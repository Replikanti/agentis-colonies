#!/bin/bash
# run-stage0.sh — One-shot Stage 0 wiring test (#363).
#
# Creates a hermetic per-run directory under tribes-bench/runs/<ts>/,
# initialises a fresh .agentis/ inside it, exports the Stage 0 env
# (TARGET_DIR, BUGS_MANIFEST, VERIFIER_PATH), launches both tribes via
# start-federation.sh, sleeps the wall-clock cap, kills the federation,
# then runs analyse-stage0.py to produce telemetry.csv. Prints the final
# summary path on stdout.
#
# Env vars:
#   STAGE0_WALL_CLOCK_S    Wall-clock cap in seconds (default: 900)
#   STAGE0_LLM_BACKEND     Override [llm].backend in colony.toml
#                          (default: leave config alone, which means cli)
#
# Exit codes:
#   0  run completed and telemetry.csv produced
#   1  prerequisite missing (agentis CLI, jq, python3)
#   2  start-federation.sh failed to launch
#   3  analyse-stage0.py failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

WALL_CLOCK="${STAGE0_WALL_CLOCK_S:-900}"
case "$WALL_CLOCK" in
    ''|*[!0-9]*)
        echo "run-stage0: STAGE0_WALL_CLOCK_S must be a positive integer (got: $WALL_CLOCK)" >&2
        exit 1
        ;;
esac

# --- Prerequisite checks ---
for bin in agentis jq python3; do
    if ! command -v "$bin" >/dev/null 2>&1; then
        echo "run-stage0: $bin not found on PATH" >&2
        exit 1
    fi
done

# --- Per-run hermetic directory ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/$TS"
mkdir -p "$RUN_DIR"

echo "[run-stage0] run dir: $RUN_DIR"
echo "[run-stage0] wall-clock cap: ${WALL_CLOCK}s"

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

# Configure the hermetic .agentis/config so analyse-stage0.py can find
# the inputs it expects:
#   exec.env_passthrough — the Stage 0 trio (TARGET_DIR, BUGS_MANIFEST,
#       VERIFIER_PATH) is dropped by the default forge-shaped passthrough
#       list, so add it explicitly. Without this the agent's
#       `cat $TARGET_DIR/...` expands to `cat /...`.
#   experience.enabled — required so learn() rows land in
#       .agentis/experience/<agent-id>.jsonl. Default is off on a fresh
#       init; enabling it is the contract analyse-stage0.py reads.
#   telemetry.enabled — required so daemon.started / daemon.stopped /
#       agent.completed events land in .agentis/lifecycle/events.jsonl,
#       which analyse-stage0.py joins by agent_id to derive
#       agents_alive + cb_balance per minute.
CONFIG_FILE="$RUN_DIR/.agentis/config"
if [ -f "$CONFIG_FILE" ]; then
    if ! grep -q '^exec\.env_passthrough' "$CONFIG_FILE"; then
        printf '\nexec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,BUGS_MANIFEST,VERIFIER_PATH\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^experience\.enabled' "$CONFIG_FILE"; then
        printf 'experience.enabled = true\n' >> "$CONFIG_FILE"
    fi
    if ! grep -q '^telemetry\.enabled' "$CONFIG_FILE"; then
        printf 'telemetry.enabled = true\n' >> "$CONFIG_FILE"
    fi
fi

# Seed both tribes' confidence memo to 0.7 (mid-`propose`) inside the
# hermetic root. Without this seed the tier resolver returns "dormant"
# on the first tick.
(
    cd "$RUN_DIR"
    agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true
)

# --- Make sure each tribe has a colony.toml (install.sh idempotent) ---
for tribe in tribe-alpha tribe-beta; do
    example="$FED_DIR/$tribe/config/colony.example.toml"
    target="$FED_DIR/$tribe/config/colony.toml"
    if [ ! -f "$target" ] && [ -f "$example" ]; then
        cp "$example" "$target"
    fi
done

# --- Export Stage 0 env consumed by hunter.ag via exec sh ---
export TARGET_DIR="$FED_DIR/targets/stage0"
export BUGS_MANIFEST="$TARGET_DIR/bugs.json"
export VERIFIER_PATH="$FED_DIR/tools/verify-finding.sh"

if [ ! -f "$TARGET_DIR/vulnerable.rs" ]; then
    echo "run-stage0: target source not found at $TARGET_DIR/vulnerable.rs" >&2
    exit 1
fi
if [ ! -f "$BUGS_MANIFEST" ]; then
    echo "run-stage0: bugs manifest not found at $BUGS_MANIFEST" >&2
    exit 1
fi
if [ ! -x "$VERIFIER_PATH" ]; then
    echo "run-stage0: verifier not executable at $VERIFIER_PATH" >&2
    exit 1
fi

# --- Launch federation in the background, anchored at RUN_DIR ---
echo "[run-stage0] launching tribes..."
(
    cd "$RUN_DIR"
    "$FED_DIR/start-federation.sh" "$FED_DIR" >>"$RUN_DIR/start-federation.log" 2>&1
) &
FED_PID=$!

# Give start-federation.sh a moment to spawn child daemons.
sleep 5

if ! kill -0 "$FED_PID" 2>/dev/null; then
    echo "run-stage0: start-federation.sh exited early; see $RUN_DIR/start-federation.log" >&2
    exit 2
fi

# --- Sleep the wall-clock cap ---
echo "[run-stage0] sleeping ${WALL_CLOCK}s..."
sleep "$WALL_CLOCK"

# --- Reliable shutdown via tools/kill-federation.sh ---
echo "[run-stage0] stopping federation..."
KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
if [ -x "$KILL_SCRIPT" ]; then
    bash "$KILL_SCRIPT" --fed-dir "$FED_DIR" --no-backup >>"$RUN_DIR/kill-federation.log" 2>&1 || true
else
    echo "run-stage0: kill-federation.sh not found at $KILL_SCRIPT — falling back to kill" >&2
    kill "$FED_PID" 2>/dev/null || true
fi

# Reap the start-federation wrapper if still alive.
wait "$FED_PID" 2>/dev/null || true

# --- Telemetry ---
echo "[run-stage0] analysing run..."
ANALYSER="$TOOLS_DIR/analyse-stage0.py"
if ! python3 "$ANALYSER" "$RUN_DIR"; then
    echo "run-stage0: analyse-stage0.py failed" >&2
    exit 3
fi

echo "[run-stage0] done."
echo "[run-stage0] telemetry: $RUN_DIR/telemetry.csv"
