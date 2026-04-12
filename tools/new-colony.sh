#!/bin/bash
# new-colony.sh: scaffold a new colony within a federation
#
# Usage: ./tools/new-colony.sh <federation> <colony-name>
# Example: ./tools/new-colony.sh dev-apprenticeship planning

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    echo "Usage: $0 <federation> <colony-name>"
    echo "Example: $0 dev-apprenticeship planning"
    exit 1
}

if [ $# -ne 2 ]; then
    usage
fi

FEDERATION="$1"
COLONY="$2"
FED_PATH="$REPO_ROOT/$FEDERATION"
COL_PATH="$FED_PATH/$COLONY"

# Validate federation exists
if [ ! -d "$FED_PATH" ] || [ ! -f "$FED_PATH/README.md" ]; then
    echo "Error: federation '$FEDERATION' not found (no directory with README.md at $FED_PATH)"
    exit 1
fi

# Validate colony name
if [[ ! "$COLONY" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "Error: colony name must be lowercase alphanumeric with dashes (e.g. 'code-review')"
    exit 1
fi

# Check colony doesn't exist
if [ -d "$COL_PATH" ]; then
    echo "Error: colony '$COLONY' already exists at $COL_PATH"
    exit 1
fi

echo "Creating colony '$COLONY' in federation '$FEDERATION'..."

# Create directory structure
mkdir -p "$COL_PATH/agents" "$COL_PATH/config" "$COL_PATH/scripts"
touch "$COL_PATH/agents/.gitkeep"

# Pretty name: "code-review" -> "Code Review"
PRETTY_NAME=$(echo "$COLONY" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')
# Federation pretty name
FED_PRETTY=$(echo "$FEDERATION" | sed 's/-/ /g' | sed 's/\b\(.\)/\u\1/g')

# Generate README
cat > "$COL_PATH/README.md" << EOF
# $PRETTY_NAME Colony

> Part of the [$FED_PRETTY](../) federation.

<!-- TODO: Describe what this colony does and what agents it contains. -->

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| <!-- agent name --> | \`agents/example.ag\` | <!-- what it learns --> | ~N observations |

## Setup

1. Copy and edit the config:
   \`\`\`bash
   cp config/colony.example.toml config/colony.toml
   \`\`\`

2. Configure your GitLab connection in \`colony.toml\`.

3. Start the colony:
   \`\`\`bash
   ./scripts/start-colony.sh
   \`\`\`
EOF

# Generate config
cat > "$COL_PATH/config/colony.example.toml" << EOF
# $PRETTY_NAME Colony Configuration
#
# Part of the $FED_PRETTY federation.
# Copy to colony.toml and edit for your environment.

[colony]
name = "$COLONY"
tick_interval_ms = 60000

[gitlab]
url = "https://gitlab.example.com"
token = "glpat-your-token-here"
project = "your-org/your-project"

[llm]
# Only "backend" is read today. "cli" uses the agentis daemon default CLI adapter.
backend = "cli"

# Agent definitions
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.

# [[agents]]
# name = "example_agent"
# source = "agents/example_agent.ag"
# cb_budget = 800
# tick_interval_ms = 60000
EOF

# Generate start script
cat > "$COL_PATH/scripts/start-colony.sh" << 'OUTER'
#!/bin/bash
# Start the COLONY_PLACEHOLDER colony (part of FED_PLACEHOLDER federation)
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

# TODO: Add agent names here
AGENTS=(
)

if [ ${#AGENTS[@]} -eq 0 ]; then
    echo "No agents defined yet. Edit this script to add agents to the AGENTS array."
    exit 1
fi

echo "Starting NAME_PLACEHOLDER colony (${#AGENTS[@]} agents)..."

# Note: LLM backend is read by agentis daemon from the llm.backend key in
# .agentis/config, not from a CLI flag. The [llm] section in colony.toml is
# informational only — operators should mirror it into .agentis/config.

for agent in "${AGENTS[@]}"; do
    echo "  Starting $agent..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony COLONY_ID_PLACEHOLDER \
        --tick-interval 60000 &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis colony status' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
OUTER

# Replace placeholders in start script
sed -i "s/COLONY_PLACEHOLDER/$PRETTY_NAME/g" "$COL_PATH/scripts/start-colony.sh"
sed -i "s/FED_PLACEHOLDER/$FED_PRETTY/g" "$COL_PATH/scripts/start-colony.sh"
sed -i "s/NAME_PLACEHOLDER/$PRETTY_NAME/g" "$COL_PATH/scripts/start-colony.sh"
sed -i "s/COLONY_ID_PLACEHOLDER/$COLONY/g" "$COL_PATH/scripts/start-colony.sh"

chmod +x "$COL_PATH/scripts/start-colony.sh"

echo ""
echo "Colony scaffolded at $COL_PATH/"
echo ""
echo "Next steps:"
echo "  1. Edit $COL_PATH/README.md to describe the colony and its agents"
echo "  2. Edit $COL_PATH/config/colony.example.toml to add agent definitions"
echo "  3. Edit $COL_PATH/scripts/start-colony.sh to add agent names to AGENTS array"
echo "  4. Create .ag files in $COL_PATH/agents/"
echo "  5. Update $FED_PATH/README.md to add the new colony to the table"
