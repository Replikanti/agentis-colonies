#!/bin/bash
# start-federation.sh — Start the Tribes Bench federation tribes.
#
# Launches every tribe in COLONIES in parallel by invoking each colony's
# start-colony.sh. The bench has no auto-promote sidecar, no cost-cap
# sidecar, no dashboard auto-launch. ADR-0003 expects the script to
# launch the federation and wait — that is all this does.
#
# Stage 0 (#363) shipped tribe-alpha + tribe-beta; Stage 1 M1 (#364)
# adds tribe-gamma. The default target stays targets/stage0/ (Stage 0
# back-compat); set TARGET_DIR/BUGS_MANIFEST in the env to point a run
# at targets/stage1/.
#
# Usage:
#   ./start-federation.sh [path/to/federation-dir]
#   ./start-federation.sh                 # uses script's own directory

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="${1:-$SCRIPT_DIR}"

COLONIES=(tribe-alpha tribe-beta tribe-gamma)

echo ""
echo "Tribes Bench Federation"
echo "======================="
echo ""

# Pre-flight: every tribe must have its colony.toml in place.
for colony in "${COLONIES[@]}"; do
    CONFIG="$FED_DIR/$colony/config/colony.toml"
    if [ ! -f "$CONFIG" ]; then
        echo "[!!] Missing config: $CONFIG"
        echo "     Run ./install.sh first."
        exit 1
    fi
done

# Refuse to start if a federation is already running under this directory.
# Stage 0 daemons would race the existing set for the same memo store.
if agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
    echo "[!!] A federation is already running under this directory."
    echo "     Stop it first:  agentis daemon stop --all"
    echo "     Inspect it:     agentis daemon list"
    exit 1
fi

TOTAL_AGENTS=0
for colony in "${COLONIES[@]}"; do
    echo "Starting $colony colony..."
    "$FED_DIR/$colony/scripts/start-colony.sh" &
    AGENT_COUNT=$(grep -c '^\[\[agents\]\]' "$FED_DIR/$colony/config/colony.toml" 2>/dev/null || echo 0)
    TOTAL_AGENTS=$((TOTAL_AGENTS + AGENT_COUNT))
    sleep 1
done

echo ""
echo "================================="
echo "Federation started: ${#COLONIES[@]} tribes, $TOTAL_AGENTS agents"
echo ""
echo "Stop with: tools/kill-federation.sh --fed-dir $FED_DIR"
echo ""

wait
