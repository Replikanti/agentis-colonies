#!/bin/bash
# test-run-verdict-pair.sh — smoke-test the orchestrator's --dry-run CLI
# surface (#436).
#
# Asserts:
#   1. tools/run-verdict-pair.sh exists, is executable, and bash -n clean.
#   2. --dry-run exits 0.
#   3. --dry-run echoes the four expected command lines in order:
#        + bash <...>/run-stage2.sh
#        + bash <...>/run-baseline.sh
#        + python3 <...>/analyse-stage2.py <eco-dir> --baseline <baseline-dir>/telemetry.csv
#        + cat <eco-dir>/comparison.md
#
# No daemons launched. No fixtures touched. Mirrors the
# PASS/FAIL/SKIP shape of the other tribes-bench test-*.sh files.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/run-verdict-pair.sh"

PASS=0
FAIL=0

assert_eq() {
    label="$1"; exp="$2"; got="$3"
    if [ "$exp" = "$got" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $exp"
        echo "       got:      $got"
        FAIL=$((FAIL + 1))
    fi
}

assert_match() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s\n' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle missing: $needle"
        FAIL=$((FAIL + 1))
    fi
}

# 1. exists + executable + bash -n
if [ ! -x "$TARGET" ]; then
    echo "[FAIL] run-verdict-pair.sh exists and is executable"
    FAIL=$((FAIL + 1))
else
    echo "[PASS] run-verdict-pair.sh exists and is executable"
    PASS=$((PASS + 1))
fi

if bash -n "$TARGET" 2>/dev/null; then
    echo "[PASS] run-verdict-pair.sh bash -n clean"
    PASS=$((PASS + 1))
else
    echo "[FAIL] run-verdict-pair.sh bash -n clean"
    FAIL=$((FAIL + 1))
fi

# 2. --dry-run exits 0
set +e
OUT="$(bash "$TARGET" --dry-run 2>&1)"
RC=$?
set -e
assert_eq "--dry-run exits 0" "0" "$RC"

# 3. four command lines in order. Use grep -nF to pull the line numbers
# of each `+ ` prefixed step and assert ordering.
LINES="$(printf '%s\n' "$OUT" | grep -nF '+ ' | sed 's/:.*//')"
COUNT="$(printf '%s\n' "$LINES" | grep -c . || true)"
assert_eq "--dry-run prints 4 echoed command lines" "4" "$COUNT"

assert_match "step 1 is run-stage2.sh"   "$OUT" "+ bash $SCRIPT_DIR/run-stage2.sh"
assert_match "step 2 is run-baseline.sh" "$OUT" "+ bash $SCRIPT_DIR/run-baseline.sh"
assert_match "step 3 invokes analyse-stage2.py with --baseline" "$OUT" "+ python3 $SCRIPT_DIR/analyse-stage2.py"
assert_match "step 3 passes --baseline telemetry.csv" "$OUT" "--baseline"
assert_match "step 4 cats comparison.md" "$OUT" "comparison.md"

# 3b. order check: step 1 line < step 2 line < step 3 line < step 4 line
L1="$(printf '%s\n' "$OUT" | grep -nF '+ bash ' | grep -F 'run-stage2.sh' | head -1 | cut -d: -f1)"
L2="$(printf '%s\n' "$OUT" | grep -nF '+ bash ' | grep -F 'run-baseline.sh' | head -1 | cut -d: -f1)"
L3="$(printf '%s\n' "$OUT" | grep -nF '+ python3 ' | grep -F 'analyse-stage2.py' | head -1 | cut -d: -f1)"
L4="$(printf '%s\n' "$OUT" | grep -nF '+ cat ' | grep -F 'comparison.md' | head -1 | cut -d: -f1)"

if [ -n "$L1" ] && [ -n "$L2" ] && [ -n "$L3" ] && [ -n "$L4" ] \
    && [ "$L1" -lt "$L2" ] && [ "$L2" -lt "$L3" ] && [ "$L3" -lt "$L4" ]; then
    echo "[PASS] command lines appear in correct order"
    PASS=$((PASS + 1))
else
    echo "[FAIL] command lines appear in correct order"
    echo "       L1=$L1 L2=$L2 L3=$L3 L4=$L4"
    FAIL=$((FAIL + 1))
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
