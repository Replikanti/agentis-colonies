#!/bin/bash
# tools/test-walk-forward.sh — unit tests for tools/walk-forward.sh (#1167).
#
# Container-free coverage of the walk-forward orchestrator:
#
#   1. Fold-spec parsing: WF_FOLDS -> the correct per-fold train/test
#      windows surface in the --dry-run plan (train start..end, test
#      end..testEnd) for >= 2 folds.
#   2. tribe -> pid -> evolved-prompt extraction against a synthetic
#      finished TRAIN run dir (strategist-alpha.log with
#      'child started (pid=42)' + memo strategist:42:strategy_prompt.jsonl
#      carrying a known .value) -> --extract-prompt writes that value into
#      seed/tribe-alpha.txt and exits 0; a tribe with no pid exits 5 and
#      writes nothing.
#   3. --dry-run prints >= 2 folds AND the seed/freeze wiring: the
#      --extract-prompt step per tribe, REPLAY_SEED_PROMPTS_DIR threaded
#      into the TEST phase, and the frozen evolution threshold (999999).
#   4. Exit codes: dry-run 0, unknown flag 2, bad fold spec 2.
#
# Standard library only — no pytest, no podman, no live LLM. Self-contained:
# the synthetic run dir is generated inline. dash-safe (POSIX sh idioms,
# printf for fixtures, no bashisms in the assertions).
#
# Auto-discovered + run by tools/colony-lint.sh's tools-test loop.
#
# Usage: bash tools/test-walk-forward.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WF="$SCRIPT_DIR/walk-forward.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        pass "$label"
    else
        fail "$label" "needle not found: $needle"
    fi
}

if [ ! -x "$WF" ]; then
    echo "[FAIL] walk-forward.sh not executable at $WF"
    exit 1
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

TWO_FOLDS="2026-03-01:2026-03-08:2026-03-12,2026-03-01:2026-03-12:2026-03-16"

# ---------------------------------------------------------------------------
# 1. Fold-spec parsing — both folds' train/test windows appear in the plan.
# ---------------------------------------------------------------------------
DRY_RC=0
PLAN="$(WF_FOLDS="$TWO_FOLDS" WF_RUN_DIR="$WORK_DIR/wf1" \
        bash "$WF" --dry-run 2>&1)" || DRY_RC=$?
assert_contains "1a. dry-run reports 2 folds" "$PLAN" "folds: 2"
assert_contains "1b. fold 1 train/test windows parsed" "$PLAN" \
    "fold 1/2 : train 2026-03-01..2026-03-08 -> test 2026-03-08..2026-03-12"
assert_contains "1c. fold 2 train/test windows parsed" "$PLAN" \
    "fold 2/2 : train 2026-03-01..2026-03-12 -> test 2026-03-12..2026-03-16"
assert_contains "1d. TRAIN phase window 1 surfaced" "$PLAN" \
    "train phase: window 2026-03-01..2026-03-08 (evolution_threshold=3)"
assert_contains "1e. TEST phase window 1 surfaced" "$PLAN" \
    "test phase: window 2026-03-08..2026-03-12"

# ---------------------------------------------------------------------------
# 2. tribe -> pid -> prompt extraction against a synthetic TRAIN run dir.
# ---------------------------------------------------------------------------
TRAINRUN="$WORK_DIR/trainrun"
mkdir -p "$TRAINRUN/laptop-node/.agentis/logs" "$TRAINRUN/laptop-node/.agentis/memo"
printf 'boot\nchild started (pid=42) colony=tribe-alpha tick=40000\nready\n' \
    >"$TRAINRUN/laptop-node/.agentis/logs/strategist-alpha.log"
# Two memo records; the last .value wins (latest evolved prompt body).
printf '{"value":"EVOLVED ALPHA gen1","ts":1}\n{"value":"EVOLVED ALPHA gen3 frozen","ts":2}\n' \
    >"$TRAINRUN/laptop-node/.agentis/memo/strategist:42:strategy_prompt.jsonl"
# tribe-beta has a log but no pid line -> extraction must skip (exit 5).
printf 'boot\nno child line here\n' \
    >"$TRAINRUN/laptop-node/.agentis/logs/strategist-beta.log"

SEED_DIR="$WORK_DIR/seed"
EX_RC=0
bash "$WF" --extract-prompt "$TRAINRUN" alpha "$SEED_DIR/tribe-alpha.txt" >/dev/null 2>&1 || EX_RC=$?
if [ "$EX_RC" -eq 0 ]; then
    pass "2a. extract-prompt exits 0 on a tribe with a pid + prompt"
else
    fail "2a. extract-prompt exits 0 on a tribe with a pid + prompt" "rc=$EX_RC"
fi
if [ -f "$SEED_DIR/tribe-alpha.txt" ]; then
    EX_VAL="$(cat "$SEED_DIR/tribe-alpha.txt")"
    assert_contains "2b. extracted prompt is the latest .value" "$EX_VAL" \
        "EVOLVED ALPHA gen3 frozen"
else
    fail "2b. extracted prompt is the latest .value" "seed file not written"
fi

BETA_RC=0
bash "$WF" --extract-prompt "$TRAINRUN" beta "$SEED_DIR/tribe-beta.txt" >/dev/null 2>&1 || BETA_RC=$?
if [ "$BETA_RC" -eq 5 ]; then
    pass "2c. extract-prompt exits 5 when no pid"
else
    fail "2c. extract-prompt exits 5 when no pid" "rc=$BETA_RC"
fi
if [ -f "$SEED_DIR/tribe-beta.txt" ]; then
    fail "2d. extract-prompt writes nothing when no pid" "stray seed file written"
else
    pass "2d. extract-prompt writes nothing when no pid"
fi

# tribe-gamma: pid line present but the memo .value is empty -> exit 5.
printf 'child started (pid=77) colony=tribe-gamma\n' \
    >"$TRAINRUN/laptop-node/.agentis/logs/strategist-gamma.log"
printf '{"value":"","ts":1}\n' \
    >"$TRAINRUN/laptop-node/.agentis/memo/strategist:77:strategy_prompt.jsonl"
GAMMA_RC=0
bash "$WF" --extract-prompt "$TRAINRUN" gamma "$SEED_DIR/tribe-gamma.txt" >/dev/null 2>&1 || GAMMA_RC=$?
if [ "$GAMMA_RC" -eq 5 ]; then
    pass "2e. extract-prompt exits 5 on empty prompt value"
else
    fail "2e. extract-prompt exits 5 on empty prompt value" "rc=$GAMMA_RC"
fi

# ---------------------------------------------------------------------------
# 3. --dry-run prints the seed/freeze wiring: per-tribe extract step,
#    REPLAY_SEED_PROMPTS_DIR threaded into TEST, frozen threshold 999999.
# ---------------------------------------------------------------------------
assert_contains "3a. dry-run shows per-tribe extract step" "$PLAN" \
    "--extract-prompt <trainrun> alpha"
assert_contains "3b. dry-run threads REPLAY_SEED_PROMPTS_DIR into TEST" "$PLAN" \
    "REPLAY_SEED_PROMPTS_DIR="
assert_contains "3c. dry-run TEST phase uses the frozen evolution threshold" "$PLAN" \
    "REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999999"
assert_contains "3d. dry-run TRAIN phase keeps evolution armed (threshold=3)" "$PLAN" \
    "REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3"
assert_contains "3e. dry-run names the run-replay.sh orchestrator" "$PLAN" \
    "trading-binance/tools/run-replay.sh"
assert_contains "3f. dry-run reports no containers spawned" "$PLAN" \
    "no containers spawned"

# ---------------------------------------------------------------------------
# 4. Exit codes.
# ---------------------------------------------------------------------------
if [ "$DRY_RC" -eq 0 ]; then
    pass "4a. --dry-run exits 0"
else
    fail "4a. --dry-run exits 0" "rc=$DRY_RC"
fi

UNKNOWN_RC=0
bash "$WF" --bogus-flag >/dev/null 2>&1 || UNKNOWN_RC=$?
if [ "$UNKNOWN_RC" -eq 2 ]; then
    pass "4b. unknown flag exits 2"
else
    fail "4b. unknown flag exits 2" "rc=$UNKNOWN_RC"
fi

BADFOLD_RC=0
WF_FOLDS="2026-03-01:2026-03-08" bash "$WF" --dry-run >/dev/null 2>&1 || BADFOLD_RC=$?
if [ "$BADFOLD_RC" -eq 2 ]; then
    pass "4c. malformed fold spec exits 2"
else
    fail "4c. malformed fold spec exits 2" "rc=$BADFOLD_RC"
fi

BADDATE_RC=0
WF_FOLDS="2026-3-1:2026-03-08:2026-03-12" bash "$WF" --dry-run >/dev/null 2>&1 || BADDATE_RC=$?
if [ "$BADDATE_RC" -eq 2 ]; then
    pass "4d. malformed date in fold spec exits 2"
else
    fail "4d. malformed date in fold spec exits 2" "rc=$BADDATE_RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
