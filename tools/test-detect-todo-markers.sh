#!/bin/bash
# tools/test-detect-todo-markers.sh: unit tests for tools/detect-todo-markers.sh (M1 of #1266).
#
# Validates:
#   Test 1: a file carrying a TODO marker -> prints exactly the DRIFT TSV line
#   Test 2: a clean file                  -> no line is emitted for it
#   Test 3: detector always exits 0 (it is a detector, not a gate)
#
# The scanned tree is driven through DETECT_TODO_ROOT so the assertions use a
# throwaway fixture dir and never depend on the live repo contents.
#
# Usage: ./tools/test-detect-todo-markers.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECTOR="$SCRIPT_DIR/detect-todo-markers.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[FAIL] tools/detect-todo-markers.sh missing or not executable"
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# ----- Fixture tree: one marked file, one clean file -----
printf 'TODO: wire this up\n' > "$TMPDIR_TEST/marked.txt"
printf 'all good here\n' > "$TMPDIR_TEST/clean.txt"

OUT="$(DETECT_TODO_ROOT="$TMPDIR_TEST" "$DETECTOR")"
RC=$?

# ----- Test 1: marked file emits the exact DRIFT TSV line -----
EXPECTED="$(printf 'DRIFT\ttodo-marker\tmarked.txt:1\tTODO: wire this up')"
if printf '%s\n' "$OUT" | grep -qxF "$EXPECTED"; then
    pass "marked: prints DRIFT line for the TODO marker"
else
    fail "marked" "expected line <$EXPECTED>, got <$OUT>"
fi

# ----- Test 2: clean file produces no line -----
if printf '%s\n' "$OUT" | grep -q 'clean.txt'; then
    fail "clean" "expected no line for clean.txt, got <$OUT>"
else
    pass "clean: emits nothing for the marker-free file"
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
