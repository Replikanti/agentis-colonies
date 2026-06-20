#!/usr/bin/env bash
# test-assignment-based-pickup.sh: #1181 wiring + parse assertions for the
# assignment-based work-pickup change. The 5 agents that "check assigned
# issues" (implementation/code_writer + planning/{risk_assessor, plan_reviewer,
# task_decomposer, scope_estimator}) used to gate pickup on a label event once
# `last_check` was set: after tick 1 they switched to the
# `...-by-label-events --since <last_check>` query, so a stably-assigned issue
# with no recent label churn went invisible on a mature repo. The fix makes
# pickup always query the current-state snapshot.
#
# This test asserts, per agent (grep-level wiring):
#   1. the pickup command builds the current-state snapshot
#      (`assigned-issues ... --view` / `issues --needs-planning --view`).
#   2. pickup is no longer gated behind `...-by-label-events --since` (the
#      label-events branch and its `--since <last_check>` are gone). The
#      code_writer "learn from merged MR" step keeps its own
#      `merge-requests --since` query — that is a separate code path and is
#      explicitly excluded from this assertion.
# Plus a parse check: all 5 .ag files commit cleanly under `agentis commit`
# (skipped when the agentis binary is not on PATH, mirroring colony-lint).
#
# Matches the test style of tools/test-implementation-assignee-filter.sh
# (bash 3.2, [PASS]/[FAIL] lines, `Results: N passed, M failed`). Exit 0
# all-pass, 1 any-fail. Related: #1181.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
AGENTS_DIR="$REPO_ROOT/dev-apprenticeship"
PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# -----------------------------------------------------------------------------
# Per-agent pickup wiring. Each row is:
#   <relative .ag path> | <snapshot-verb grep> | <forbidden label-events grep>
# The snapshot grep is the current-state query the agent must now build; the
# forbidden grep is the label-events pickup query that must be gone. Both are
# fixed-string greps (grep -F) so the `+ ... + repo_arg(...)` concat noise
# around them does not matter.
# -----------------------------------------------------------------------------
AGENTS=(
  "implementation/agents/code_writer.ag|assigned-issues --view assigned|assigned-issues-by-label-events --since "
  "planning/agents/plan_reviewer.ag|issues --needs-planning --view planning|issues-by-label-events --since "
  "planning/agents/risk_assessor.ag|issues --needs-planning --view planning|issues-by-label-events --since "
  "planning/agents/task_decomposer.ag|issues --needs-planning --view planning|issues-by-label-events --since "
  "planning/agents/scope_estimator.ag|issues --needs-planning --view planning|issues-by-label-events --since "
)

for row in "${AGENTS[@]}"; do
  rel="${row%%|*}"
  rest="${row#*|}"
  snapshot="${rest%%|*}"
  forbidden="${rest#*|}"
  ag="$AGENTS_DIR/$rel"
  name="$(basename "$rel")"

  if [ ! -f "$ag" ]; then
    fail "$name: agent file present" "missing $ag"
    continue
  fi

  if grep -F -q -- "$snapshot" "$ag"; then
    pass "$name: builds snapshot pickup ($snapshot)"
  else
    fail "$name: builds snapshot pickup ($snapshot)" "not found in $rel"
  fi

  if grep -F -q -- "$forbidden" "$ag"; then
    fail "$name: pickup no longer gated on label events" "still references '$forbidden' in $rel"
  else
    pass "$name: pickup no longer gated on label events (no '$forbidden')"
  fi
done

# -----------------------------------------------------------------------------
# Parse check: each agent commits cleanly under `agentis commit`, same as the
# per-agent syntax pass in colony-lint.sh. Skipped (not failed) when agentis is
# not installed, matching the CI runner contract.
# -----------------------------------------------------------------------------
if command -v agentis >/dev/null 2>&1; then
  LINT_TMP="$(mktemp -d)"
  trap 'rm -rf "$LINT_TMP"' EXIT
  (cd "$LINT_TMP" && agentis init) >/dev/null 2>&1
  for row in "${AGENTS[@]}"; do
    rel="${row%%|*}"
    ag="$AGENTS_DIR/$rel"
    name="$(basename "$rel")"
    if (cd "$LINT_TMP" && agentis commit "$ag") >/dev/null 2>&1; then
      pass "$name: parses (agentis commit)"
    else
      fail "$name: parses (agentis commit)" "syntax error in $rel"
    fi
  done
else
  echo "[SKIP] agentis not on PATH — skipping .ag parse checks"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
