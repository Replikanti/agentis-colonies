#!/bin/bash
# Start the Code Review colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage: ./scripts/start-colony.sh [path/to/colony.toml]

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

# #104: operator identity. Empty if not configured (pre-#104 setups or
# operators who skipped the install.sh prompt); agents fall back to
# memo gitlab:me and tag everything as team when both are empty.
GITLAB_ME=$(parse_toml gitlab me)

export GITLAB_URL
export GITLAB_TOKEN
export GITLAB_PROJECT
export GITLAB_ME
export COLONY_DIR

AGENTS=(
    style_reviewer
    logic_reviewer
    security_reviewer
    test_reviewer
    approval_decider
)

# Opt-in log truncation. Off by default so operators who rely on log
# history across restarts are not surprised. Set TRUNCATE_LOGS=1 in
# the environment (or via start-federation.sh) to bound disk use
# between manual restarts. Real log rotation should use the
# logrotate.conf sample in ops/ instead; this is the zero-config
# fallback for laptops that do not have logrotate configured.
if [ "${TRUNCATE_LOGS:-0}" = "1" ]; then
    AGENTIS_LOGS="$REPO_ROOT/dev-apprenticeship/.agentis/logs"
    if [ -d "$AGENTIS_LOGS" ]; then
        for agent in "${AGENTS[@]}"; do
            : > "$AGENTIS_LOGS/${agent}.log" 2>/dev/null || true
        done
    fi
fi

cd "$COLONY_DIR"

# Note: LLM backend is read by agentis daemon from the llm.backend key in
# .agentis/config, not from a CLI flag. The [llm] section in colony.toml is
# informational only. Operators should mirror it into .agentis/config.
# `--enable-exec` is required since agentis v1.1.6 (exec sh is opt-in; see #484/#489).
# `--enable-messaging` is required for cross-agent emit/listen (#484, v1.1.6+).

# Per-agent tick-interval override (#146). Every agent in this colony is
# reactive: the four reviewers wait on implementation:mr_ready events, and
# approval_decider waits on their findings. When no MR is in flight the
# ticks are no-ops. 5-min cadence matches the natural rhythm of merge
# requests in a small team and cuts idle LLM spend ~5×. Fallback is 60000ms
# for any agent not listed.
tick_interval_for() {
    case "$1" in
        style_reviewer|logic_reviewer|security_reviewer|test_reviewer|approval_decider) echo 300000 ;;
        *) echo 60000 ;;
    esac
}

echo "Starting Code Review colony (${#AGENTS[@]} agents)..."
echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)"

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony code-review \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
