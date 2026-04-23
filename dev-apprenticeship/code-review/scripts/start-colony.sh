#!/bin/bash
# Start the Code Review colony (part of Dev Apprenticeship federation)
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

# Parse forge config from TOML via the shared helper.
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=../../../tools/parse-toml.sh
# shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
. "$REPO_ROOT/tools/parse-toml.sh"

# #256: forge backend selection. `[forge].type` picks which backend
# wrapper forge-api.sh dispatches to. Defaults to "gitlab" so pre-#256
# configs keep working unchanged. PR 5 of #256 ships the code-review
# colony's github-api.sh, so FORGE_TYPE=github is now live for
# code-review (the release colony still returns exit 99 "not
# implemented" until PR 6 lands).
FORGE_TYPE=$(parse_toml forge type)
FORGE_TYPE="${FORGE_TYPE:-gitlab}"

case "$FORGE_TYPE" in
    gitlab)
        # Prefer [forge.gitlab] (ADR-0002) if present; fall back to legacy
        # [gitlab] so pre-#256 configs keep working during the overlap window.
        GITLAB_URL=$(parse_toml forge.gitlab url)
        [ -z "$GITLAB_URL" ] && GITLAB_URL=$(parse_toml gitlab url)
        GITLAB_TOKEN=$(parse_toml forge.gitlab token)
        [ -z "$GITLAB_TOKEN" ] && GITLAB_TOKEN=$(parse_toml gitlab token)
        GITLAB_PROJECT_RAW=$(parse_toml forge.gitlab project)
        [ -z "$GITLAB_PROJECT_RAW" ] && GITLAB_PROJECT_RAW=$(parse_toml gitlab project)
        GITLAB_ME=$(parse_toml forge.gitlab me)
        [ -z "$GITLAB_ME" ] && GITLAB_ME=$(parse_toml gitlab me)

        if [ -z "$GITLAB_URL" ] || [ -z "$GITLAB_TOKEN" ] || [ -z "$GITLAB_PROJECT_RAW" ]; then
            echo "Error: GitLab config incomplete in $CONFIG"
            echo "Required: url, token, project under [forge.gitlab] (or legacy [gitlab])"
            exit 1
        fi

        # URL-encode the project path (replace / with %2F)
        GITLAB_PROJECT="${GITLAB_PROJECT_RAW//\//%2F}"

        export GITLAB_URL
        export GITLAB_TOKEN
        export GITLAB_PROJECT
        export GITLAB_ME
        ;;
    github)
        GITHUB_URL=$(parse_toml forge.github url)
        GITHUB_URL="${GITHUB_URL:-https://api.github.com}"
        GITHUB_OWNER=$(parse_toml forge.github owner)
        GITHUB_REPO=$(parse_toml forge.github repo)
        GITHUB_TOKEN=$(parse_toml forge.github token)
        GITHUB_ME=$(parse_toml forge.github me)

        if [ -z "$GITHUB_OWNER" ] || [ -z "$GITHUB_REPO" ] || [ -z "$GITHUB_TOKEN" ]; then
            echo "Error: GitHub config incomplete in $CONFIG"
            echo "Required: owner, repo, token under [forge.github]"
            exit 1
        fi

        GITLAB_PROJECT_RAW="$GITHUB_OWNER/$GITHUB_REPO"

        export GITHUB_URL
        export GITHUB_OWNER
        export GITHUB_REPO
        export GITHUB_TOKEN
        export GITHUB_ME
        ;;
    *)
        echo "Error: unknown [forge].type '$FORGE_TYPE' in $CONFIG (expected: gitlab|github)" >&2
        exit 1
        ;;
esac

export FORGE_TYPE
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

# #257: single-agent respawn path. Dashboard's /restart endpoint delegates
# here instead of reading [gitlab] config itself. All env exports above
# already happened (including the `cd "$COLONY_DIR"` above); we validate
# the agent name, launch exactly one daemon, emit one parseable line on
# stdout, and exit.
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
        --colony code-review \
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

echo "Starting Code Review colony (${#AGENTS[@]} agents)..."
case "$FORGE_TYPE" in
    gitlab) echo "  GitLab: $GITLAB_URL ($GITLAB_PROJECT_RAW)" ;;
    github) echo "  GitHub: $GITHUB_URL ($GITHUB_OWNER/$GITHUB_REPO)" ;;
esac

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
