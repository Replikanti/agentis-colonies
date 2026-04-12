#!/bin/bash
# install.sh - Set up the Dev Apprenticeship federation
#
# Checks prerequisites, copies config templates, writes GitLab
# credentials into all 5 colony configs, and optionally seeds
# agent confidence values.
#
# Usage: ./install.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COLONIES=(triage code-review planning implementation release)
ALL_AGENTS=(
    router prioritizer labeler issue_creator
    logic_reviewer style_reviewer security_reviewer test_reviewer approval_decider
    scope_estimator risk_assessor task_decomposer plan_reviewer
    code_writer test_writer refactorer commit_composer
    ship_decider changelog_writer version_bumper release_checker
)

# --- Helpers ---

info()  { printf '  %s\n' "$*"; }
ok()    { printf '  [ok] %s\n' "$*"; }
fail()  { printf '  [!!] %s\n' "$*"; }
ask()   { printf '\n  %s ' "$1"; }

check_cmd() {
    if command -v "$1" >/dev/null 2>&1; then
        ok "$1 found ($(command -v "$1"))"
        return 0
    else
        fail "$1 not found"
        return 1
    fi
}

# --- 1. Prerequisites ---

echo ""
echo "Dev Apprenticeship - Federation Setup"
echo "======================================"
echo ""
echo "Checking prerequisites..."

MISSING=0
check_cmd agentis  || MISSING=1
check_cmd claude   || MISSING=1
check_cmd python3  || MISSING=1
check_cmd git      || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Missing prerequisites. Install them and re-run."
    echo ""
    info "agentis: https://github.com/Replikanti/agentis"
    info "claude:  https://claude.ai/download"
    info "python3: your system package manager"
    exit 1
fi

# Check agentis version (need >= 1.1.3 for memo set/get)
AGENTIS_VERSION=$(agentis --version 2>/dev/null | grep -oP 'v?\K[0-9]+\.[0-9]+\.[0-9]+' || echo "0.0.0")
info "agentis version: $AGENTIS_VERSION"

# --- 2. Copy configs ---

echo ""
echo "Setting up colony configs..."

for colony in "${COLONIES[@]}"; do
    CONFIG_DIR="$SCRIPT_DIR/$colony/config"
    if [ -f "$CONFIG_DIR/colony.toml" ]; then
        info "$colony: colony.toml already exists, skipping"
    else
        cp "$CONFIG_DIR/colony.example.toml" "$CONFIG_DIR/colony.toml"
        ok "$colony: created colony.toml"
    fi
done

# --- 3. GitLab credentials ---

echo ""
echo "GitLab configuration"
echo "All 5 colonies connect to the same GitLab project."
echo ""

ask "GitLab URL (e.g. https://gitlab.com):"
read -r GITLAB_URL
ask "GitLab project path (e.g. my-org/my-project):"
read -r GITLAB_PROJECT
ask "GitLab personal access token (glpat-...):"
read -rs GITLAB_TOKEN
echo ""

if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_PROJECT" ] || [ -z "$GITLAB_TOKEN" ]; then
    fail "All three fields are required."
    exit 1
fi

echo ""
echo "Writing credentials to colony configs..."

for colony in "${COLONIES[@]}"; do
    CONFIG="$SCRIPT_DIR/$colony/config/colony.toml"
    # Use python3 for safe in-place replacement (no sed -i portability issues)
    python3 - "$CONFIG" "$GITLAB_URL" "$GITLAB_TOKEN" "$GITLAB_PROJECT" <<'PY'
import sys
path, url, token, project = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
content = content.replace('https://gitlab.example.com', url)
content = content.replace('glpat-your-token-here', token)
content = content.replace('your-org/your-project', project)
with open(path, 'w') as f:
    f.write(content)
PY
    ok "$colony"
done

# --- 4. Initialize agentis (if not already done) ---

echo ""
if [ -d "$SCRIPT_DIR/../.agentis" ] || [ -d ".agentis" ]; then
    info "agentis already initialized"
else
    echo "Initializing agentis..."
    agentis init 2>/dev/null || true
    ok "agentis init"
fi

# --- 5. Seed confidence ---

echo ""
echo "Agent confidence seeding"
echo ""
echo "Agents start silent (confidence = 0.0). You choose the starting level:"
echo ""
echo "  0.5  - Observe only (recommended for first run)"
echo "  0.6  - Observe + emit suggestions for your review"
echo "  0.85 - Full autonomy (agents act on their own)"
echo "  skip - Do not seed, configure manually later"
echo ""

ask "Starting confidence [0.5]:"
read -r CONFIDENCE
CONFIDENCE="${CONFIDENCE:-0.5}"

if [ "$CONFIDENCE" != "skip" ]; then
    echo ""
    echo "Seeding all 21 agents at $CONFIDENCE..."
    for agent in "${ALL_AGENTS[@]}"; do
        agentis memo set "${agent}:confidence" "$CONFIDENCE" 2>/dev/null || true
    done
    ok "All agents seeded at $CONFIDENCE"
fi

# --- 6. LLM backend ---

echo ""
echo "LLM backend"
echo ""
info "The federation uses Claude via the agentis CLI backend."
info "Make sure your .agentis/config has:"
echo ""
echo "    llm.backend = cli"
echo "    llm.command = claude"
echo ""

# --- Done ---

echo ""
echo "======================================"
echo "Setup complete."
echo ""
echo "Start the federation:"
echo "  ./start-federation.sh"
echo ""
echo "Or start individual colonies:"
for colony in "${COLONIES[@]}"; do
    echo "  ./$colony/scripts/start-colony.sh"
done
echo ""
echo "Monitor:"
echo "  agentis colony status"
echo ""
