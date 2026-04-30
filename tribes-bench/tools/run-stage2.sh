#!/bin/bash
# run-stage2.sh — One-shot Stage 2 harness (#392 M1).
#
# Stage 2 M1 is pure infrastructure: 5 tribes (alpha + beta + gamma +
# delta + epsilon) scanning the vendored real-world `smallvec v0.6.13`
# target under `targets/stage2/smallvec-v0.6.13/`, verified by the
# distinct `tools/verify-finding-stage2.sh` (Stage 0/1 verifier
# unchanged for back-compat). Calibration parameters are unchanged from
# Stage 1; the federation-wide CB pool delta is zero (each tribe gets
# its own `initial_cb`).
#
# Mirrors run-stage1.sh: reads economy parameters from
# tribes-bench/calibration.toml, exports them into the federation
# environment so each tribe's start-colony.sh can seed the
# corresponding per-tribe memos, captures a periodic snapshot every
# 600s into runs/<ts>/snapshots/<elapsed>.txt, and finally drives
# tools/analyse-stage2.py at the end.
#
# Env vars:
#   STAGE2_WALL_CLOCK_S    Wall-clock cap in seconds (default: 3600)
#   STAGE2_LLM_BACKEND     Override [llm].backend in colony.toml
#                          (default: leave config alone, which means cli)
#   STAGE2_SNAPSHOT_S      Snapshot interval in seconds (default: 600)
#
# Exit codes:
#   0  run completed and telemetry.csv produced
#   1  prerequisite missing (agentis CLI, jq, python3)
#   2  start-federation.sh failed to launch
#   3  analyse-stage2.py failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

WALL_CLOCK="${STAGE2_WALL_CLOCK_S:-3600}"
case "$WALL_CLOCK" in
    ''|*[!0-9]*)
        echo "run-stage2: STAGE2_WALL_CLOCK_S must be a positive integer (got: $WALL_CLOCK)" >&2
        exit 1
        ;;
esac

SNAPSHOT_INTERVAL="${STAGE2_SNAPSHOT_S:-600}"
case "$SNAPSHOT_INTERVAL" in
    ''|*[!0-9]*)
        echo "run-stage2: STAGE2_SNAPSHOT_S must be a positive integer (got: $SNAPSHOT_INTERVAL)" >&2
        exit 1
        ;;
esac

# --- Prerequisite checks ---
for bin in agentis jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "run-stage2: $bin not found on PATH" >&2
        exit 1
    fi
done

# --- Calibration: parse calibration.toml and export to env ---
# We delegate calibration parsing to a small python helper to dodge the
# macOS bash 3.2 heredoc parser bug (CLAUDE.md "no heredocs in tools/*.sh"
# invariant). The helper uses pure stdlib tomllib (Python 3.11+) and
# falls back gracefully to documented defaults when keys are missing.
CALIBRATION="$FED_DIR/calibration.toml"
if [ ! -f "$CALIBRATION" ]; then
    echo "run-stage2: calibration.toml not found at $CALIBRATION" >&2
    exit 1
fi

INITIAL_CB="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy initial_cb 1000)"
BASE_COST="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy base_replication_cost 100)"
K_MALTHUSIAN="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy k_malthusian 3)"
MAX_REPLICAS="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.economy max_replicas_per_tribe 5)"
REWARD_FULL="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward full 200)"
REWARD_SUBSEQUENT="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.reward subsequent 50)"
DEATH_THRESHOLD="$(python3 "$TOOLS_DIR/run-stage1-calibration.py" "$CALIBRATION" tribe.death threshold 100)"

export INITIAL_CB BASE_COST K_MALTHUSIAN MAX_REPLICAS REWARD_FULL REWARD_SUBSEQUENT DEATH_THRESHOLD

# --- Per-run hermetic directory ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/$TS"
mkdir -p "$RUN_DIR" "$RUN_DIR/snapshots"

echo "[run-stage2] run dir: $RUN_DIR"
echo "[run-stage2] wall-clock cap: ${WALL_CLOCK}s"
echo "[run-stage2] snapshot interval: ${SNAPSHOT_INTERVAL}s"
echo "[run-stage2] calibration: initial_cb=$INITIAL_CB base_cost=$BASE_COST k=$K_MALTHUSIAN reward_full=$REWARD_FULL reward_subsequent=$REWARD_SUBSEQUENT death=$DEATH_THRESHOLD"

# Initialise a fresh .agentis/ inside the run dir so daemons walking up
# from cwd find this root rather than the operator's persistent store.
(
    cd "$RUN_DIR"
    if [ ! -d .agentis ]; then
        agentis init >/dev/null 2>&1
    fi
)

AGENTIS_ROOT="$RUN_DIR/.agentis"
export AGENTIS_ROOT

# Configure the hermetic .agentis/config so analyse-stage2.py can find
# the inputs it expects:
#   exec.env_passthrough — the Stage 0 trio (TARGET_DIR, BUGS_MANIFEST,
#       VERIFIER_PATH) plus Stage 1 calibration vars + RUN_DIR +
#       BUG_LEDGER_PATH.
#   experience.enabled — required so learn() rows land in
#       .agentis/experience/<agent-id>.jsonl.
#   telemetry.enabled — required so daemon.started / daemon.stopped /
#       agent.completed events land in .agentis/lifecycle/events.jsonl.
CONFIG_FILE="$RUN_DIR/.agentis/config"
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q '^exec\.env_passthrough' "$CONFIG_FILE"; then
        printf '\nexec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,BUGS_MANIFEST,VERIFIER_PATH,RUN_DIR,BUG_LEDGER_PATH,INITIAL_CB,BASE_COST,K_MALTHUSIAN,MAX_REPLICAS,REWARD_FULL,REWARD_SUBSEQUENT,DEATH_THRESHOLD,AGENTIS_ROOT\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^experience\.enabled' "$CONFIG_FILE"; then
        printf 'experience.enabled = true\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^telemetry\.enabled' "$CONFIG_FILE"; then
        printf 'telemetry.enabled = true\n' >> "$CONFIG_FILE"
    fi
fi

# Seed all five tribes' confidence memo to 0.7 (mid-`propose`) inside
# the hermetic root.
(
    cd "$RUN_DIR"
    agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true
)

# --- Make sure each tribe has a colony.toml (install.sh idempotent) ---
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    example="$FED_DIR/$tribe/config/colony.example.toml"
    target="$FED_DIR/$tribe/config/colony.toml"
    if [ ! -f "$target" ] && [ -f "$example" ]; then
        cp "$example" "$target"
    fi
done

# --- Export Stage 2 env consumed by hunter.ag via exec sh ---
export TARGET_DIR="$FED_DIR/targets/stage2/smallvec-v0.6.13"
export BUGS_MANIFEST="$FED_DIR/targets/stage2/bugs.json"
export VERIFIER_PATH="$FED_DIR/tools/verify-finding-stage2.sh"
export RUN_DIR
export BUG_LEDGER_PATH="$RUN_DIR/bug-ledger.jsonl"

# Touch the bug-ledger so JSONL append never races mkdir.
: > "$BUG_LEDGER_PATH"

if [ ! -f "$TARGET_DIR/lib.rs" ]; then
    echo "run-stage2: target source not found at $TARGET_DIR/lib.rs" >&2
    exit 1
fi
if [ ! -f "$BUGS_MANIFEST" ]; then
    echo "run-stage2: bugs manifest not found at $BUGS_MANIFEST" >&2
    exit 1
fi
if [ ! -x "$VERIFIER_PATH" ]; then
    echo "run-stage2: verifier not executable at $VERIFIER_PATH" >&2
    exit 1
fi

# --- Launch federation in the background, anchored at RUN_DIR ---
echo "[run-stage2] launching tribes..."
(
    cd "$RUN_DIR"
    "$FED_DIR/start-federation.sh" "$FED_DIR" >>"$RUN_DIR/start-federation.log" 2>&1
) &
FED_PID=$!

# Give start-federation.sh a moment to spawn child daemons.
sleep 5

if ! kill -0 "$FED_PID" 2>/dev/null; then
    echo "run-stage2: start-federation.sh exited early; see $RUN_DIR/start-federation.log" >&2
    exit 2
fi

# --- Sleep the wall-clock cap with periodic snapshots ---
echo "[run-stage2] sleeping ${WALL_CLOCK}s with snapshots every ${SNAPSHOT_INTERVAL}s..."
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
    {
        echo "# snapshot at elapsed=${elapsed}s"
        date -u +%Y-%m-%dT%H:%M:%SZ
        agentis daemon list --json 2>/dev/null || true
    } > "$snap_path" 2>&1 || true
    echo "[run-stage2] snapshot $snap_path"
done

# --- Reliable shutdown via tools/kill-federation.sh ---
echo "[run-stage2] stopping federation..."
KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
if [ -x "$KILL_SCRIPT" ]; then
    bash "$KILL_SCRIPT" --fed-dir "$FED_DIR" --no-backup >>"$RUN_DIR/kill-federation.log" 2>&1 || true
else
    echo "run-stage2: kill-federation.sh not found at $KILL_SCRIPT — falling back to kill" >&2
    kill "$FED_PID" 2>/dev/null || true
fi

# Reap the colony worker spawned by start-federation.sh.
if [ -f "$RUN_DIR/worker.pid" ]; then
    worker_pid="$(cat "$RUN_DIR/worker.pid" 2>/dev/null || echo)"
    if [ -n "$worker_pid" ]; then
        kill "$worker_pid" 2>/dev/null || true
    fi
fi

# Reap the start-federation wrapper if still alive.
wait "$FED_PID" 2>/dev/null || true

# --- Telemetry ---
echo "[run-stage2] analysing run..."
ANALYSER="$TOOLS_DIR/analyse-stage2.py"
if ! python3 "$ANALYSER" "$RUN_DIR"; then
    echo "run-stage2: analyse-stage2.py failed" >&2
    exit 3
fi

echo "[run-stage2] done."
echo "[run-stage2] telemetry: $RUN_DIR/telemetry.csv"
echo "[run-stage2] bug-ledger: $RUN_DIR/bug-ledger.jsonl"
