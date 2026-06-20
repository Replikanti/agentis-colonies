#!/usr/bin/env bash
# test-code-writer-completion-markers.sh: #1185 grep-level wiring assertions
# for implementation/code_writer.ag.
#
# Two operability fixes are covered here:
#
#   Part 2 (first-run MR-learning bound). merged_mr_cmd() returns the
#   no-`--since` form on the first tick (empty `last_check`). Without a bound
#   that learns from the WHOLE merged-MR history — one prompt() per MR per
#   tick — starving the drafting step on a mature repo. The fix bounds the
#   first-run query to a small recent window (`--per-page 1`, both forge
#   backends sort updated_at desc), so the first run never learns more than a
#   bounded window. We assert the no-since branch carries that bound.
#
#   Part 3 (don't strand a half-completed autonomous flow). The #200 staleness
#   markers (last_drafted_iid / _updated_at) used to be written right after the
#   draft prompt, BEFORE the autonomous action ran. A half-completed tick still
#   marked the issue "drafted", so the #200 gate skipped it forever. The fix
#   sets the markers only once the path's own action has COMPLETED: the
#   autonomous path (#1210: Approach A — edit in a local checkout, then commit
#   the diff + open the PR; #1214: the slow orchestrator runs DETACHED via
#   code-edit-job.sh and code_writer polls its state across ticks) sets them
#   only inside the PR-opened block (`if job_state == "DONE"`); the
#   non-autonomous (review-gated / propose / shadow) paths still set them after
#   their terminal draft comment / emit. We assert, structurally:
#     - the markers are NOT written before the tier branch (no write between
#       `should_draft_code(...)` and the `if my_tier == "autonomous"` branch);
#     - a marker write appears inside the `if job_state == "DONE"` block;
#     - a marker write still exists on the non-autonomous side.
#
# Matches the test style of tools/test-assignment-based-pickup.sh (bash,
# [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0 all-pass, 1
# any-fail. Related: #1185.

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

# -----------------------------------------------------------------------------
# Part 2: first-run MR-learning bound.
# -----------------------------------------------------------------------------

# The no-since merged-requests query (the first-run branch) must carry a bound
# so the very first tick cannot fan out over the whole merged history.
if grep -F -q -- 'merge-requests --state merged --per-page 1 --view impl' "$AG"; then
  pass "merged_mr_cmd bounds first-run (no last_check) learning (--per-page 1)"
else
  fail "merged_mr_cmd first-run bound" \
    "no-since merge-requests query missing a --per-page bound in code_writer.ag"
fi

# The since-gated query (sticky ticks) must stay unbounded so a real
# last_check window still learns from every MR merged since then.
if grep -F -q -- 'merge-requests --state merged --since ' "$AG"; then
  pass "merged_mr_cmd keeps the --since query for sticky ticks"
else
  fail "merged_mr_cmd since-query" \
    "expected a '--since'-gated merge-requests query in code_writer.ag"
fi

# -----------------------------------------------------------------------------
# Part 3: completion-time staleness markers. Use awk to slice the file into the
# three regions delimited by the structural anchors, so we assert *where* the
# marker writes live, not just that they exist somewhere.
#   region A: from `should_draft_code(` up to (not incl.) the autonomous branch
#   region B: from `if job_state == "DONE"` to its closing scope
#   region C: from the non-autonomous `} else {` (the tier else) to end
# -----------------------------------------------------------------------------
MARKER='memo_write(scoped_memo(owner, repo, "code_writer:last_drafted_iid")'

# Region A: between the should_draft_code gate and the autonomous branch.
# A marker write here would be the pre-fix bug (mark before any action runs).
region_a="$(awk '
  /if should_draft_code\(/ { grab=1 }
  /if my_tier == "autonomous"/ { grab=0 }
  grab { print }
' "$AG")"
if printf '%s\n' "$region_a" | grep -F -q -- "$MARKER"; then
  fail "marker not set before the tier branch" \
    "last_drafted_iid written between should_draft_code and the autonomous branch (pre-#1185 bug)"
else
  pass "marker NOT set before the tier branch (autonomous flow can retry)"
fi

# Region B: inside the PR-opened block. The autonomous path must mark only when
# the detached job reports DONE (the poll-state machine, #1214) — never on
# LAUNCHED / RUNNING / NO_EDITS / ERROR.
region_b="$(awk '
  /if job_state == "DONE"/ { grab=1 }
  grab { print }
  /emit\("implementation:mr_ready", draft\)/ { if (grab) exit }
' "$AG")"
if printf '%s\n' "$region_b" | grep -F -q -- "$MARKER"; then
  pass "autonomous path sets the marker inside the job_state == \"DONE\" block"
else
  fail "autonomous marker placement" \
    "last_drafted_iid not written inside the 'if job_state == \"DONE\"' block"
fi

# The autonomous branch must NOT mark before the detached launcher runs: assert
# the marker write occurs after the code-edit-job.sh command line within the
# file (#1214 moved the slow orchestrator behind this fast launcher).
edit_line="$(grep -n -F -- 'tools/code-edit-job.sh --owner' "$AG" | head -1 | cut -d: -f1)"
marker_lines="$(grep -n -F -- "$MARKER" "$AG" | cut -d: -f1)"
autonomous_marker_after_edit=0
if [ -n "$edit_line" ]; then
  for ln in $marker_lines; do
    if [ "$ln" -gt "$edit_line" ]; then
      autonomous_marker_after_edit=1
      break
    fi
  done
fi
if [ "$autonomous_marker_after_edit" = "1" ]; then
  pass "a marker write follows the code-edit-job.sh launcher call (not before it)"
else
  fail "marker vs launcher ordering" \
    "no last_drafted_iid write found after the code-edit-job.sh line"
fi

# Region C: the non-autonomous paths (review-gated / propose / shadow) must
# still mark after their terminal draft comment / emit, so they stay
# idempotent and do not re-post every tick. We assert the marker exists after
# the review-gated add-note post.
post_line="$(grep -n -F -- 'add-note ' "$AG" | head -1 | cut -d: -f1)"
nonauto_marker_after_post=0
if [ -n "$post_line" ]; then
  for ln in $marker_lines; do
    if [ "$ln" -gt "$post_line" ]; then
      nonauto_marker_after_post=1
      break
    fi
  done
fi
if [ "$nonauto_marker_after_post" = "1" ]; then
  pass "non-autonomous paths still mark after their terminal post/emit (idempotent)"
else
  fail "non-autonomous marker placement" \
    "no last_drafted_iid write found after the review-gated add-note post"
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
