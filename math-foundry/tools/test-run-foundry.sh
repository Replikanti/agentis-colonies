#!/usr/bin/env bash
# math-foundry/tools/test-run-foundry.sh -- smoke test for run-foundry.sh
# --dry-run mode (#592).
#
# Assertions:
#
#   1. FOUNDRY_DRY_RUN=1 exits 0
#   2. emit_step transcript names the configured topics
#   3. emit_step transcript names the configured paper corpus
#   4. emit_step transcript names the configured tick interval
#   5. emit_step transcript names the configured total ticks
#   6. emit_step transcript names the configured daemons per colony
#   7. emit_step transcript names the configured hold period
#   8. Invalid FOUNDRY_TOTAL_TICKS=0 rejected with exit 2
#   9. Empty FOUNDRY_TOPICS rejected with exit 2
#  10. Bootstrap-script generation step is emitted in dry-run output
#  11. Container spawn command is emitted in dry-run output (echo-only)
#  12. Run-meta.json write step is emitted in dry-run output
#  13. Cleanup trap is installed in dry-run output
#  14. Header doc names every documented FOUNDRY_* env var
#
# Standard library only -- no pytest, no requests, no live LLM, no podman.
#
# Usage: bash math-foundry/tools/test-run-foundry.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH="$SCRIPT_DIR/run-foundry.sh"

PASS=0
FAIL=0

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle not found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_eq() {
    label="$1"; expected="$2"; actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       expected: $expected"
        echo "       actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] run-foundry.sh not executable at $ORCH"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# ---------------------------------------------------------------------------
# 1-7. Dry-run with explicit knobs surfaces every config line.
# ---------------------------------------------------------------------------
DRY_RC=0
OUT="$(FOUNDRY_DRY_RUN=1 \
       FOUNDRY_TOPICS=number_theory,combinatorics \
       FOUNDRY_PAPER_CORPUS=/tmp/foundry-corpus \
       FOUNDRY_TICK_INTERVAL_S=30 \
       FOUNDRY_TOTAL_TICKS=12 \
       FOUNDRY_DAEMONS_PER_COLONY=2 \
       FOUNDRY_HOLD_PERIOD=5 \
       FOUNDRY_RUN_DIR="$WORK_DIR/run-default" \
       bash "$ORCH" 2>&1)" || DRY_RC=$?

assert_eq "1. FOUNDRY_DRY_RUN=1 exits 0" "0" "$DRY_RC"
assert_contains "2. emit_step names topics" "$OUT" "topics: number_theory,combinatorics"
assert_contains "3. emit_step names paper corpus" "$OUT" "paper corpus: /tmp/foundry-corpus"
assert_contains "4. emit_step names tick interval" "$OUT" "tick interval: 30s"
assert_contains "5. emit_step names total ticks" "$OUT" "total ticks: 12"
assert_contains "6. emit_step names daemons per colony" "$OUT" "daemons per colony: 2"
assert_contains "7. emit_step names hold period" "$OUT" "hold period: 5"

# ---------------------------------------------------------------------------
# 8. Invalid total ticks rejected.
# ---------------------------------------------------------------------------
INVALID_RC=0
INVALID_OUT="$(FOUNDRY_DRY_RUN=1 FOUNDRY_TOTAL_TICKS=0 \
               bash "$ORCH" 2>&1 || true)"
FOUNDRY_DRY_RUN=1 FOUNDRY_TOTAL_TICKS=0 bash "$ORCH" >/dev/null 2>&1 || INVALID_RC=$?
assert_eq "8a. FOUNDRY_TOTAL_TICKS=0 exits 2" "2" "$INVALID_RC"
assert_contains "8b. zero-ticks stderr names the variable" "$INVALID_OUT" \
    "FOUNDRY_TOTAL_TICKS must be >= 1"

# ---------------------------------------------------------------------------
# 9. Empty FOUNDRY_TOPICS rejected.
# ---------------------------------------------------------------------------
EMPTY_RC=0
EMPTY_OUT="$(FOUNDRY_DRY_RUN=1 FOUNDRY_TOPICS= \
             bash "$ORCH" 2>&1 || true)"
FOUNDRY_DRY_RUN=1 FOUNDRY_TOPICS= bash "$ORCH" >/dev/null 2>&1 || EMPTY_RC=$?
assert_eq "9a. empty FOUNDRY_TOPICS exits 2" "2" "$EMPTY_RC"
assert_contains "9b. empty-topics stderr names the variable" "$EMPTY_OUT" \
    "FOUNDRY_TOPICS must be a non-empty comma-separated list"

# ---------------------------------------------------------------------------
# 10-13. Bootstrap, spawn, run-meta, cleanup-trap steps are all emitted.
# ---------------------------------------------------------------------------
assert_contains "10. bootstrap-script generation step emitted" "$OUT" \
    "generating bootstrap script"
assert_contains "11. container spawn command emitted via echo prefix" "$OUT" \
    "+ podman run -d --replace --name math-foundry-laptop"
assert_contains "12. run-meta.json write step emitted" "$OUT" \
    "writing run-meta.json"
assert_contains "13. cleanup trap installed" "$OUT" \
    "trap 'podman stop --time 5 math-foundry-laptop"

# ---------------------------------------------------------------------------
# 14. Header-doc sanity (env vars documented).
# ---------------------------------------------------------------------------
SRC="$(cat "$ORCH")"
assert_contains "14a. header documents FOUNDRY_TOPICS" "$SRC" "FOUNDRY_TOPICS"
assert_contains "14b. header documents FOUNDRY_PAPER_CORPUS" "$SRC" "FOUNDRY_PAPER_CORPUS"
assert_contains "14c. header documents FOUNDRY_TICK_INTERVAL_S" "$SRC" "FOUNDRY_TICK_INTERVAL_S"
assert_contains "14d. header documents FOUNDRY_TOTAL_TICKS" "$SRC" "FOUNDRY_TOTAL_TICKS"
assert_contains "14e. header documents FOUNDRY_DRY_RUN" "$SRC" "FOUNDRY_DRY_RUN"
assert_contains "14f. header documents FOUNDRY_RUN_DIR" "$SRC" "FOUNDRY_RUN_DIR"
assert_contains "14g. header documents FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK" "$SRC" \
    "FOUNDRY_FITNESS_REWARD_NOVEL_PER_TICK"
assert_contains "14h. header documents FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK" "$SRC" \
    "FOUNDRY_FITNESS_PENALTY_NOT_NOVEL_PER_TICK"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
