#!/usr/bin/env bash
# test-tribes-bench-analyse-stage3.sh -- federation-local snapshot
# driver for the #495 observational analyser. Runs analyse-stage3.py
# against the canonical archived smoke #42 run dir and asserts the
# tribe-alpha and tribe-epsilon leaderboards plus the dead-variants
# subsection in comparison-stage3.md.
#
# Skips when the snapshot dir is absent (for example on CI runners
# that do not vendor archived runs). Set AGENTIS_STAGE3_SNAPSHOT_DIR
# to override the default location.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FED_ROOT="$(dirname "$SCRIPT_DIR")"
ANALYSER="$SCRIPT_DIR/analyse-stage3.py"
SNAPSHOT_DIR="${AGENTIS_STAGE3_SNAPSHOT_DIR:-$FED_ROOT/runs/stage3-docker-20260510T120610Z}"

PASS=0
FAIL=0
SKIP=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1"; SKIP=$((SKIP + 1)); }

if [ ! -f "$ANALYSER" ]; then
    fail "analyser missing: $ANALYSER"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

if [ ! -d "$SNAPSHOT_DIR" ]; then
    skip "snapshot dir absent: $SNAPSHOT_DIR"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi

OUT_DIR="$SNAPSHOT_DIR/_495-snapshot-shell"
mkdir -p "$OUT_DIR"

if ! python3 "$ANALYSER" "$SNAPSHOT_DIR" \
        --fed-root "$FED_ROOT" \
        --out "$OUT_DIR" >/dev/null 2>&1; then
    fail "analyser invocation"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
pass "analyser invocation"

CMP_PATH="$OUT_DIR/comparison-stage3.md"
if [ ! -f "$CMP_PATH" ]; then
    fail "comparison-stage3.md produced"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
pass "comparison-stage3.md produced"

# tribe-alpha leader = format-pattern-substitution-aware: it is the
# first format-pattern-* row in the Variant outcomes table.
ALPHA_LEADER="$(awk '/^\| tribe-alpha \|/{print $4; exit}' "$CMP_PATH" || true)"
if [ "$ALPHA_LEADER" = "format-pattern-substitution-aware" ]; then
    pass "tribe-alpha leader = format-pattern-substitution-aware"
else
    fail "tribe-alpha leader = format-pattern-substitution-aware (got: $ALPHA_LEADER)"
fi

# tribe-epsilon leader = concurrency-cell-interior-mut.
EPSILON_LEADER="$(awk '/^\| tribe-epsilon \|/{print $4; exit}' "$CMP_PATH" || true)"
if [ "$EPSILON_LEADER" = "concurrency-cell-interior-mut" ]; then
    pass "tribe-epsilon leader = concurrency-cell-interior-mut"
else
    fail "tribe-epsilon leader = concurrency-cell-interior-mut (got: $EPSILON_LEADER)"
fi

# format-pattern-default appears in alpha's dead-variants subsection.
if awk '/^Dead variants per tribe/,0' "$CMP_PATH" \
        | grep -q "tribe-alpha .* format-pattern-default"; then
    pass "format-pattern-default in alpha dead-variants"
else
    fail "format-pattern-default in alpha dead-variants"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
