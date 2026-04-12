#!/bin/bash
# Start the Triage colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage: ./scripts/start-colony.sh [--config path/to/colony.toml]

set -e

# Resolve symlinks on $0 itself so the script works when invoked via a symlink.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Config not found: $CONFIG"
    echo "Copy config/colony.example.toml to config/colony.toml and edit it."
    exit 1
fi

# Parse GitLab config from TOML via the shared helper.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../tools/parse-toml.sh
# shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
. "$REPO_ROOT/tools/parse-toml.sh"

GITLAB_URL=$(parse_toml gitlab url)
GITLAB_TOKEN=$(parse_toml gitlab token)
GITLAB_PROJECT_RAW=$(parse_toml gitlab project)

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

AGENTS=(
    issue_creator
    labeler
    prioritizer
    router
)

# Note: LLM backend is read by agentis daemon from the llm.backend key in
# .agentis/config, not from a CLI flag. The [llm] section in colony.toml is
# informational only. Operators should mirror it into .agentis/config.
# exec sh is enabled by default on agentis daemon; there is no --enable-exec.

echo "Starting Triage colony (${#AGENTS[@]} agents)..."
echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)"

for agent in "${AGENTS[@]}"; do
    echo "  Starting $agent..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony triage \
        --tick-interval 60000 &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis colony status' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
