#!/bin/bash
# Start the Monitor colony (part of the Dark Factory federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#
# The monitor colony runs three long-lived daemons (invariant-watcher,
# oracle-watcher, coordinator) that continuously WATCH a target EVM protocol and
# emit reasoned anomaly alerts on the bus (`monitor:alert`). NON-custodial /
# read-only: the watchers only READ chain state via `cast`/RPC; no agent signs a
# transaction or touches funds.
#
# ADR-0003 conformance: --restart-agent (#257) respawns one agent with the full
# colony env, skips memo seeding + log truncation. Exit codes: 0 ok, 2 unknown
# flag / missing arg, 3 unknown agent, 4 daemon launch failure. On success of a
# --restart-agent run, prints exactly one line `started <agent> pid=<n>
# tick=<ms>` for the dashboard's /restart endpoint to parse.
#
# Monitor inputs are passed via the environment (all optional; see
# config/colony.example.toml [monitor] and the colony README). With no
# MONITOR_CAST / MONITOR_RPC_URL a watcher reads nothing and only observes — it
# never raises a false alert:
#   MONITOR_CAST  MONITOR_RPC_URL                                 (shared reader)
#   MONITOR_TARGET MONITOR_INV_LHS_SIG MONITOR_INV_RHS_SIG ...    (invariant)
#   MONITOR_ORACLE MONITOR_ORACLE_PRICE_SIG MONITOR_ORACLE_TS_SIG (oracle)
#   MONITOR_WEBHOOK_URL                                           (notify.sh sink)

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

COLONY_NAME="monitor"

# Monitor environment contract (read by the .ag watchers via getenv inside the
# sandboxed `exec sh`). Each falls back to its current value or empty; a watcher
# with no reader configured simply observes and never raises a false alert.
MONITOR_CAST="${MONITOR_CAST:-}"
MONITOR_RPC_URL="${MONITOR_RPC_URL:-}"
MONITOR_TARGET="${MONITOR_TARGET:-}"
MONITOR_INV_LHS_SIG="${MONITOR_INV_LHS_SIG:-}"
MONITOR_INV_RHS_SIG="${MONITOR_INV_RHS_SIG:-}"
MONITOR_INV_RHS_CONST="${MONITOR_INV_RHS_CONST:-}"
MONITOR_INV_REL="${MONITOR_INV_REL:-}"
MONITOR_INV_MARGIN_BP="${MONITOR_INV_MARGIN_BP:-}"
MONITOR_INV_LABEL="${MONITOR_INV_LABEL:-}"
MONITOR_ORACLE="${MONITOR_ORACLE:-}"
MONITOR_ORACLE_PRICE_SIG="${MONITOR_ORACLE_PRICE_SIG:-}"
MONITOR_ORACLE_TS_SIG="${MONITOR_ORACLE_TS_SIG:-}"
MONITOR_ORACLE_MAX_AGE="${MONITOR_ORACLE_MAX_AGE:-}"
MONITOR_ORACLE_DEV_BP="${MONITOR_ORACLE_DEV_BP:-}"
MONITOR_ORACLE_MIN="${MONITOR_ORACLE_MIN:-}"
MONITOR_ORACLE_MAX="${MONITOR_ORACLE_MAX:-}"
MONITOR_ORACLE_LABEL="${MONITOR_ORACLE_LABEL:-}"
MONITOR_WEBHOOK_URL="${MONITOR_WEBHOOK_URL:-}"

export COLONY_DIR COLONY_NAME
export MONITOR_CAST MONITOR_RPC_URL
export MONITOR_TARGET MONITOR_INV_LHS_SIG MONITOR_INV_RHS_SIG MONITOR_INV_RHS_CONST
export MONITOR_INV_REL MONITOR_INV_MARGIN_BP MONITOR_INV_LABEL
export MONITOR_ORACLE MONITOR_ORACLE_PRICE_SIG MONITOR_ORACLE_TS_SIG MONITOR_ORACLE_MAX_AGE
export MONITOR_ORACLE_DEV_BP MONITOR_ORACLE_MIN MONITOR_ORACLE_MAX MONITOR_ORACLE_LABEL
export MONITOR_WEBHOOK_URL

AGENTS=(
    invariant-watcher
    oracle-watcher
    coordinator
)

# Per-agent tick interval. The watchers + coordinator all run at 60000ms by
# default; MONITOR_TICK_MS overrides all three for faster/slower polling.
tick_interval_for() {
    case "$1" in
        invariant-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        oracle-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        coordinator) echo "${MONITOR_TICK_MS:-60000}" ;;
        *) echo 60000 ;;
    esac
}

if ! command -v agentis >/dev/null 2>&1; then
    echo "start-colony.sh: agentis not found on PATH — install it before running the monitor." >&2
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
        --colony monitor \
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
# (ADR-0001 seeds fresh agents at shadow/0.4; propose lets the watchers emit
# draft alerts out of the box for a smoke run. Operators lower this to observe
# baselines first.)
for agent in "${AGENTS[@]}"; do
    agentis memo set "${agent}:confidence" "0.7" >/dev/null 2>&1 || true
done

echo "Starting Monitor colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony monitor \
        --enable-exec \
        --enable-messaging \
        --tick-interval "$interval" &
    sleep 2
done

echo "Colony started. Use 'agentis daemon list' to monitor."
echo "Stop with: agentis daemon stop --all"

wait
