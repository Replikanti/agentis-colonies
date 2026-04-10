#!/bin/bash
# Start the Triage colony (part of Dev Apprenticeship federation)
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

# Parse GitLab config from TOML and export for gitlab-api.sh
parse_toml() {
    grep "^$1 " "$CONFIG" 2>/dev/null | head -1 | sed 's/.*= *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' | tr -d ' '
}

GITLAB_URL=$(parse_toml "url")
GITLAB_TOKEN=$(parse_toml "token")
GITLAB_PROJECT_RAW=$(parse_toml "project")

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT_RAW" ]; then
    echo "Error: GitLab config incomplete in $CONFIG"
    echo "Required: url, token, project under [gitlab]"
    exit 1
fi

# URL-encode the project path (replace / with %2F)
GITLAB_PROJECT="${GITLAB_PROJECT_RAW//\//%2F}"

export GITLAB_URL
export GITLAB_TOKEN
export GITLAB_PROJECT
export COLONY_DIR

# Parse LLM backend
LLM_BACKEND=$(parse_toml "backend")

AGENTS=(
    issue_creator
    labeler
    prioritizer
    router
)

echo "Starting Triage colony (${#AGENTS[@]} agents)..."
echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)"
echo "  LLM: ${LLM_BACKEND:-mock}"

for agent in "${AGENTS[@]}"; do
    echo "  Starting $agent..."
    if [ -n "$LLM_BACKEND" ]; then
        agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
            --colony triage \
            --backend "$LLM_BACKEND" \
            --tick-interval 60000 \
            --enable-exec &
    else
        agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
            --colony triage \
            --tick-interval 60000 \
            --enable-exec &
    fi
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis colony status' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
