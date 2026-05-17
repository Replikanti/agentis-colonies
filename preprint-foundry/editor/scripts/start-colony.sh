#!/bin/bash
# Start the Editor colony (part of the Preprint Foundry federation).
#
# The editor reads the abstract+intro from the introducer, the
# preliminaries+main from the theorist, and the reproducibility
# script+output from the computer, synthesises a single LaTeX
# main.tex (amsart class), runs latexmk -pdf, and (on first-pass
# compile failure) makes one repair pass via the LLM. Editor's
# cadence is intentionally slower (240s default) because latexmk is
# IO-heavy and the repair pass is a second LLM round-trip.
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#   ./scripts/start-colony.sh --rate-limit-status
#
# ADR-0003 conformance: --restart-agent (#257) respawns one agent with full
# colony env, skips memo seeding + log truncation; --rate-limit-status
# (federation-dashboard 0.3.0) execs forge-api.sh rate-limit-status. Exit
# codes: 0 ok, 2 unknown flag / missing arg, 3 unknown agent, 4 daemon
# launch failure.

set -e

RESTART_AGENT=""
RATE_LIMIT_STATUS=0
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
        --rate-limit-status)
            RATE_LIMIT_STATUS=1
            shift
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

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
FED_DIR="$(dirname "$COLONY_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Config not found: $CONFIG"
    echo "Copy config/colony.example.toml to config/colony.toml and edit it."
    exit 1
fi

PARSE_TOML=""
for cand in "$FED_DIR/tools/parse-toml.sh" "$FED_DIR/../tools/parse-toml.sh"; do
    if [ -f "$cand" ]; then
        PARSE_TOML="$cand"
        break
    fi
done
if [ -z "$PARSE_TOML" ]; then
    echo "Error: tools/parse-toml.sh not found in $FED_DIR/tools or $FED_DIR/../tools" >&2
    exit 1
fi
# shellcheck source=/dev/null
. "$PARSE_TOML"

COLONY_NAME="editor"
DISCOVERY_LEDGER="${DISCOVERY_LEDGER:-}"
PREPRINT_OUTPUT_ROOT="${PREPRINT_OUTPUT_ROOT:-}"
PREPRINT_AUTHOR_CONFIG="${PREPRINT_AUTHOR_CONFIG:-}"
PREPRINT_LATEXMK_MAX_PASSES="${PREPRINT_LATEXMK_MAX_PASSES:-3}"
DAEMON_ID="${DAEMON_ID:-1}"
export COLONY_DIR COLONY_NAME DISCOVERY_LEDGER PREPRINT_OUTPUT_ROOT PREPRINT_AUTHOR_CONFIG PREPRINT_LATEXMK_MAX_PASSES DAEMON_ID

AGENTS=(
    editor
)

if [ ${#AGENTS[@]} -eq 0 ] && [ "$RATE_LIMIT_STATUS" = "0" ] && [ -z "$RESTART_AGENT" ]; then
    echo "No agents defined yet. Edit AGENTS=( ... ) in this script after creating .ag files." >&2
    exit 1
fi

# Editor default cadence is 240s (latexmk is slow and the repair pass
# is a second LLM round-trip). Overridable via PREPRINT_EDITOR_TICK_MS.
tick_interval_for() {
    case "$1" in
        editor) echo "${PREPRINT_EDITOR_TICK_MS:-240000}" ;;
        *) echo 240000 ;;
    esac
}

if [ "$RATE_LIMIT_STATUS" = "1" ]; then
    if [ -x "$COLONY_DIR/scripts/forge-api.sh" ]; then
        exec "$COLONY_DIR/scripts/forge-api.sh" rate-limit-status
    fi
    echo '{"remaining": null, "limit": null, "reset_at": null, "error": "rate-limit-status not implemented for this colony"}'
    exit 0
fi

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
    agentis daemon "$COLONY_DIR/agents/${RESTART_AGENT}.ag" \
        --colony editor \
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

echo "Starting Editor colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony editor \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
