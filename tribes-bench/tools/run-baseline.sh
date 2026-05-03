#!/bin/bash
# run-baseline.sh — Stage 2 M3 (#394) baseline harness.
#
# The M3 thesis verdict requires a fixed-pipeline control: a single tribe
# scanning the same target as the 5-tribe ecosystem with `replicate(...)`
# and the cognitive market (`knowledge_buy` / `knowledge_sell`) stubbed
# out. This script builds and runs that control.
#
# The baseline tribe is materialised from
# `tribes-bench/templates/tribe-baseline/` into the per-run dir
# `tribes-bench/runs/baseline-<ts>/tribe-baseline/` (template
# substitution is python3-driven; CLAUDE.md "no heredocs in tools/*.sh").
# Operator-managed cleanup of `runs/baseline-*` mirrors run-stage2.sh.
#
# Total CB budget per plan Decision 1: BASELINE_CB = 5 * initial_cb
# (matches the 5-tribe federation's total compute envelope).
#
# Env vars:
#   STAGE2_BASELINE_WALL_CLOCK_S   Wall-clock cap in seconds (default: 3600)
#   STAGE2_BASELINE_LLM_BACKEND    Override [llm].backend in colony.toml
#                                   (default: claude)
#   STAGE2_BASELINE_SNAPSHOT_S     Snapshot interval in seconds (default: 600)
#
# Exit codes:
#   0  run completed and telemetry.csv produced
#   1  prerequisite missing (agentis CLI, jq, python3) or invalid input
#   2  start-federation/baseline launch failed
#   3  analyse-stage2.py failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

WALL_CLOCK="${STAGE2_BASELINE_WALL_CLOCK_S:-3600}"
case "$WALL_CLOCK" in
    ''|*[!0-9]*)
        echo "run-baseline: STAGE2_BASELINE_WALL_CLOCK_S must be a positive integer (got: $WALL_CLOCK)" >&2
        exit 1
        ;;
esac

SNAPSHOT_INTERVAL="${STAGE2_BASELINE_SNAPSHOT_S:-600}"
case "$SNAPSHOT_INTERVAL" in
    ''|*[!0-9]*)
        echo "run-baseline: STAGE2_BASELINE_SNAPSHOT_S must be a positive integer (got: $SNAPSHOT_INTERVAL)" >&2
        exit 1
        ;;
esac

LLM_BACKEND="${STAGE2_BASELINE_LLM_BACKEND:-claude}"

# --- Prerequisite checks ---
for bin in agentis jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "run-baseline: $bin not found on PATH" >&2
        exit 1
    fi
done

# --- Calibration: parse calibration.toml and export to env ---
CALIBRATION="$FED_DIR/calibration.toml"
if [ ! -f "$CALIBRATION" ]; then
    echo "run-baseline: calibration.toml not found at $CALIBRATION" >&2
    exit 1
fi

INITIAL_CB="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy initial_cb 1000)"
BASE_COST="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy base_replication_cost 100)"
K_MALTHUSIAN="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy k_malthusian 3)"
MAX_REPLICAS="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy max_replicas_per_tribe 5)"
REWARD_FULL="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward full 200)"
REWARD_SUBSEQUENT="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward subsequent 50)"
DEATH_THRESHOLD="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.death threshold 100)"

# Plan Decision 1: BASELINE_CB = 5 * initial_cb so the single-tribe baseline
# burns the same total compute envelope as the 5-tribe ecosystem.
BASELINE_CB="$((INITIAL_CB * 5))"

export INITIAL_CB BASE_COST K_MALTHUSIAN MAX_REPLICAS REWARD_FULL REWARD_SUBSEQUENT DEATH_THRESHOLD

echo "[run-baseline] total CB: $BASELINE_CB"

# --- Per-run hermetic directory under runs/baseline-<ts>/ ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/baseline-$TS"
mkdir -p "$RUN_DIR" "$RUN_DIR/snapshots" "$RUN_DIR/tribe-baseline/agents" "$RUN_DIR/tribe-baseline/scripts" "$RUN_DIR/tribe-baseline/config"

echo "[run-baseline] run dir: $RUN_DIR"
echo "[run-baseline] wall-clock cap: ${WALL_CLOCK}s"
echo "[run-baseline] snapshot interval: ${SNAPSHOT_INTERVAL}s"
echo "[run-baseline] llm backend: $LLM_BACKEND"

# --- Materialise tribe-baseline from template (python3 substitution) ---
TARGET_DIR="$FED_DIR/targets/stage2/smallvec-v0.6.13"
VERIFIER_PATH="$FED_DIR/tools/verify-finding-stage2.sh"
BUG_LEDGER_PATH="$RUN_DIR/bug-ledger.jsonl"

TEMPLATE_DIR="$FED_DIR/templates/tribe-baseline"
if [ ! -d "$TEMPLATE_DIR" ]; then
    echo "run-baseline: template dir missing at $TEMPLATE_DIR" >&2
    exit 1
fi

python3 "$TOOLS_DIR/run-baseline-render.py" \
    "$TEMPLATE_DIR/colony.toml.template" \
    "$RUN_DIR/tribe-baseline/config/colony.toml" \
    "CB_BUDGET=$BASELINE_CB" \
    "LLM_BACKEND=$LLM_BACKEND" \
    "TARGET_DIR=$TARGET_DIR" \
    "VERIFIER_PATH=$VERIFIER_PATH" \
    "BUG_LEDGER_PATH=$BUG_LEDGER_PATH"

# #404: rewrite cb_budget in the rendered baseline colony.toml from
# INITIAL_CB so the per-tick budget matches the calibration default
# (the hunter-baseline.ag `cb <N>;` keeps BASELINE_CB = 5 * INITIAL_CB
# as its lifetime CB pool — different concept from the per-tick budget).
python3 "$TOOLS_DIR/run-stage2-rewrite-cb.py" \
    "$RUN_DIR/tribe-baseline/config/colony.toml" "$INITIAL_CB" || {
    echo "run-baseline: failed to rewrite cb_budget in baseline colony.toml" >&2
    exit 1
}

python3 "$TOOLS_DIR/run-baseline-render.py" \
    "$TEMPLATE_DIR/agents/hunter-baseline.ag.template" \
    "$RUN_DIR/tribe-baseline/agents/hunter-baseline.ag" \
    "CB_BUDGET=$BASELINE_CB" \
    "LLM_BACKEND=$LLM_BACKEND" \
    "TARGET_DIR=$TARGET_DIR" \
    "VERIFIER_PATH=$VERIFIER_PATH" \
    "BUG_LEDGER_PATH=$BUG_LEDGER_PATH"

# --- Hermetic .agentis/ root inside run dir ---
(
    cd "$RUN_DIR"
    if [ ! -d .agentis ]; then
        agentis init >/dev/null 2>&1
    fi
)

AGENTIS_ROOT="$RUN_DIR/.agentis"
export AGENTIS_ROOT

# #409: file_read() sandbox is hardcoded to <agentis_root>/sandbox/. Copy
# the Stage 2 target tree INTO sandbox (symlink fails because the runtime
# canonicalizes the candidate path before the sandbox-containment check —
# a symlink dereferences to its outside-sandbox target). Resume path
# refreshes the copy so a target-tree edit during a paused run doesn't
# desync.
SANDBOX_DIR="$AGENTIS_ROOT/sandbox"
mkdir -p "$SANDBOX_DIR"
rm -rf "$SANDBOX_DIR/targets-stage2"
cp -r "$FED_DIR/targets/stage2" "$SANDBOX_DIR/targets-stage2"
export TARGET_DIR_SANDBOX="targets-stage2/smallvec-v0.6.13"

# Configure config so analyse-stage2.py can find inputs.
CONFIG_FILE="$RUN_DIR/.agentis/config"
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q '^exec\.env_passthrough' "$CONFIG_FILE"; then
        printf '\nexec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,TARGET_FILE,BUGS_MANIFEST,VERIFIER_PATH,RUN_DIR,BUG_LEDGER_PATH,INITIAL_CB,BASE_COST,K_MALTHUSIAN,MAX_REPLICAS,REWARD_FULL,REWARD_SUBSEQUENT,DEATH_THRESHOLD,AGENTIS_ROOT\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^experience\.enabled' "$CONFIG_FILE"; then
        printf 'experience.enabled = true\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^telemetry\.enabled' "$CONFIG_FILE"; then
        printf 'telemetry.enabled = true\n' >> "$CONFIG_FILE"
    fi
fi

# --- Export env consumed by hunter-baseline.ag via exec sh ---
export TARGET_DIR
export TARGET_FILE="lib.rs"

# Seed hunter:confidence to 0.7 (mid-propose). #405: hunter:target_dir +
# hunter:target_file feed the recall_latest() + file_read() path that
# replaces the old `exec sh "cat $TARGET_DIR/$TARGET_FILE"` (blocked by
# exec_foreign denial on agentis 1.6.0). #409: seed the sandbox-relative
# path so file_read() can reach the target through the in-sandbox copy.
(
    cd "$RUN_DIR"
    agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true
    agentis memo set "hunter:target_dir" "$TARGET_DIR_SANDBOX" >/dev/null 2>&1 || true
    agentis memo set "hunter:target_file" "$TARGET_FILE" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:pool" "$BASELINE_CB" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:size" "1" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:reward_full" "$REWARD_FULL" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:reward_subsequent" "$REWARD_SUBSEQUENT" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:death_threshold" "$DEATH_THRESHOLD" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:bug_ledger" "$BUG_LEDGER_PATH" >/dev/null 2>&1 || true
    agentis memo set "tribe-tribe-baseline:run_dir" "$RUN_DIR" >/dev/null 2>&1 || true
    agentis memo set "reputation:tribes-bench-tribe-baseline" "0.5" >/dev/null 2>&1 || true
)

export BUGS_MANIFEST="$FED_DIR/targets/stage2/bugs.json"
export VERIFIER_PATH
export RUN_DIR
export BUG_LEDGER_PATH
export TRIBE_NAME="tribe-baseline"

: > "$BUG_LEDGER_PATH"

if [ ! -f "$TARGET_DIR/$TARGET_FILE" ]; then
    echo "run-baseline: target source not found at $TARGET_DIR/$TARGET_FILE" >&2
    exit 1
fi
if [ ! -f "$BUGS_MANIFEST" ]; then
    echo "run-baseline: bugs manifest not found at $BUGS_MANIFEST" >&2
    exit 1
fi
if [ ! -x "$VERIFIER_PATH" ]; then
    echo "run-baseline: verifier not executable at $VERIFIER_PATH" >&2
    exit 1
fi

# Capture agentis version + llm backend + run-meta.
agentis --version > "$RUN_DIR/agentis-version.txt" 2>&1 || true
printf '%s\n' "$LLM_BACKEND" > "$RUN_DIR/llm-backend.txt"

STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
python3 "$TOOLS_DIR/run-baseline-meta.py" \
    "$RUN_DIR/run-meta.json" \
    "$STARTED_AT" \
    "$WALL_CLOCK" \
    "$SNAPSHOT_INTERVAL" \
    "$LLM_BACKEND" \
    "$BASELINE_CB" \
    "baseline"

# --- Launch the baseline daemon directly (no start-federation.sh; the
# baseline tribe lives outside <fed>/tribe-* and would not be picked up
# by the COLONIES array). One daemon = one hunter-baseline. ---
echo "[run-baseline] launching baseline tribe..."
(
    cd "$RUN_DIR"
    agentis daemon "$RUN_DIR/tribe-baseline/agents/hunter-baseline.ag" \
        --colony tribe-baseline \
        --enable-exec \
        --enable-messaging \
        --tick-interval 60000 >>"$RUN_DIR/start-baseline.log" 2>&1
) &
FED_PID=$!

sleep 5

if ! kill -0 "$FED_PID" 2>/dev/null; then
    echo "run-baseline: baseline daemon exited early; see $RUN_DIR/start-baseline.log" >&2
    exit 2
fi

# --- Sleep wall-clock cap with periodic snapshots ---
echo "[run-baseline] sleeping ${WALL_CLOCK}s with snapshots every ${SNAPSHOT_INTERVAL}s..."
elapsed=0
while [ "$elapsed" -lt "$WALL_CLOCK" ]; do
    remaining=$((WALL_CLOCK - elapsed))
    if [ "$remaining" -gt "$SNAPSHOT_INTERVAL" ]; then
        sleep "$SNAPSHOT_INTERVAL"
        elapsed=$((elapsed + SNAPSHOT_INTERVAL))
    else
        sleep "$remaining"
        elapsed="$WALL_CLOCK"
    fi
    snap_path="$RUN_DIR/snapshots/${elapsed}.txt"
    bash "$TOOLS_DIR/snapshot-stanza.sh" "$RUN_DIR" "$elapsed" > "$snap_path" 2>/dev/null || true
    echo "[run-baseline] snapshot $snap_path"
done

# --- Reliable shutdown via tools/kill-federation.sh ---
echo "[run-baseline] stopping baseline..."
KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
if [ -x "$KILL_SCRIPT" ]; then
    bash "$KILL_SCRIPT" --fed-dir "$FED_DIR" --no-backup >>"$RUN_DIR/kill-federation.log" 2>&1 || true
else
    echo "run-baseline: kill-federation.sh not found at $KILL_SCRIPT — falling back to kill" >&2
    kill "$FED_PID" 2>/dev/null || true
fi

wait "$FED_PID" 2>/dev/null || true

# --- Telemetry ---
echo "[run-baseline] analysing run..."
ANALYSER="$TOOLS_DIR/analyse-stage2.py"
if ! python3 "$ANALYSER" "$RUN_DIR"; then
    echo "run-baseline: analyse-stage2.py failed" >&2
    exit 3
fi

echo "[run-baseline] done."
echo "[run-baseline] telemetry: $RUN_DIR/telemetry.csv"
echo "[run-baseline] bug-ledger: $RUN_DIR/bug-ledger.jsonl"
