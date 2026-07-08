#!/usr/bin/env bash
# test-code-writer-plan-post.sh: #1500 grep-level structural assertions for
# implementation/code_writer.ag's autonomous-tier plan-visibility fix.
#
# Before this fix, the `review-gated` branch posted the drafted implementation
# plan as an issue note ("[draft-impl] ... pending approval") but the
# `autonomous` branch never did — it drafted a plan internally (branch name,
# file list, approach) and jumped straight to launching the detached edit job,
# so the operator's only pre-code intervention point (cf. #1482) never fired
# for self-initiated / directly-labeled issues.
#
# We assert, structurally:
#   - the autonomous-tier plan note text exists;
#   - the plan-post guard/block precedes (by line number) BOTH launch calls
#     (the in-shell `job_raw` launcher and the AG-driven `ag_edit_step` call)
#     — visibility must land BEFORE the edit job starts, not after;
#   - the idempotency guard (`code_writer:plan_posted:` memo-scoped key)
#     exists, so retries/re-polls never double-post;
#   - the post is fail-open: a failed `exec sh` is caught and logged, never
#     raised past the block, and never blocks the launch below;
#   - the review-gated note text is unchanged (regression pin — this PR must
#     not touch that branch).
#
# Matches the test style of tools/test-code-writer-completion-markers.sh
# (bash, [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass,
# 1 any-fail. Auto-discovered by colony-lint.sh's `find tools -name test-*.sh`
# loop. Related: #1500.

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

# 1. The autonomous-tier plan note text exists (distinct from the
#    review-gated note — no "pending approval" wording, since nothing is
#    pending at this tier).
if grep -F -q -- '[plan] **Implementation Plan** (automated)' "$AG"; then
  pass "autonomous plan note text present ([plan] ... (automated))"
else
  fail "autonomous plan note text" \
    "expected literal '[plan] **Implementation Plan** (automated)' in $AG"
fi

# 2. The plan-post guard/block must precede BOTH launch call sites by line
#    number — visibility must land BEFORE the edit job starts (the pre-code
#    intervention point cited in #1482), not after.
guard_line="$(grep -n -F -- 'if !plan_already_posted(' "$AG" | head -1 | cut -d: -f1)"
job_raw_line="$(grep -n -F -- 'let job_raw = if ag_loop_on' "$AG" | head -1 | cut -d: -f1)"
ag_edit_step_line="$(grep -n -F -- 'ag_edit_step(owner, repo, issue_iid,' "$AG" | head -1 | cut -d: -f1)"

if [ -n "$guard_line" ] && [ -n "$job_raw_line" ] && [ -n "$ag_edit_step_line" ] \
  && [ "$guard_line" -lt "$job_raw_line" ] && [ "$guard_line" -lt "$ag_edit_step_line" ]; then
  pass "plan-post guard precedes both launch calls (job_raw and ag_edit_step)"
else
  fail "plan-post ordering vs launch calls" \
    "guard_line=$guard_line job_raw_line=$job_raw_line ag_edit_step_line=$ag_edit_step_line (guard must be less than both)"
fi

# 3. Idempotency guard: a code_writer:plan_posted:<iid> scoped memo key must
#    exist so retries/re-polls (LAUNCHED/RUNNING re-enter this block every
#    tick) never double-post.
if grep -F -q -- 'code_writer:plan_posted:' "$AG"; then
  pass "plan_posted idempotency memo key present (code_writer:plan_posted:)"
else
  fail "plan_posted memo key" \
    "expected a 'code_writer:plan_posted:' scoped memo literal in $AG"
fi

# 4. Fail-open: the plan-post exec sh call must be wrapped in try/catch, and
#    the catch arm must log (not silently swallow) the failure. Assert the
#    failure log message appears shortly after the plan-post exec sh line —
#    same ordering-assertion style as test-code-writer-completion-markers.sh's
#    "marker follows launcher" pins, just checking a catch arm here.
plan_exec_line="$(grep -n -F -- 'exec sh plan_post_cmd;' "$AG" | head -1 | cut -d: -f1)"
fail_log_line="$(grep -n -F -- 'Failed to post autonomous plan note' "$AG" | head -1 | cut -d: -f1)"
if [ -n "$plan_exec_line" ] && [ -n "$fail_log_line" ] \
  && [ "$fail_log_line" -gt "$plan_exec_line" ] \
  && [ "$((fail_log_line - plan_exec_line))" -le 3 ]; then
  pass "plan-post is fail-open (try/catch logs 'Failed to post autonomous plan note')"
else
  fail "plan-post fail-open guard" \
    "expected a 'Failed to post autonomous plan note' catch-arm log within 3 lines after the plan_post_cmd exec sh call"
fi

# 5. Regression pin: the review-gated note text must remain byte-identical —
#    this PR is explicitly out of scope for that branch.
if grep -F -q -- '[draft-impl] **Implementation Plan** (automated, pending approval)' "$AG"; then
  pass "review-gated note text unchanged ([draft-impl] ... pending approval)"
else
  fail "review-gated note regression" \
    "expected unchanged literal '[draft-impl] **Implementation Plan** (automated, pending approval)' in $AG"
fi

# -----------------------------------------------------------------------------
# Parse check: the agent commits cleanly under `agentis commit`, same as the
# per-agent syntax pass in colony-lint.sh. Skipped (not failed) when agentis is
# not installed, matching the CI runner contract.
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
