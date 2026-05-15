#!/bin/bash
# test-run-ab-experiment.sh -- smoke test for run-ab-experiment.sh
# --dry-run mode (#573 PR-5).
#
# 8 assertions covering the harness control surface:
#   1. --help works (returns 0, prints usage).
#   2. AB_DRY_RUN=1 AB_N_REPLICATES=2 emits exactly 4 run-replay.sh
#      lines (2 arms * 2 replicates).
#   3. Control replicates carry
#      REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999.
#   4. Treatment replicates carry
#      REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3.
#   5. Per-run dirs follow ab-trading-*-{control,treatment}-run-*
#      naming.
#   6. experiment-manifest.json path is emitted in the plan.
#   7. analyze-ab-results.py invocation emitted after the runs.
#   8. Unknown flag exits non-zero (2).
#
# Standard library only -- no pytest, no live LLM, no podman.
#
# Usage: bash trading-binance/tools/test-run-ab-experiment.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HARNESS="$SCRIPT_DIR/run-ab-experiment.sh"

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

if [ ! -x "$HARNESS" ]; then
    echo "[FAIL] run-ab-experiment.sh not executable at $HARNESS"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. --help works.
# ---------------------------------------------------------------------------
HELP_RC=0
HELP_OUT="$(bash "$HARNESS" --help 2>&1)" || HELP_RC=$?
assert_eq "1a. --help exits 0" "0" "$HELP_RC"
assert_contains "1b. --help prints harness summary" "$HELP_OUT" \
    "A/B emergence experiment harness"
assert_contains "1c. --help documents AB_N_REPLICATES" "$HELP_OUT" \
    "AB_N_REPLICATES"

# ---------------------------------------------------------------------------
# 2-7. AB_DRY_RUN=1 AB_N_REPLICATES=2 -> 4 run-replay invocations + manifest
#      + analyser invocation.
# ---------------------------------------------------------------------------
DRY_RC=0
DRY_OUT="$(AB_DRY_RUN=1 AB_N_REPLICATES=2 \
           AB_SYMBOL=BTCUSDT AB_TIMEFRAME=1h \
           bash "$HARNESS" 2>&1)" || DRY_RC=$?
assert_eq "2a. AB_DRY_RUN=1 exits 0" "0" "$DRY_RC"

run_replay_lines=$(printf '%s\n' "$DRY_OUT" | grep -c 'bash .*run-replay.sh' || true)
assert_eq "2b. exactly 4 run-replay.sh invocations emitted (2 arms x 2 reps)" \
    "4" "$run_replay_lines"

# 3. Control threshold (999) appears in dry-run.
control_999_lines=$(printf '%s\n' "$DRY_OUT" \
    | grep -F 'REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999' \
    | grep -c 'bash .*run-replay.sh' || true)
assert_eq "3. control replicates carry threshold=999" "2" "$control_999_lines"

# 4. Treatment threshold (3) appears in dry-run.
treatment_3_lines=$(printf '%s\n' "$DRY_OUT" \
    | grep -F 'REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3 ' \
    | grep -c 'bash .*run-replay.sh' || true)
assert_eq "4. treatment replicates carry threshold=3" "2" "$treatment_3_lines"

# 5. Per-run dir naming convention.
assert_contains "5a. control-run-1 dir name emitted" "$DRY_OUT" \
    "control-run-1"
assert_contains "5b. control-run-2 dir name emitted" "$DRY_OUT" \
    "control-run-2"
assert_contains "5c. treatment-run-1 dir name emitted" "$DRY_OUT" \
    "treatment-run-1"
assert_contains "5d. treatment-run-2 dir name emitted" "$DRY_OUT" \
    "treatment-run-2"

# 6. experiment-manifest.json path emitted.
assert_contains "6. experiment-manifest.json path emitted" "$DRY_OUT" \
    "experiment-manifest.json"

# 7. analyser invocation emitted (after the runs).
assert_contains "7. analyze-ab-results.py invocation emitted" "$DRY_OUT" \
    "analyze-ab-results.py"

# Verify ordering: analyser line appears AFTER the last run-replay line.
analyser_pos=$(printf '%s\n' "$DRY_OUT" | grep -n 'analyze-ab-results.py' | tail -1 | cut -d: -f1)
last_replay_pos=$(printf '%s\n' "$DRY_OUT" | grep -n 'bash .*run-replay.sh' | tail -1 | cut -d: -f1)
if [ -n "$analyser_pos" ] && [ -n "$last_replay_pos" ] && [ "$analyser_pos" -gt "$last_replay_pos" ]; then
    echo "[PASS] 7b. analyser invocation strictly after last replicate"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 7b. analyser invocation ordering wrong (analyser_pos=$analyser_pos last_replay_pos=$last_replay_pos)"
    FAIL=$((FAIL + 1))
fi

# ---------------------------------------------------------------------------
# 8. Unknown flag exits 2.
# ---------------------------------------------------------------------------
UNK_RC=0
bash "$HARNESS" --no-such-flag >/dev/null 2>&1 || UNK_RC=$?
assert_eq "8. unknown flag exits 2" "2" "$UNK_RC"

# Header-doc sanity.
SRC="$(cat "$HARNESS")"
assert_contains "header documents AB_N_REPLICATES" "$SRC" "AB_N_REPLICATES"
assert_contains "header documents AB_SYMBOL" "$SRC" "AB_SYMBOL"
assert_contains "header documents AB_TIMEFRAME" "$SRC" "AB_TIMEFRAME"
assert_contains "header documents AB_SPEED" "$SRC" "AB_SPEED"
assert_contains "header documents AB_DRY_RUN" "$SRC" "AB_DRY_RUN"
assert_contains "header documents binance-feed-download prerequisite" "$SRC" \
    "binance-feed-download.py"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
