#!/bin/bash
# new-colony.sh: scaffold a new colony within a federation
#
# Usage: ./tools/new-colony.sh <federation> <colony-name>
# Example: ./tools/new-colony.sh dev-apprenticeship planning

set -euo pipefail

# Preflight: this script substitutes template placeholders with python3, and it
# creates the target directory before it does. Without this check a machine
# lacking python3 gets a half-built tree with raw placeholders left in it, and
# the re-run then refuses because the directory already exists.
if ! command -v python3 >/dev/null 2>&1; then
    echo "${0##*/}: python3 is required (used for template substitution)" >&2
    exit 2
fi

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

# Pretty names: "code-review" -> "Code Review". The `\u` escape and `\b` word
# boundary are GNU extensions; BSD sed has neither, so on macOS this produced
# "code review". Same helper as new-federation.sh.
pretty() { echo "$1" | sed 's/-/ /g' | awk '{for (i=1; i<=NF; i++) $i=toupper(substr($i,1,1)) substr($i,2)}1'; }
PRETTY_NAME="$(pretty "$COLONY")"
FED_PRETTY="$(pretty "$FEDERATION")"

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

2. Configure your forge (GitLab or GitHub) connection in \`colony.toml\` under \`[forge]\` and the matching \`[forge.<type>]\` block (see [ADR-0002](../../doc/adr/ADR-0002-forge-abstraction.md)).

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

# Forge configuration (post-#256, ADR-0002).
# Set type to either "gitlab" or "github" and fill in the matching block.
[forge]
type = "gitlab"

[forge.gitlab]
url = "https://gitlab.example.com"
token = "glpat-your-token-here"
project = "your-org/your-project"
me = "your-username"

# [forge.github]
# owner = "your-org"
# repo  = "your-repo"
# token = "ghp_your-token-here"
# me    = "your-username"

[llm]
# Only "backend" is read today. Keep "cli" — it means "use the agentis daemon
# default CLI adapter", which INHERITS the federation backend from
# .agentis/config (typically flat-cyborg, the flat-rate Claude PTY wrapper).
# Do not hardcode "flat-cyborg" here: that would override the federation
# default and break host-run federations that use the flat-cyborg-claude.sh
# wrapper. See CLAUDE.md "LLM backend".
backend = "cli"

# Agent definitions
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.

[[agents]]
name = "example_agent"
source = "agents/example_agent.ag"
cb_budget = 800
tick_interval_ms = 60000
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
# informational only. Operators should mirror it into .agentis/config.

# Per-agent tick-interval override (#146). Add cases here only for agents
# whose natural cadence differs from 60s. Reactive agents (those that poll
# for infrequent upstream events) typically go to 180000-300000ms; active
# agents producing work every tick stay at the 60000ms fallback.
# Uses a case statement instead of declare -A for bash 3.2 (macOS) compat.
tick_interval_for() {
    case "$1" in
        # example_reactive_agent) echo 300000 ;;
        *) echo 60000 ;;
    esac
}

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony COLONY_ID_PLACEHOLDER \
        --tick-interval "$interval" &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
OUTER

# Replace placeholders in start script
# python3 rather than `sed -i`, matching the precedent in tools/scaffold-agent.sh,
# tools/cost-cap.sh and tools/experience-transfer.sh. BSD `sed`'s -i takes a
# REQUIRED suffix argument, so the GNU form used here consumed the substitution
# expression as the backup suffix and then treated the target as the script —
# on macOS this scaffolder corrupted the file it was meant to fill in, silently,
# under `set -euo pipefail`.
NC_TARGET="$COL_PATH/scripts/start-colony.sh"
NC_TMP="$NC_TARGET.tmp.$$"
NC_TARGET="$NC_TARGET" NC_TMP="$NC_TMP" \
PRETTY_NAME="$PRETTY_NAME" FED_PRETTY="$FED_PRETTY" COLONY="$COLONY" \
python3 -c '
import os
src = open(os.environ["NC_TARGET"]).read()
for token, value in (
    ("COLONY_PLACEHOLDER",    os.environ["PRETTY_NAME"]),
    ("FED_PLACEHOLDER",       os.environ["FED_PRETTY"]),
    ("NAME_PLACEHOLDER",      os.environ["PRETTY_NAME"]),
    ("COLONY_ID_PLACEHOLDER", os.environ["COLONY"]),
):
    src = src.replace(token, value)
open(os.environ["NC_TMP"], "w").write(src)
'
mv "$NC_TMP" "$NC_TARGET"

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
