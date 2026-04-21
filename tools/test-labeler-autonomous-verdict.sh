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
if grep -Fq 'memo_write("labeler:autonomous_verdict:"' "$LABELER"; then
    ok "multi-slot blob key memo_write(\"labeler:autonomous_verdict:\" + ...)"
else
    bad "multi-slot blob key memo_write missing"
fi

if grep -Fq 'recall_latest("labeler:autonomous_verdict_index")' "$LABELER"; then
    ok "index recall_latest(\"labeler:autonomous_verdict_index\")"
else
    bad "index recall_latest missing"
fi

if grep -Fq 'memo_write("labeler:autonomous_verdict_index",' "$LABELER"; then
    ok "index memo_write(\"labeler:autonomous_verdict_index\", ...)"
else
    bad "index memo_write missing"
fi

# -- (3) scanner wired into tick() -------------------------------------------
# evaluate_autonomous_verdicts() must be called from tick(); paired with
# evaluate_label_verdict() so both reality checks run before new work each
# tick.
tick_line="$(grep -n '^fn tick(' "$LABELER" | head -1 | cut -d: -f1 || true)"
if [ -z "$tick_line" ]; then
    bad "fn tick() not found — cannot verify scanner wiring"
else
    scanner_line="$(awk -v t="$tick_line" 'NR>t && /evaluate_autonomous_verdicts\(\)/ {print NR; exit}' "$LABELER")"
    propose_line="$(awk -v t="$tick_line" 'NR>t && /evaluate_label_verdict\(\)/ {print NR; exit}' "$LABELER")"
    if [ -n "$scanner_line" ]; then
        ok "evaluate_autonomous_verdicts() called from tick() (line $scanner_line)"
    else
        bad "evaluate_autonomous_verdicts() NOT called from tick() — scanner is dead code"
    fi
    if [ -n "$propose_line" ]; then
        ok "evaluate_label_verdict() still called from tick() (line $propose_line) — propose path not broken"
    else
        bad "evaluate_label_verdict() no longer called from tick() — #106/#195 propose path regressed"
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
if grep -Fq 'memo_write("labeler:pending_verdict"' "$LABELER"; then
    ok "propose-path labeler:pending_verdict memo_write still present"
else
    bad "propose-path labeler:pending_verdict memo_write removed — #106/#195 regressed"
fi
if grep -Fq 'recall_latest("labeler:pending_verdict")' "$LABELER"; then
    ok "propose-path labeler:pending_verdict recall_latest still present"
else
    bad "propose-path labeler:pending_verdict recall_latest removed — #106/#195 regressed"
fi

# -- (6) autonomous compare has no signal==0 arm -----------------------------
# Compare the two compare_cmd python3 inline scripts: propose has signal 0,
# autonomous must not. Grep for the two-arm ternary that starts at `print(1
# if sug and sug.issubset(act)` — the propose variant prepends a
# `0 if not act else` guard; the autonomous variant does not.
if grep -Fq "print(0 if not act else" "$LABELER"; then
    ok "propose compare still has signal==0 guard (0 if not act else ...)"
else
    bad "propose compare signal==0 guard missing — #195 regressed"
fi

# Look for an autonomous-specific compare that does NOT have the `0 if not act`
# prefix. The pattern must be: `print(1 if sug and sug.issubset(act) else (2`
# WITHOUT a leading `0 if not act else`.
if awk '/SUGGESTED=/ && /RAW=/ && /python3/ {print}' "$LABELER" | grep -vq "0 if not act else"; then
    ok "at least one compare call is autonomous-style (no signal==0 arm)"
else
    bad "every compare call still has signal==0 arm — autonomous-compare variant missing"
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

# Append catch-branch must preserve peer iids when the subprocess fails.
# A refactor that falls back to plain `iid_str` (or `""`) silently discards
# any previously-queued autonomous writes.
if awk '/^fn append_autonomous_index\(/,/^}/' "$LABELER" | grep -Eq "catch e \{ append_csv\(existing, iid_str\); \}"; then
    ok "append_autonomous_index catch-branch preserves peers via append_csv(existing, iid_str)"
else
    bad "append_autonomous_index catch-branch does NOT preserve peers — silently clobbers the index on subprocess failure"
fi

# End-of-scan index rewrite: evaluate_autonomous_verdicts MUST write the
# surviving index at the end of the scan. A refactor that moves this into
# eval_autonomous_at or drops it turns the scanner into a no-op after the
# first still-soaking iid.
if awk '/^fn evaluate_autonomous_verdicts\(/,/^}/' "$LABELER" | grep -Fq 'memo_write("labeler:autonomous_verdict_index",'; then
    ok "evaluate_autonomous_verdicts rewrites the index at end of scan"
else
    bad "evaluate_autonomous_verdicts does NOT rewrite the index — scanner is a no-op after first keep"
fi

echo
echo "labeler-autonomous-verdict: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
