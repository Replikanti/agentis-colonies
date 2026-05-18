#!/bin/bash
# Start the Explorer colony (part of the Math Foundry federation).
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

# Symlink-safe $0 resolution.
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

# Source parse-toml.sh: try <fed>/tools first, then <fed>/../tools (the
# latter is the in-repo layout; the former is for standalone tarball
# installs that ship tools/ inside the federation directory).
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

# Non-forge federation (ADR-0003). The explorer reads cached arxiv paper
# pairs prepared by `tools/run-foundry.sh` and runs Python code in the
# hermetic sandbox; no agent calls a forge API. `forge.type = "none"` in
# colony.example.toml opts out per ADR-0003.
COLONY_NAME="explorer"
HOLD_PERIOD="${HOLD_PERIOD:-4}"
DISCOVERY_LEDGER="${DISCOVERY_LEDGER:-}"

export COLONY_DIR COLONY_NAME HOLD_PERIOD DISCOVERY_LEDGER

AGENTS=(
    explorer
)

if [ ${#AGENTS[@]} -eq 0 ] && [ "$RATE_LIMIT_STATUS" = "0" ] && [ -z "$RESTART_AGENT" ]; then
    echo "No agents defined yet. Edit AGENTS=( ... ) in this script after creating .ag files." >&2
    exit 1
fi

# Per-agent tick-interval override. EXPLORER_TICK_MS env (set by the
# foundry orchestrator via `FOUNDRY_TICK_INTERVAL_S` math) lets one wall-
# clock second represent one foundry tick; default 60000ms for direct
# (non-orchestrator) launches.
tick_interval_for() {
    case "$1" in
        explorer) echo "${EXPLORER_TICK_MS:-60000}" ;;
        *) echo 60000 ;;
    esac
}

# --rate-limit-status mode (federation-dashboard 0.3.0).
if [ "$RATE_LIMIT_STATUS" = "1" ]; then
    if [ -x "$COLONY_DIR/scripts/forge-api.sh" ]; then
        exec "$COLONY_DIR/scripts/forge-api.sh" rate-limit-status
    fi
    echo '{"remaining": null, "limit": null, "reset_at": null, "error": "rate-limit-status not implemented for this colony"}'
    exit 0
fi

# --restart-agent mode (#257).
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
        --colony explorer \
        --enable-exec \
        --enable-messaging \
        --enable-replication \
        --allow-replica-replication \
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

# Per-colony economy seeds. Mirrors trading-binance pattern.
INITIAL_CB="${INITIAL_CB:-1000}"
BASE_COST="${BASE_COST:-100}"
K_MALTHUSIAN="${K_MALTHUSIAN:-3}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
REPRODUCTIVE_FITNESS_THRESHOLD="${REPRODUCTIVE_FITNESS_THRESHOLD:-100}"

agentis memo set "colony-${COLONY_NAME}:pool" "$INITIAL_CB" >/dev/null 2>&1 || true
agentis memo set "colony-${COLONY_NAME}:size" "1" >/dev/null 2>&1 || true
agentis memo set "colony-${COLONY_NAME}:replication_base_cost" "$BASE_COST" >/dev/null 2>&1 || true
agentis memo set "colony-${COLONY_NAME}:replication_k" "$K_MALTHUSIAN" >/dev/null 2>&1 || true
agentis memo set "colony-${COLONY_NAME}:max_replicas" "$MAX_REPLICAS" >/dev/null 2>&1 || true
agentis memo set "explorer:reproductive_fitness_threshold" "$REPRODUCTIVE_FITNESS_THRESHOLD" >/dev/null 2>&1 || true

# Seed propose-tier confidence so the explorer daemon ticks past dormant.
agentis memo set "explorer:confidence" "0.7" >/dev/null 2>&1 || true

echo "Starting Explorer colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony explorer \
        --enable-exec \
        --enable-messaging \
        --enable-replication \
        --allow-replica-replication \
        --tick-interval "$interval" &
    sleep 2
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
