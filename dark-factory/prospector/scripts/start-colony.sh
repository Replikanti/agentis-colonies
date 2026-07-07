#!/bin/bash
# Start the Prospector colony (part of the Dark Factory federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#
# The prospector colony runs four long-lived daemons (intake, source-classifier,
# value-scorer, coordinator) that QUALIFY candidate EVM protocols as MONITORING
# TARGETS by public on-chain/source signals — i.e. decide which candidates are
# worth standing up the `monitor` colony on, and why. NON-custodial / read-only:
# the agents only READ public source/ABI + on-chain state via `cast`/explorer; no
# agent signs a transaction or touches funds.
#
# ADR-0003 conformance: --restart-agent (#257) respawns one agent with the full
# colony env, skips memo seeding + log truncation. Exit codes: 0 ok, 1 agentis
# not found, 2 unknown flag / missing arg, 3 unknown agent, 4 daemon launch
# failure. On success of a --restart-agent run, prints exactly one line
# `started <agent> pid=<n> tick=<ms>` for the dashboard's /restart endpoint to parse.
#
# Prospector inputs are passed via the environment (all optional; see
# config/colony.example.toml [prospector] and the colony README). With no
# PROSPECTOR_ABI_CMD / PROSPECTOR_CAST an agent reads nothing and only observes —
# a candidate then classifies "no-read" and is never falsely qualified:
#   PROSPECTOR_CANDIDATES                                       (intake list)
#   PROSPECTOR_ABI_CMD                                          (source-classifier reader)
#   PROSPECTOR_CAST PROSPECTOR_RPC_URL PROSPECTOR_VALUE_SIG ... (value-scorer reader)
#   PROSPECTOR_BOUNTY_META                                      (coordinator bounty dimension, #1459)

set -e

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
set -- ${POSITIONAL[@]+"${POSITIONAL[@]}"}

# Symlink-safe $0 resolution.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
FED_DIR="$(dirname "$COLONY_DIR")"
CONFIG="${1:-$COLONY_DIR/config/colony.toml}"

if [ ! -f "$CONFIG" ]; then
    echo "Note: config not found ($CONFIG) — running with environment inputs only." >&2
    echo "      Copy config/colony.example.toml to config/colony.toml to silence this." >&2
fi

# Source parse-toml.sh: try <fed>/tools first, then <fed>/../tools (the latter is
# the in-repo layout; the former is for standalone tarball installs that ship
# tools/ inside the federation directory).
PARSE_TOML=""
for cand in "$FED_DIR/tools/parse-toml.sh" "$FED_DIR/../tools/parse-toml.sh"; do
    if [ -f "$cand" ]; then
        PARSE_TOML="$cand"
        break
    fi
done
if [ -n "$PARSE_TOML" ]; then
    # shellcheck source=/dev/null
    . "$PARSE_TOML"
fi

COLONY_NAME="prospector"

# Prospector environment contract (read by the .ag agents via getenv, and inside
# the sandboxed `exec sh` readers). Each falls back to its current value or empty;
# an agent with no reader configured simply observes and never falsely qualifies
# a candidate.
PROSPECTOR_CANDIDATES="${PROSPECTOR_CANDIDATES:-}"
PROSPECTOR_ABI_CMD="${PROSPECTOR_ABI_CMD:-}"
PROSPECTOR_CAST="${PROSPECTOR_CAST:-}"
PROSPECTOR_RPC_URL="${PROSPECTOR_RPC_URL:-}"
PROSPECTOR_VALUE_SIG="${PROSPECTOR_VALUE_SIG:-}"
PROSPECTOR_VALUE_FLOOR="${PROSPECTOR_VALUE_FLOOR:-}"
# Active-bounty metadata for the coordinator's bounty dimension (#1459); read-only, no egress.
PROSPECTOR_BOUNTY_META="${PROSPECTOR_BOUNTY_META:-}"

export COLONY_DIR COLONY_NAME
export PROSPECTOR_CANDIDATES PROSPECTOR_ABI_CMD
export PROSPECTOR_CAST PROSPECTOR_RPC_URL PROSPECTOR_VALUE_SIG PROSPECTOR_VALUE_FLOOR
export PROSPECTOR_BOUNTY_META

AGENTS=(
    intake
    source-classifier
    value-scorer
    coordinator
)

# Per-agent tick interval. All four run at 60000ms by default;
# PROSPECTOR_TICK_MS overrides all of them for faster/slower polling.
tick_interval_for() {
    case "$1" in
        intake) echo "${PROSPECTOR_TICK_MS:-60000}" ;;
        source-classifier) echo "${PROSPECTOR_TICK_MS:-60000}" ;;
        value-scorer) echo "${PROSPECTOR_TICK_MS:-60000}" ;;
        coordinator) echo "${PROSPECTOR_TICK_MS:-60000}" ;;
        *) echo 60000 ;;
    esac
}

if ! command -v agentis >/dev/null 2>&1; then
    echo "start-colony.sh: agentis not found on PATH — install it before running the prospector." >&2
    exit 1
fi

# --restart-agent mode (#257): respawn exactly one agent with the full colony
# env; skip memo seeding + log truncation (full-colony bootstrap concerns).
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
        --colony prospector \
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

# Seed propose-tier confidence so each daemon ticks past dormant on first launch.
# (ADR-0001 seeds fresh agents at shadow/0.4; propose lets the agents emit draft
# signals out of the box for a smoke run. Operators lower this to observe / score
# baselines first.)
for agent in "${AGENTS[@]}"; do
    agentis memo set "${agent}:confidence" "0.7" >/dev/null 2>&1 || true
done

echo "Starting Prospector colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony prospector \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
