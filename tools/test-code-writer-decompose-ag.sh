#!/usr/bin/env bash
# test-code-writer-decompose-ag.sh (#1422 M2): grep-level + agentis-commit-parse
# structural assertions for implementation/code_writer.ag's AG-driven decompose
# loop (ag_decompose_step over the M1 --decompose-only primitive).
#
# The decompose FSM cannot be exercised end-to-end without a live federation
# (it drives detached flat-cyborg sessions across ticks), so — like
# test-code-writer-plan-post.sh — this pins the load-bearing INVARIANTS at the
# source level:
#   (a) the agent parses (agentis commit);
#   (b) recursion base case — subtask_idx advances ONLY under the `i < n` guard,
#       and `i == n` is the ONLY transition into decomp="finalize";
#   (c) one-PR invariant — exactly ONE --finalize drive is reachable from
#       ag_decompose_step (a single is_finalize=true launch in the finalize state);
#   (d) multi-subtask accumulation — force_reuse is `i > 1` (subtask >= 2 uses
#       --reuse to accumulate on subtask 1's fresh branch);
#   (e) in-shell fallback still works — decompose_flag = " --decompose" stays
#       reachable when ag_decompose_on is false (default OFF);
#   (f) ag_decompose_reset clears all SIX memo keys + the subtasks file;
#   (g) clear_job_dir fires after STATUS=decomposed and each subtask boundary;
#   (h) the AG_DECOMPOSE_LOOP gate is epic-scoped + default OFF (getenv == "1").
#
# Matches the test style of tools/test-code-writer-plan-post.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1
# any-fail. Auto-discovered by colony-lint.sh's `find tools -name test-*.sh`
# loop. Related: #1422, #1354, #1353.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AG="$REPO_ROOT/dev-apprenticeship/implementation/agents/code_writer.ag"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
  echo "[FAIL] code_writer.ag present: missing $AG"
  echo ""
  echo "Results: 0 passed, 1 failed"
  exit 1
fi

# --- Isolate ag_decompose_step's body so the invariant greps below cannot be
#     satisfied by an unrelated function (e.g. a stray --finalize in ag_edit_step).
DECOMP_BODY="$(awk '/^fn ag_decompose_step\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"

# 1. The decompose entry points exist: ag_decompose_step + the two M1-consuming
#    launch helpers.
if grep -F -q -- 'fn ag_decompose_step(' "$AG" \
  && grep -F -q -- 'fn ag_decompose_launch(' "$AG" \
  && grep -F -q -- 'fn ag_decompose_reset(' "$AG"; then
  pass "ag_decompose_step + ag_decompose_launch + ag_decompose_reset defined"
else
  fail "decompose functions defined" "expected fn ag_decompose_step/_launch/_reset in $AG"
fi

# 2 (b). Recursion base case: subtask_idx advances ONLY under an `i < n` guard,
#        and `i == n` is the SOLE transition into decomp="finalize".
#        - exactly one write of subtask_idx to (i + 1), and it sits under `if i < n`;
#        - exactly one write of decomp to "finalize" from the editing advance.
idx_adv="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'code_edit_loop:subtask_idx:" + iid), to_string(i + 1)')"
guard_lt="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'if i < n {')"
if [ "$idx_adv" = "1" ] && [ "$guard_lt" = "1" ]; then
  pass "base case: subtask_idx advances (i+1) exactly once, under the 'if i < n' guard"
else
  fail "base case i<n advance" "idx_adv=$idx_adv guard_lt=$guard_lt (both must be 1)"
fi

# The advance must come BEFORE the finalize transition (the else-arm of i<n),
# i.e. the subtask_idx=i+1 write precedes the decomp="finalize" write in the body.
adv_line="$(printf '%s\n' "$DECOMP_BODY" | grep -n -F -- 'code_edit_loop:subtask_idx:" + iid), to_string(i + 1)' | head -1 | cut -d: -f1)"
fin_line="$(printf '%s\n' "$DECOMP_BODY" | grep -n -F -- 'code_edit_loop:decomp:" + iid), "finalize"' | head -1 | cut -d: -f1)"
if [ -n "$adv_line" ] && [ -n "$fin_line" ] && [ "$adv_line" -lt "$fin_line" ]; then
  pass "base case: the i<n advance precedes the i==n finalize transition"
else
  fail "advance-before-finalize ordering" "adv_line=$adv_line fin_line=$fin_line"
fi

# 3 (c). One-PR invariant: exactly ONE --finalize drive is reachable from
#        ag_decompose_step — a single is_finalize=true ag_attempt_launch call in
#        the finalize state (subtask edits pass is_finalize=false).
fin_launch="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'ag_attempt_launch(owner, repo, iid, branch, title, task, description, true, false)')"
edit_launch="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'ag_attempt_launch(owner, repo, iid, branch, title, subtask_text, description, false, force_reuse)')"
if [ "$fin_launch" = "1" ] && [ "$edit_launch" = "1" ]; then
  pass "one-PR invariant: exactly one is_finalize=true launch (finalize) + one per-subtask launch"
else
  fail "one-PR invariant launch count" "finalize_launch=$fin_launch edit_launch=$edit_launch (both must be 1)"
fi

# Also: only ONE transition memo into decomp="finalize" exists in the whole body.
fin_transitions="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'code_edit_loop:decomp:" + iid), "finalize"')"
if [ "$fin_transitions" = "1" ]; then
  pass "one-PR invariant: exactly one decomp=\"finalize\" transition"
else
  fail "single finalize transition" "count=$fin_transitions (must be 1)"
fi

# 4 (d). Multi-subtask accumulation: force_reuse is `i > 1` so subtask >= 2 rides
#        --reuse onto subtask 1's fresh branch.
if printf '%s\n' "$DECOMP_BODY" | grep -F -q -- 'let force_reuse = i > 1;'; then
  pass "accumulation: force_reuse = i > 1 (subtask >= 2 uses --reuse)"
else
  fail "force_reuse = i > 1" "expected 'let force_reuse = i > 1;' in ag_decompose_step"
fi

# 5 (e). In-shell fallback still works: decompose_flag = " --decompose" stays
#        reachable when ag_decompose_on is false (the default-OFF path). The
#        dispatch nests it as: if ag_decompose_on { ""; } else { " --decompose"; }.
if grep -F -q -- 'if is_epic { if ag_decompose_on { ""; } else { " --decompose"; }; } else { ""; };' "$AG"; then
  pass "fallback: in-shell --decompose reachable when ag_decompose_on is false"
else
  fail "in-shell --decompose fallback reachable" "expected the nested decompose_flag ternary in the dispatch"
fi

# 6 (f). ag_decompose_reset clears ALL SIX memo keys + the subtasks file.
RESET_BODY="$(awk '/^fn ag_decompose_reset\(/{c=1} c{print} c&&/^}/{exit}' "$AG")"
missing_key=""
for key in decomp subtask_count subtask_idx phase attempts; do
  printf '%s\n' "$RESET_BODY" | grep -F -q -- "code_edit_loop:$key:\" + iid" || missing_key="$missing_key $key"
done
# The 6th cleared artifact is the stable subtasks file (rm -f), + the cont file.
if [ -z "$missing_key" ] \
  && printf '%s\n' "$RESET_BODY" | grep -F -q -- 'code-edit-subtasks/issue-' \
  && printf '%s\n' "$RESET_BODY" | grep -F -q -- 'code-edit-cont/issue-'; then
  pass "ag_decompose_reset clears decomp/subtask_count/subtask_idx/phase/attempts + subtasks & cont files"
else
  fail "ag_decompose_reset key coverage" "missing_memo_keys=[$missing_key] (needs all 5 memo keys + subtasks + cont file rm)"
fi

# 7 (g). clear_job_dir fires after STATUS=decomposed (before the first subtask
#        launch) AND on each subtask boundary (the editing-advance path).
#        At least two clear_job_dir(iid) calls live in ag_decompose_step, one in
#        the "decomposed" block and one in the editing-advance block.
cjd_count="$(printf '%s\n' "$DECOMP_BODY" | grep -c -F -- 'clear_job_dir(iid);')"
if [ -n "$cjd_count" ] && [ "$cjd_count" -ge 2 ]; then
  pass "clear_job_dir fires after decomposed + subtask boundaries ($cjd_count call sites)"
else
  fail "clear_job_dir call sites" "count=$cjd_count (need >= 2: post-decomposed + subtask advance)"
fi

# 8 (h). The AG_DECOMPOSE_LOOP gate is epic-scoped + default OFF: read via
#        getenv() == "1", and only when is_epic.
if grep -F -q -- 'let ag_decompose_on = if is_epic { getenv("AG_DECOMPOSE_LOOP") == "1"; } else { false; };' "$AG"; then
  pass "AG_DECOMPOSE_LOOP gate is epic-scoped + default OFF (getenv == \"1\")"
else
  fail "AG_DECOMPOSE_LOOP gate" "expected the epic-scoped getenv(\"AG_DECOMPOSE_LOOP\") == \"1\" gate"
fi

# 9. Dispatch routes ag_decompose_on to ag_decompose_step (verdict contract).
if grep -F -q -- 'ag_decompose_step(owner, repo, issue_iid, branch_name, draft.title, task_text, draft.summary)' "$AG"; then
  pass "dispatch routes the decompose path to ag_decompose_step"
else
  fail "dispatch -> ag_decompose_step" "expected the ag_decompose_step call in the verdict resolution"
fi

# 10. The stable subtasks path lives OUTSIDE the job dir (code-edit-subtasks/),
#     so clear_job_dir cannot reap the M1 --subtasks-out records mid-loop.
if grep -F -q -- '.agentis/code-edit-subtasks/issue-' "$AG" \
  && grep -F -q -- ' --decompose-only --subtasks-out ' "$AG"; then
  pass "subtasks list is written OUTSIDE the job dir via --decompose-only --subtasks-out"
else
  fail "subtasks-out path outside job dir" "expected code-edit-subtasks/ path + --decompose-only --subtasks-out launch"
fi

# -----------------------------------------------------------------------------
# Parse check: the agent commits cleanly under `agentis commit`, same as the
# per-agent syntax pass in colony-lint.sh. Skipped (not failed) when agentis is
# not installed, matching the CI runner contract. This is the guard for the
# read_subtask awk `RS="\0"` string escaping (the one dialect trap).
# -----------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
  LINT_TMP="$(mktemp -d)"
  trap 'rm -rf "$LINT_TMP"' EXIT
  (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
  if (cd "$LINT_TMP" && agentis commit "$AG") >/dev/null 2>&1; then
    pass "code_writer.ag parses (agentis commit)"
  else
    fail "code_writer.ag parses (agentis commit)" "syntax error in code_writer.ag"
  fi
else
  echo "[SKIP] agentis not on PATH — skipping .ag parse check"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
