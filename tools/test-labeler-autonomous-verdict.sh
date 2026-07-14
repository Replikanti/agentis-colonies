#!/usr/bin/env bash
# test-labeler-autonomous-verdict.sh -- #203 structural regression test
#
# Verifies the autonomous-tier reality-check pattern in triage/labeler.ag:
#
#   1. Per-iid memo schema (multi-slot), not single-slot like the propose path.
#      Keys: `labeler:autonomous_verdict:<iid>` + `labeler:autonomous_verdict_index`
#   2. Entry points defined: record / score-one / iterator / scanner.
#   3. Scanner wired into tick() alongside the existing propose-path
#      evaluate_label_verdict() call.
#   4. Autonomous branch records the verdict BEFORE emitting the at-write
#      `learn("success", ..., "acted")` row — the two-row-per-action
#      ordering is what preserves the honest reality-check signal (soak
#      row is the truthful one; at-write row is the optimistic one).
#   5. Propose-path single-slot `labeler:pending_verdict` idiom is still
#      in place — this ticket extends the pattern, it does not replace
#      the #106/#195 path.
#   6. Signal compare in score_one_autonomous() has no signal==0 arm
#      (autonomous WROTE the labels; "act empty" = reversal, not silence).
#   7. Soak and ageout windows are the documented 1800 s / 172 800 s.
#
# Grep-based rather than dynamic because the runtime end-to-end path
# (tier=autonomous + GitLab write + 30 min soak + reality-check tick)
# would require a daemon + a mock GitLab API; the structural invariants
# above are the regression surface a future refactor is most likely to
# quietly break.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABELER="$REPO_ROOT/dev-apprenticeship/triage/agents/labeler.ag"

pass=0
fail=0

ok()  { echo "  ok — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

echo "[labeler.ag]"

if [ ! -f "$LABELER" ]; then
    bad "missing file: $LABELER"
    echo
    echo "labeler-autonomous-verdict: $pass passed, $fail failed"
    exit 1
fi

# -- (2) entry points --------------------------------------------------------
for fn in record_autonomous_verdict score_one_autonomous eval_autonomous_at evaluate_autonomous_verdicts append_autonomous_index; do
    if grep -Eq "^fn ${fn}\(" "$LABELER"; then
        ok "fn ${fn}() defined"
    else
        bad "fn ${fn}() missing"
    fi
done

# -- (1) multi-slot memo schema ----------------------------------------------
# Post-#316 M3a, the per-iid blob key is built via scoped_memo(owner, repo,
# "labeler:autonomous_verdict:" + to_string(issue_id)). On single-block
# configs scoped_memo passes the suffix through unchanged so the key is
# byte-identical to the pre-M3 literal `labeler:autonomous_verdict:<iid>`.
if grep -Fq '"labeler:autonomous_verdict:" + to_string(issue_id)' "$LABELER"; then
    ok "multi-slot blob key suffix \"labeler:autonomous_verdict:\" + to_string(issue_id) (M3a scoped_memo wraps it per-repo)"
else
    bad "multi-slot blob key suffix missing"
fi

# The index key is now built via scoped_memo too. Both recall_latest and
# memo_write reference the same scoped key via a `key` local; the literal
# suffix `labeler:autonomous_verdict_index` must appear inside scoped_memo.
if grep -Fq 'scoped_memo(owner, repo, "labeler:autonomous_verdict_index")' "$LABELER"; then
    ok "index key suffix scoped_memo(owner, repo, \"labeler:autonomous_verdict_index\") (M3a per-repo)"
else
    bad "index key suffix missing"
fi

# evaluate_autonomous_verdicts must read the index — locally bound `key` from
# scoped_memo, then recall_latest(key). Verify both ops appear inside the fn.
if awk '/^fn evaluate_autonomous_verdicts\(/,/^}/' "$LABELER" | grep -Fq 'recall_latest(key)'; then
    ok "evaluate_autonomous_verdicts() reads index via recall_latest(key)"
else
    bad "evaluate_autonomous_verdicts() does not recall the index"
fi

# -- (3) scanner wired into tick_for_repo() ----------------------------------
# Post-#316 M3a, both evaluate_* helpers take (owner, repo) and are called
# from tick_for_repo, which the outer tick() fans out per-repo via tick_at.
# Verify both calls land inside tick_for_repo so per-tick reality checks
# still fire before each repo's work batch.
tfr_line="$(grep -n '^fn tick_for_repo(' "$LABELER" | head -1 | cut -d: -f1 || true)"
if [ -z "$tfr_line" ]; then
    bad "fn tick_for_repo() not found — cannot verify scanner wiring"
else
    scanner_line="$(awk -v t="$tfr_line" 'NR>t && /evaluate_autonomous_verdicts\(owner, repo\)/ {print NR; exit}' "$LABELER")"
    propose_line="$(awk -v t="$tfr_line" 'NR>t && /evaluate_label_verdict\(owner, repo\)/ {print NR; exit}' "$LABELER")"
    if [ -n "$scanner_line" ]; then
        ok "evaluate_autonomous_verdicts(owner, repo) called from tick_for_repo() (line $scanner_line)"
    else
        bad "evaluate_autonomous_verdicts(owner, repo) NOT called from tick_for_repo() — scanner is dead code"
    fi
    if [ -n "$propose_line" ]; then
        ok "evaluate_label_verdict(owner, repo) still called from tick_for_repo() (line $propose_line) — propose path not broken"
    else
        bad "evaluate_label_verdict(owner, repo) no longer called from tick_for_repo() — #106/#195 propose path regressed"
    fi
fi

# -- (4) ordering invariant: record_autonomous_verdict BEFORE at-write learn -
# Inside the `if my_tier == "autonomous"` branch, record_autonomous_verdict()
# MUST appear before the bare learn("label", ..., "success", [..., "acted"]).
# If this ordering flips, a prompt/learn failure could leave a row in the
# experience store with no future reality-check to correct it.
auto_line="$(grep -n 'if my_tier == "autonomous"' "$LABELER" | head -1 | cut -d: -f1 || true)"
if [ -z "$auto_line" ]; then
    bad "autonomous branch not found"
else
    record_line="$(awk -v a="$auto_line" 'NR>a && /record_autonomous_verdict\(/ {print NR; exit}' "$LABELER")"
    learn_line="$(awk -v a="$auto_line" 'NR>a && /learn\("label"/ && /"success"/ && /"acted"/ {print NR; exit}' "$LABELER")"
    if [ -n "$record_line" ] && [ -n "$learn_line" ] && [ "$record_line" -gt "$auto_line" ] && [ "$record_line" -lt "$learn_line" ]; then
        ok "record_autonomous_verdict() before at-write learn() inside autonomous branch (lines $auto_line < $record_line < $learn_line)"
    else
        bad "ordering broken: autonomous=$auto_line record=${record_line:-?} learn=${learn_line:-?} — record must be between branch opener and first at-write learn()"
    fi
fi

# -- (5) propose-path single-slot path intact --------------------------------
# Post-#316 M3a, the pending-verdict key is built via scoped_memo too. On
# single-block configs (owner == "") the key collapses to the literal
# `labeler:pending_verdict` so pre-M3 federations pick up their existing
# verdicts on first M3 tick — the migration is implicit.
if grep -Fq 'scoped_memo(owner, repo, "labeler:pending_verdict")' "$LABELER"; then
    ok "propose-path labeler:pending_verdict key built via scoped_memo (M3a per-repo)"
else
    bad "propose-path labeler:pending_verdict key construction missing — #106/#195 regressed"
fi
# evaluate_label_verdict reads via recall_latest(key) — the key local is
# bound from scoped_memo at the top of the fn.
if awk '/^fn evaluate_label_verdict\(/,/^}/' "$LABELER" | grep -Fq 'recall_latest(key)'; then
    ok "evaluate_label_verdict() reads pending verdict via recall_latest(key)"
else
    bad "evaluate_label_verdict() does not recall the pending verdict — #106/#195 regressed"
fi

# -- (6) autonomous compare has no signal==0 arm -----------------------------
# #1638 P3 cluster B: the two compares are now native `.ag` (was `python3 -c`).
# The propose path (evaluate_label_verdict) keeps its empty-act signal-0 arm
# (`if len(act) == 0 { 0; }`); the autonomous path (score_one_autonomous) does
# NOT — an empty act there is a reversal (signal 3). Assert the signal-0 arm is
# present in the propose region and ABSENT from the autonomous region.
PROPOSE_REGION="$(awk '/^fn evaluate_label_verdict\(/,/^}/' "$LABELER")"
AUTO_REGION="$(awk '/^fn score_one_autonomous\(/,/^}/' "$LABELER")"
if printf '%s' "$PROPOSE_REGION" | grep -qF 'if len(act) == 0 {'; then
    ok "propose compare still has signal==0 guard (if len(act) == 0 ...)"
else
    bad "propose compare signal==0 guard missing — #195 regressed"
fi

# The autonomous compare must NOT carry the `if len(act) == 0` empty-act arm —
# a reversal there is signal 3, not "no signal yet".
if printf '%s' "$AUTO_REGION" | grep -qF 'if len(act) == 0 {'; then
    bad "autonomous compare still has an empty-act signal==0 arm — #203 regressed"
else
    ok "autonomous compare has no signal==0 arm (empty act => reversal signal 3)"
fi

# -- (7) soak and ageout constants -------------------------------------------
if grep -Eq "let soak_s = 1800" "$LABELER"; then
    ok "soak window = 1800 s (30 min)"
else
    bad "soak window != 1800 s — spec drift"
fi

if grep -Eq "let ageout_s = 172800" "$LABELER"; then
    ok "autonomous ageout window = 172800 s (48 h)"
else
    bad "autonomous ageout window != 172800 s — spec drift"
fi

# Propose-path ageout must stay at 86400 — this test doubles as a regression
# guard against accidentally unifying the two windows.
if grep -Eq "let timeout_s = 86400" "$LABELER"; then
    ok "propose-path timeout_s = 86400 s (24 h) preserved"
else
    bad "propose-path timeout_s != 86400 s — #106/#195 spec drift"
fi

# -- (8) hardening asserts (QA PR #243 round 2) ------------------------------

# Append must preserve peer iids. #1588 slice 4: the dedup+append body is
# now native (dedup_append_csv — regex_split/filter/trim/reduce, all total,
# pure builtins), not a python3 subprocess wrapped in a try/catch, so there
# is no failure mode left that could silently discard previously-queued
# iids — peer-preservation holds by construction instead of via a
# catch-branch fallback. A refactor that reintroduces a subprocess call
# without carrying `existing` through would be a regression; guard against
# that by requiring the native helper call to stay the whole function body.
if awk '/^fn append_autonomous_index\(/,/^}/' "$LABELER" | grep -Fq "dedup_append_csv(existing, iid_str)"; then
    ok "append_autonomous_index preserves peers via native dedup_append_csv(existing, iid_str)"
else
    bad "append_autonomous_index does NOT preserve peers — dedup_append_csv(existing, iid_str) call missing"
fi

# End-of-scan index rewrite: evaluate_autonomous_verdicts MUST write the
# surviving index at the end of the scan. A refactor that moves this into
# eval_autonomous_at or drops it turns the scanner into a no-op after the
# first still-soaking iid. Post-#316 M3a the key local is bound from
# scoped_memo so the rewrite hits the per-repo key.
if awk '/^fn evaluate_autonomous_verdicts\(/,/^}/' "$LABELER" | grep -Fq 'memo_write(key,'; then
    ok "evaluate_autonomous_verdicts rewrites the index at end of scan via memo_write(key, ...)"
else
    bad "evaluate_autonomous_verdicts does NOT rewrite the index — scanner is a no-op after first keep"
fi

echo
echo "labeler-autonomous-verdict: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
