#!/bin/bash
# Start the Release colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage: ./scripts/start-colony.sh [--config path/to/colony.toml]

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Config not found: $CONFIG"
    echo "Copy config/colony.example.toml to config/colony.toml and edit it."
    exit 1
fi

AGENTS=(
    ship_decider
    changelog_writer
    version_bumper
    release_checker
)

echo "Starting Release colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    echo "  Starting $agent..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony release \
        --tick-interval 60000 &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis colony status' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
