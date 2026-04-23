#!/bin/bash
# Start the Implementation colony (part of Dev Apprenticeship federation)
#
# Each agent runs as a separate agentis daemon process.
# They discover each other via colony UDP and communicate over TCP emit/listen.
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#
# --restart-agent mode (#257) respawns exactly one agent with the full colony
# env, skips log truncation and memo seeding (those are full-colony bootstrap
# concerns), and exits 0 on success with a single "started ... pid=... tick=..."
# line on stdout for the dashboard to parse. Exit codes: 0=ok, 2=unknown flag,
# 3=unknown agent name for this colony, 4=daemon launch failure.

set -e

# Parse flags. --restart-agent <name> swaps the script into single-agent
# respawn mode. Positional arg (if any) remains the config path, for
# backwards compatibility with pre-#257 callers.
RESTART_AGENT=""
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --restart-agent)
            if [ -z "${2:-}" ]; then
                echo "start-colony.sh: --restart-agent requires an agent name" >&2
                exit 2
            fi
            RESTART_AGENT="$2"
            shift 2
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "start-colony.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
set -- "${POSITIONAL[@]}"

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

# #225: configurable trigger label for assigned-issues filter. Empty if
# not configured (pre-#225 setups); gitlab-api.sh falls back to the
# hardcoded default "implementation" via ${VAR:-implementation}.
IMPLEMENTATION_TRIGGER_LABEL=$(parse_toml implementation trigger_label)

# #224: primary branch name. Empty if not configured (pre-#224 setups);
# gitlab-api.sh falls back to the hardcoded default "main" via
# ${GITLAB_DEFAULT_BRANCH:-main}.
GITLAB_DEFAULT_BRANCH=$(parse_toml gitlab default_branch)

export GITLAB_URL
export GITLAB_TOKEN
export GITLAB_PROJECT
export GITLAB_ME
export IMPLEMENTATION_TRIGGER_LABEL
export GITLAB_DEFAULT_BRANCH
export COLONY_DIR

AGENTS=(
    code_writer
    test_writer
    refactorer
    commit_composer
)

# Opt-in log truncation. Off by default so operators who rely on log
# history across restarts are not surprised. Set TRUNCATE_LOGS=1 in
# the environment (or via start-federation.sh) to bound disk use
# between manual restarts. Real log rotation should use the
# logrotate.conf sample in ops/ instead; this is the zero-config
# fallback for laptops that do not have logrotate configured.
# #257: skip on single-agent respawn — log truncation is a full-colony
# fresh-start concern; clobbering a single agent's log surprises operators
# and erases the timeline the dashboard is about to render.
if [ -z "$RESTART_AGENT" ] && [ "${TRUNCATE_LOGS:-0}" = "1" ]; then
    AGENTIS_LOGS="$REPO_ROOT/dev-apprenticeship/.agentis/logs"
    if [ -d "$AGENTIS_LOGS" ]; then
        for agent in "${AGENTS[@]}"; do
            : > "$AGENTIS_LOGS/${agent}.log" 2>/dev/null || true
        done
    fi
fi

# Note: LLM backend is read by agentis daemon from the llm.backend key in
# .agentis/config, not from a CLI flag. The [llm] section in colony.toml is
# informational only. Operators should mirror it into .agentis/config.
# `--enable-exec` is required since agentis v1.1.6 (exec sh is opt-in; see #484/#489).
# `--enable-messaging` is required for cross-agent emit/listen (#484, v1.1.6+).

# Per-agent tick-interval override (#146). All implementation agents are
# active: code_writer, test_writer, refactorer and commit_composer each
# run against the current working tree and produce output every tick once
# fed by upstream route_suggestion events. 60s keeps the write-test-commit
# pipeline responsive. Fallback is 60000ms.
tick_interval_for() {
    case "$1" in
        *) echo 60000 ;;
    esac
}

# #257: single-agent respawn path. Dashboard's /restart endpoint delegates
# here instead of reading [gitlab] config itself. All env exports above
# already happened; we validate the agent name, launch exactly one daemon,
# emit one parseable line on stdout, and exit.
if [ -n "$RESTART_AGENT" ]; then
    valid=0
    for a in "${AGENTS[@]}"; do
        [ "$a" = "$RESTART_AGENT" ] && valid=1
    done
    if [ "$valid" = "0" ]; then
        echo "start-colony.sh: unknown agent '$RESTART_AGENT' for this colony" >&2
        exit 3
    fi
    tick=$(tick_interval_for "$RESTART_AGENT")
    # Detach daemon stdio from any inherited pipes (e.g. the dashboard's
    # subprocess.run(capture_output=True) pipes). Without this, the daemon
    # keeps those fds open after start-colony.sh exits, and the Python
    # caller blocks on read until its own timeout — reporting spurious
    # "restart failed" even though the agent came up fine.
    agentis daemon "$COLONY_DIR/agents/${RESTART_AGENT}.ag" \
        --colony implementation \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$tick" </dev/null >/dev/null 2>&1 &
    agent_pid=$!
    sleep 0.5
    if ! kill -0 "$agent_pid" 2>/dev/null; then
        echo "start-colony.sh: agentis daemon failed to launch $RESTART_AGENT" >&2
        exit 4
    fi
    echo "started $RESTART_AGENT pid=$agent_pid tick=$tick"
    exit 0
fi

echo "Starting Implementation colony (${#AGENTS[@]} agents)..."
echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)"

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony implementation \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2  # stagger starts to reduce API contention
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
