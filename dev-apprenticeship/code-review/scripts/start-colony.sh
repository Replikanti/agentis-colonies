#!/bin/bash
# Start the Code Review colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage: ./scripts/start-colony.sh [path/to/colony.toml]

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
# Accepts both flush ("key = ...") and indented ("  key = ...") TOML keys.
# Preserves internal whitespace in values (only trims surrounding whitespace
# and matching quotes). Stops at the first match and ignores inline comments.
parse_toml() {
    python3 - "$CONFIG" "$1" <<'PY'
import sys
path, key = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    for raw in f:
        line = raw.split("#", 1)[0].rstrip("\n")
        stripped = line.lstrip()
        if not stripped.startswith(key):
            continue
        rest = stripped[len(key):].lstrip()
        if not rest.startswith("="):
            continue
        value = rest[1:].strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
            value = value[1:-1]
        print(value)
        break
PY
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
    style_reviewer
    logic_reviewer
    security_reviewer
    test_reviewer
    approval_decider
)

cd "$COLONY_DIR"

echo "Starting Code Review colony (${#AGENTS[@]} agents)..."
echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)"
echo "  LLM: ${LLM_BACKEND:-mock}"

for agent in "${AGENTS[@]}"; do
    echo "  Starting $agent..."
    if [ -n "$LLM_BACKEND" ]; then
        agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
            --colony code-review \
            --backend "$LLM_BACKEND" \
            --tick-interval 60000 \
            --enable-exec &
    else
        agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
            --colony code-review \
            --tick-interval 60000 \
            --enable-exec &
    fi
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis colony status' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
