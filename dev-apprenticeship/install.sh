#!/bin/bash
# install.sh - Set up the Dev Apprenticeship federation
#
# Checks prerequisites, copies config templates, writes GitLab
# credentials into all 5 colony configs, and optionally seeds
# agent confidence values.
#
# Usage: ./install.sh

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONIES=(triage code-review planning implementation release)
ALL_AGENTS=(
    router prioritizer labeler issue_creator
    logic_reviewer style_reviewer security_reviewer test_reviewer approval_decider
    scope_estimator risk_assessor task_decomposer plan_reviewer
    code_writer test_writer refactorer commit_composer
    ship_decider changelog_writer version_bumper release_checker
)
MIN_VERSION="1.1.3"

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

# Compare two semver strings. Returns 0 if $1 >= $2.
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n -k3,3n -C
}

# --- 1. Prerequisites ---

echo ""
echo "Dev Apprenticeship - Federation Setup"
echo "======================================"
echo ""
echo "Checking prerequisites..."

MISSING=0
check_cmd agentis  || MISSING=1
check_cmd python3  || MISSING=1
check_cmd git      || MISSING=1

if [ "$MISSING" -eq 1 ]; then
    echo ""
    fail "Missing prerequisites. Install them and re-run."
    echo ""
    info "agentis: https://github.com/Replikanti/agentis"
    info "python3: your system package manager"
    exit 1
fi

# Check agentis version (need >= 1.1.3 for memo set/get)
AGENTIS_VERSION=$(agentis --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "0.0.0")
info "agentis version: $AGENTIS_VERSION (minimum: $MIN_VERSION)"

if ! version_gte "$AGENTIS_VERSION" "$MIN_VERSION"; then
    fail "agentis >= $MIN_VERSION required (memo set/get support). Please update."
    exit 1
fi

# --- 2. Copy configs ---

echo ""
echo "Setting up colony configs..."

CONFIGS_EXISTED=0
for colony in "${COLONIES[@]}"; do
    CONFIG_DIR="$SCRIPT_DIR/$colony/config"
    if [ -f "$CONFIG_DIR/colony.toml" ]; then
        info "$colony: colony.toml already exists"
        CONFIGS_EXISTED=$((CONFIGS_EXISTED + 1))
    else
        cp "$CONFIG_DIR/colony.example.toml" "$CONFIG_DIR/colony.toml"
        ok "$colony: created colony.toml"
    fi
done

if [ "$CONFIGS_EXISTED" -eq 5 ]; then
    echo ""
    ask "All configs already exist. Overwrite with fresh templates? [y/N]:"
    read -r OVERWRITE
    if [ "$OVERWRITE" = "y" ] || [ "$OVERWRITE" = "Y" ]; then
        for colony in "${COLONIES[@]}"; do
            cp "$SCRIPT_DIR/$colony/config/colony.example.toml" "$SCRIPT_DIR/$colony/config/colony.toml"
            ok "$colony: overwritten"
        done
    else
        info "Keeping existing configs. GitLab credentials will be updated."
    fi
fi

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
    # Write credentials by matching TOML keys (works on both fresh and existing configs)
    python3 - "$CONFIG" "$GITLAB_URL" "$GITLAB_TOKEN" "$GITLAB_PROJECT" <<'PY'
import sys, re
path, url, token, project = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    content = f.read()
content = re.sub(r'(url\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + url + '"', content)
content = re.sub(r'(token\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + token + '"', content)
content = re.sub(r'(project\s*=\s*)"[^"]*"', lambda m: m.group(1) + '"' + project + '"', content)
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
    # Validate: must be a number between 0.0 and 1.0
    if ! python3 -c "v=float('$CONFIDENCE'); assert 0.0 <= v <= 1.0" 2>/dev/null; then
        fail "Invalid confidence value: $CONFIDENCE (must be 0.0 to 1.0)"
        exit 1
    fi
    echo ""
    echo "Seeding all 21 agents at $CONFIDENCE..."
    SEED_FAILED=0
    for agent in "${ALL_AGENTS[@]}"; do
        if ! agentis memo set "${agent}:confidence" "$CONFIDENCE" 2>/dev/null; then
            fail "Failed to seed ${agent}:confidence"
            SEED_FAILED=1
        fi
    done
    if [ "$SEED_FAILED" -eq 1 ]; then
        fail "Some seeds failed. Is agentis initialized? Try: agentis init"
    else
        ok "All agents seeded at $CONFIDENCE"
    fi
fi

# --- 6. LLM backend ---

echo ""
echo "LLM backend"
echo ""
info "Agentis needs an LLM backend configured in .agentis/config."
info "Examples:"
echo ""
echo "    # Claude via CLI"
echo "    llm.backend = cli"
echo "    llm.command = claude"
echo ""
echo "    # Ollama (local)"
echo "    llm.backend = http"
echo "    llm.endpoint = http://localhost:11434/v1/chat/completions"
echo "    llm.model = llama3"
echo ""
echo "    # Any OpenAI-compatible API"
echo "    llm.backend = http"
echo "    llm.endpoint = https://api.example.com/v1/chat/completions"
echo "    llm.api_key_env = MY_API_KEY"
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
