#!/bin/bash
# tools/test-detect-agent-failures.sh: unit tests for tools/detect-agent-failures.sh (M3 of #1266).
#
# Validates:
#   Test 1: a pattern repeated 3x -> reported with count 3 (exact DRIFT TSV line)
#   Test 2: a pattern appearing 1x -> NOT reported (below REPEAT_THRESHOLD)
#   Test 3: detector always exits 0 (it is a detector, not a gate)
#
# The scanned logs dir is driven through AGENT_LOG_DIR so the assertions use a
# throwaway fixture dir and never depend on the live federation logs.
#
# Usage: ./tools/test-detect-agent-failures.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECTOR="$SCRIPT_DIR/detect-agent-failures.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[FAIL] tools/detect-agent-failures.sh missing or not executable"
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ----- Fixture logs: one pattern 3x (recurs), one pattern 1x (suppressed) -----
printf 'ERROR job-failed at tick 1\nERROR job-failed at tick 2\nERROR job-failed at tick 3\n' \
    > "$TMPDIR_TEST/agent-a.log"
printf 'code_writer produced no edits this round\n' > "$TMPDIR_TEST/agent-b.log"

OUT="$(AGENT_LOG_DIR="$TMPDIR_TEST" "$DETECTOR")"
RC=$?

# ----- Test 1: the 3x pattern is reported with count 3 -----
EXPECTED="$(printf 'DRIFT\tagent-failure\tERROR job-failed:3\tERROR job-failed at tick 1')"
if printf '%s\n' "$OUT" | grep -qxF "$EXPECTED"; then
    pass "recurring: reports DRIFT line with count 3 for the 3x pattern"
else
    fail "recurring" "expected line <$EXPECTED>, got <$OUT>"
fi

# ----- Test 2: the 1x pattern is NOT reported -----
if printf '%s\n' "$OUT" | grep -q 'produced no edits'; then
    fail "suppressed" "expected no line for the 1x pattern, got <$OUT>"
else
    pass "suppressed: emits nothing for the pattern below REPEAT_THRESHOLD"
fi

# ----- Test 3: detector exits 0 -----
if [ "$RC" -eq 0 ]; then
    pass "exit 0 (detector, not gate)"
else
    fail "exit" "rc=$RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
