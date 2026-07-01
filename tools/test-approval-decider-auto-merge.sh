#!/usr/bin/env bash
# test-approval-decider-auto-merge.sh (#1375): structural wiring assertions for
# the DURABLE own-PR auto-merge sweep in code-review/approval_decider.ag.
#
# approval_decider's bus-based decision path gated the WHOLE tick on four
# ephemeral `listen("review:*_findings")` reads; the reviewers emit on their own
# independent tick schedules, so those emits almost never landed inside the narrow
# listen() window, the tick early-exited before the approve/merge block, and
# AUTO_MERGE never fired (#1375). The remedy (sibling of #1360): poll DURABLE forge
# state. merge_ready_prs lists the federation's OWN open PRs every tick, BEFORE the
# bus gate, and approves + merges the green/mergeable ones.
#
# The .ag has no runtime unit harness (colony-lint's per-agent `agentis commit`
# parse is its gate), so — exactly like tools/test-code-writer-ci-recovery.sh — we
# assert the sweep-path wiring at the grep level plus a parse check. The SAFETY
# invariants that MUST hold (this path is a terminal write):
#
#   1. Sweep runs at the autonomous tier ONLY (merging is terminal) AND BEFORE the
#      listen() bus gate in tick_for_repo; a merge action returns for the tick.
#   2. Own PRs only: head branch must start `fix/issue-` (never a PR we didn't open).
#   3. Acts ONLY on STATE=green (never red/pending — don't race CI).
#   4. Approve guarded by merge_sweep:approved:<iid>, written BEFORE the approve call.
#   5. The gated merge verb is invoked (success + no-op log lines).
#   6. Hard cap 3 attempts via merge_sweep:attempts:<iid>; after that gives up + logs.
#   7. The path adds NO prompt() (it is not flagged by check-prompt-gate.sh).
#   8. Every dynamic exec-sh value is shell_escape'd + carries the lint pragma.
#
# Matches the test style of tools/test-code-writer-ci-recovery.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1 any-fail.
set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/code-review/agents/approval_decider.ag"
PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    echo "[FAIL] approval_decider.ag present: missing $AG"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# Bodies of the two functions where the per-PR safety logic lives.
MERGE_AT="$(awk '/^fn merge_at\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"
MERGE_READY="$(awk '/^fn merge_ready_prs\(/{f=1} f{print} /^}/{if(f) f=0}' "$AG")"

# 1a. Autonomous-only gate in merge_ready_prs (terminal-write guard).
if printf '%s' "$MERGE_READY" | grep -q 'repo_tier("approval_decider", owner, repo) != "autonomous"'; then
    pass "auto-merge sweep is gated on the autonomous tier (terminal-write guard)"
else
    fail "autonomous-only gate" "merge_ready_prs must early-return when tier != autonomous"
fi

# 1b. The AUTO_MERGE opt-in env contract is preserved (no auto-merge unless =1).
if printf '%s' "$MERGE_READY" | grep -q 'getenv("AUTO_MERGE") != "1"'; then
    pass "AUTO_MERGE opt-in contract preserved (sweep no-ops unless AUTO_MERGE=1)"
else
    fail "AUTO_MERGE contract" "merge_ready_prs must early-return when AUTO_MERGE != 1"
fi

# 1c. merge_ready_prs is CALLED at the top of tick_for_repo, BEFORE the listen()
# bus gate. The sweep call line number must precede the first listen("review:..").
sweep_line="$(grep -n 'merge_ready_prs(owner, repo) == 1' "$AG" | head -n1 | cut -d: -f1)"
listen_line="$(grep -n 'let style = listen("review:style_findings"' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$sweep_line" ] && [ -n "$listen_line" ] && [ "$sweep_line" -lt "$listen_line" ]; then
    pass "merge_ready_prs runs at the TOP of tick_for_repo (before the listen() bus gate)"
else
    fail "sweep runs before bus gate" "sweep_line=$sweep_line listen_line=$listen_line"
fi
# A merge action returns for the tick (one merge action per tick): a `return;`
# must appear within the few lines after the merge_ready_prs==1 guard.
if [ -n "$sweep_line" ] && sed -n "${sweep_line},$((sweep_line + 8))p" "$AG" | grep -q 'return;'; then
    pass "a merge action returns for the tick (one merge action per tick)"
else
    fail "return-on-merge" "the merge_ready_prs==1 branch must return;"
fi

# 2. Own PRs only: head must start fix/issue- (index_of == 0).
if printf '%s' "$MERGE_AT" | grep -q 'index_of(src, "fix/issue-") != 0'; then
    pass "own-PRs-only guard: head branch must start fix/issue- (index_of == 0)"
else
    fail "own-PRs-only guard" "merge_at must reject branches not starting fix/issue-"
fi

# 3. Acts only on STATE=green (red/pending skipped — no CI race).
if printf '%s' "$MERGE_AT" | grep -q 'if state != "green" { return 0; }'; then
    pass "acts ONLY on STATE=green (red/pending are skipped — no CI race)"
else
    fail "green-only guard" "merge_at must early-return unless state == green"
fi
# The status is read from the thin mr-pipeline-status verb and classified by the
# .ag-local ci_state() helper (#1355 moved the red/green/pending mapping out of
# the forge wrapper into the agent).
if printf '%s' "$MERGE_AT" | grep -q 'mr-pipeline-status ' && printf '%s' "$MERGE_AT" | grep -q 'ci_state(pr_check_token(checks_out, "STATUS"))'; then
    pass "state comes from mr-pipeline-status (STATUS token) classified by ci_state()"
else
    fail "mr-pipeline-status wiring" "merge_at must call forge-api.sh mr-pipeline-status and classify STATUS via ci_state()"
fi

# 4. Approve guarded by merge_sweep:approved:<iid>, written BEFORE the approve call.
if printf '%s' "$MERGE_AT" | grep -q 'recall_latest(scoped_memo(owner, repo, "merge_sweep:approved:" + iid_str))'; then
    pass "approve is guarded by the merge_sweep:approved:<iid> memo (at most once per PR)"
else
    fail "approve-once guard" "merge_at must guard approve on merge_sweep:approved:<iid>"
fi
# The memo_write of merge_sweep:approved must appear BEFORE the approve exec line.
approved_write_line="$(grep -n 'memo_write(scoped_memo(owner, repo, "merge_sweep:approved:" + iid_str)' "$AG" | head -n1 | cut -d: -f1)"
approve_exec_line="$(grep -n 'forge-api.sh approve " + shell_escape(iid_str)' "$AG" | head -n1 | cut -d: -f1)"
if [ -n "$approved_write_line" ] && [ -n "$approve_exec_line" ] && [ "$approved_write_line" -lt "$approve_exec_line" ]; then
    pass "merge_sweep:approved:<iid> is written BEFORE the approve call (anti-spam, crash-safe)"
else
    fail "approved-before-approve" "approved_write_line=$approved_write_line approve_exec_line=$approve_exec_line"
fi

# 5. The gated merge verb is invoked; success + no-op log lines present.
if printf '%s' "$MERGE_AT" | grep -q 'forge-api.sh merge " + shell_escape(iid_str)' \
   && printf '%s' "$MERGE_AT" | grep -q 'Auto-merged PR'; then
    pass "the gated merge verb is invoked + success logs 'Auto-merged PR <iid>'"
else
    fail "merge invoked" "merge_at must call forge-api.sh merge and log Auto-merged PR"
fi
if printf '%s' "$MERGE_AT" | grep -q 'Auto-merge no-op for PR'; then
    pass "a not-ready merge is a logged no-op (retries next tick)"
else
    fail "no-op log" "merge_at must log a no-op when the merge verb refuses"
fi

# 6. Hard cap 3 attempts via merge_sweep:attempts:<iid>; after that give up + log.
if printf '%s' "$MERGE_AT" | grep -q 'if attempts >= 3' \
   && printf '%s' "$MERGE_AT" | grep -q 'auto-merge gave up on PR' \
   && printf '%s' "$MERGE_AT" | grep -q 'needs human'; then
    pass "hard cap 3: gives up + logs 'needs human' after 3 attempts"
else
    fail "retry cap give-up" "merge_at must stop + log at attempts >= 3"
fi
# The give-up branch returns 0 (NO merge call) — the action is only reached when
# attempts < 3.
GIVEUP_BLOCK="$(printf '%s' "$MERGE_AT" | awk '/if attempts >= 3/{f=1} f{print} /};/{if(f){exit}}')"
if printf '%s' "$GIVEUP_BLOCK" | grep -q 'return 0;'; then
    pass "the give-up branch returns 0 (no merge attempted past the cap)"
else
    fail "give-up returns 0" "after the cap the function must return 0, not act"
fi
# The attempt memo is BUMPED (+1) before acting (fail-closed: never exceed 3).
if printf '%s' "$MERGE_AT" | grep -q 'let next_attempt = attempts + 1' \
   && printf '%s' "$MERGE_AT" | grep -q 'memo_write(scoped_memo(owner, repo, "merge_sweep:attempts:" + iid_str), to_string(next_attempt))'; then
    pass "attempt memo merge_sweep:attempts:<iid> bumped (+1) before acting"
else
    fail "attempt memo bump" "merge_at must bump merge_sweep:attempts:<iid> before acting"
fi

# 7. The sweep path is prompt-free (no prompt() in any sweep helper) — so it never
# spins up a flat-cyborg session and is not flagged by check-prompt-gate.sh.
if ! printf '%s' "$MERGE_AT" | grep -q 'prompt(' \
   && ! printf '%s' "$MERGE_READY" | grep -q 'prompt('; then
    pass "the auto-merge sweep path is prompt-free (no flat-cyborg session, no prompt-gate)"
else
    fail "prompt-free" "the sweep helpers must not call prompt()"
fi

# 8. exec-sh safety: every dynamic value in the sweep exec-sh commands is
# shell_escape'd, and each command line carries the safe-exec-concat pragma.
if printf '%s' "$MERGE_AT" | grep -q 'mr-pipeline-status " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$MERGE_AT" | grep -q 'approve " + shell_escape(iid_str) + repo_arg' \
   && printf '%s' "$MERGE_AT" | grep -q 'merge " + shell_escape(iid_str) + repo_arg'; then
    pass "dynamic exec-sh values are shell_escape'd (iid in mr-pipeline-status/approve/merge)"
else
    fail "exec-sh shell_escape" "the sweep exec-sh commands must shell_escape the iid"
fi
if grep -B1 'mr-pipeline-status " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'forge-api.sh approve " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat' \
   && grep -B1 'forge-api.sh merge " + shell_escape(iid_str)' "$AG" | grep -q 'colony-lint: safe-exec-concat'; then
    pass "sweep exec-sh lines carry the safe-exec-concat lint pragma"
else
    fail "safe-exec-concat pragma" "the sweep exec-sh command lines need the lint pragma"
fi

# Parse check: the agent commits cleanly under `agentis commit` (same as the
# per-agent syntax pass in colony-lint.sh). Skipped (not failed) when agentis is
# not installed.
if command -v agentis >/dev/null 2>&1; then
    LINT_TMP="$(mktemp -d)"
    (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
    if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
        pass "approval_decider.ag parses (agentis commit) with the auto-merge sweep"
    else
        fail "approval_decider.ag parses (agentis commit)" "syntax error in approval_decider.ag"
    fi
    rm -rf "$LINT_TMP"
else
    echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
