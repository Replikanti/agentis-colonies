#!/bin/bash
# start-federation.sh - Start all 5 colonies of the Dev Apprenticeship federation
#
# Launches triage, code-review, planning, implementation, and release colonies
# in sequence. Each colony starts its agents as background daemon processes.
#
# Usage: ./start-federation.sh [path/to/federation-dir]
#        ./start-federation.sh              # uses script's own directory

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="${1:-$SCRIPT_DIR}"

COLONIES=(triage code-review planning implementation release)

echo ""
echo "Dev Apprenticeship Federation"
echo "============================="
echo ""

# Pre-flight: check all configs exist
for colony in "${COLONIES[@]}"; do
    CONFIG="$FED_DIR/$colony/config/colony.toml"
    if [ ! -f "$CONFIG" ]; then
        echo "[!!] Missing config: $CONFIG"
        echo "     Run ./install.sh first."
        exit 1
    fi
done

# Start each colony
TOTAL_AGENTS=0
for colony in "${COLONIES[@]}"; do
    echo "Starting $colony colony..."
    "$FED_DIR/$colony/scripts/start-colony.sh" &
    COLONY_PID=$!
    # Count agents in this colony's config
    AGENT_COUNT=$(grep -c '^\[\[agents\]\]' "$FED_DIR/$colony/config/colony.toml" 2>/dev/null || echo 0)
    TOTAL_AGENTS=$((TOTAL_AGENTS + AGENT_COUNT))
    sleep 3  # stagger colony starts
done

echo ""
echo "============================="
echo "Federation started: 5 colonies, $TOTAL_AGENTS agents"
echo ""
echo "Monitor:  agentis colony status"
echo "Logs:     tail -f .agentis/logs/<agent_name>.log"
echo "Stop:     agentis daemon stop --all"
echo ""

wait
