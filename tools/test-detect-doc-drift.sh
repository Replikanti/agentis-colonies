#!/bin/bash
# tools/test-detect-doc-drift.sh: unit tests for tools/detect-doc-drift.sh (#1267).
#
# Validates:
#   Test 1: badge and VERSION disagree -> prints exactly the DRIFT TSV line
#   Test 2: badge and VERSION match     -> prints nothing
#   Test 3: detector always exits 0 (it is a detector, not a gate)
#
# Inputs are driven through DETECT_DOC_DRIFT_README / DETECT_DOC_DRIFT_VERSION
# so the assertions use throwaway fixtures and never touch the live repo files.
#
# Usage: ./tools/test-detect-doc-drift.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DETECTOR="$SCRIPT_DIR/detect-doc-drift.sh"

if [ ! -x "$DETECTOR" ]; then
    echo "[FAIL] tools/detect-doc-drift.sh missing or not executable"
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Build a README fixture carrying a version badge for the given version.
make_readme() {
    local path="$1" ver="$2"
    cat > "$path" <<EOF
# dev-apprenticeship

![Version: $ver](https://img.shields.io/badge/version-$ver-blue) ![Agents: 21](https://img.shields.io/badge/agents-21-green)
EOF
}

run_detector() {
    DETECT_DOC_DRIFT_README="$1" DETECT_DOC_DRIFT_VERSION="$2" "$DETECTOR"
}

# ----- Test 1: drift case (badge 2.0.0 vs VERSION 2.1.0) -----
make_readme "$TMPDIR_TEST/r1.md" "2.0.0"
printf '2.1.0\n' > "$TMPDIR_TEST/v1"
OUT="$(run_detector "$TMPDIR_TEST/r1.md" "$TMPDIR_TEST/v1")"
RC=$?
EXPECTED="$(printf 'DRIFT\tversion-badge\t2.0.0\t2.1.0')"
if [ "$OUT" = "$EXPECTED" ]; then
    pass "drift: prints DRIFT line with documented=badge, actual=VERSION"
else
    fail "drift" "expected <$EXPECTED>, got <$OUT>"
fi
if [ "$RC" -eq 0 ]; then
    pass "drift: exit 0 (detector, not gate)"
else
    fail "drift-exit" "rc=$RC"
fi

# ----- Test 2: no-drift case (badge 2.1.0 == VERSION 2.1.0) -----
make_readme "$TMPDIR_TEST/r2.md" "2.1.0"
printf '2.1.0\n' > "$TMPDIR_TEST/v2"
OUT="$(run_detector "$TMPDIR_TEST/r2.md" "$TMPDIR_TEST/v2")"
RC=$?
if [ -z "$OUT" ]; then
    pass "no-drift: prints nothing when badge matches VERSION"
else
    fail "no-drift" "expected empty output, got <$OUT>"
fi
if [ "$RC" -eq 0 ]; then
    pass "no-drift: exit 0"
else
    fail "no-drift-exit" "rc=$RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
