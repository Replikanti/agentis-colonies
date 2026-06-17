#!/bin/bash
# Start the Monitor colony (part of the Dark Factory federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#   ./scripts/start-colony.sh --restart-agent <name> [path/to/colony.toml]
#
# The monitor colony runs eight long-lived daemons (invariant-watcher,
# oracle-watcher, governance-watcher, liquidity-watcher, flow-watcher,
# pause-state-watcher, coordinator, notifier) that continuously WATCH a target
# EVM protocol and emit reasoned anomaly alerts on the bus (`monitor:alert`); the
# notifier (#1092) forwards each alert to scripts/notify.sh so a page is actually
# DELIVERED, and owns the liveness heartbeat + dead-man's switch (#1093).
# NON-custodial / read-only: the watchers only READ chain state via `cast`/RPC
# and the notifier only sends an OUTBOUND notification; no agent signs a
# transaction or touches funds.
#
# ADR-0003 conformance: --restart-agent (#257) respawns one agent with the full
# colony env, skips memo seeding + log truncation. Exit codes: 0 ok, 1 agentis
# not found, 2 unknown flag / missing arg, 3 unknown agent, 4 daemon launch
# failure. On success of a --restart-agent run, prints exactly one line
# `started <agent> pid=<n> tick=<ms>` for the dashboard's /restart endpoint to parse.
#
# Monitor inputs are passed via the environment (all optional; see
# config/colony.example.toml [monitor] and the colony README). With no
# MONITOR_CAST / MONITOR_RPC_URL a watcher reads nothing and only observes — it
# never raises a false alert:
#   MONITOR_CAST  MONITOR_RPC_URL                                 (shared reader)
#   MONITOR_RPC_URLS MONITOR_RPC_CONSENSUS MONITOR_CAST_READ      (RPC failover/consensus, #1098)
#   MONITOR_TARGET MONITOR_INV_LHS_SIG MONITOR_INV_RHS_SIG ...    (single invariant)
#   MONITOR_INV_SPEC                                              (derived invariant set, #1086)
#   MONITOR_ORACLE MONITOR_ORACLE_PRICE_SIG MONITOR_ORACLE_TS_SIG (oracle)
#   MONITOR_GOV_TARGET MONITOR_GOV_OWNER_SIG MONITOR_GOV_ROLE_SIG (governance, #1095)
#   MONITOR_GOV_TIMELOCK_SIG MONITOR_GOV_LABEL                    (governance, #1095)
#   MONITOR_LIQ_TARGET MONITOR_LIQ_SIG MONITOR_LIQ_DROP_BP ...    (liquidity, #1096)
#   MONITOR_FLOW_TARGET MONITOR_FLOW_SIG MONITOR_FLOW_OUT_BP ...  (flow, #1096)
#   MONITOR_PAUSE_TARGET MONITOR_PAUSE_SIG MONITOR_PAUSE_LABEL    (pause-state, #1096)
#   MONITOR_WEBHOOK_URL[/_WARN/_HIGH]                             (notify.sh sink + routing)
#   MONITOR_HEARTBEAT_INTERVAL_S MONITOR_DEADMAN_WINDOW_S         (notifier liveness)
#   MONITOR_NOTIFY_MAX_RETRIES MONITOR_NOTIFY_BACKOFF_S ...       (notify.sh hardening)

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
# RPC failover + read consensus (#1098). MONITOR_RPC_URLS is a comma-separated list
# of endpoints tried in order on failure; it falls back to the single MONITOR_RPC_URL.
# MONITOR_RPC_CONSENSUS ("" / 0 / 1 => first-success failover; >=2 => require N
# endpoints to AGREE before a value is returned). MONITOR_CAST_READ points the
# watchers at scripts/cast-read.sh, the ONE place that owns the failover + consensus;
# default it to this colony's wrapper so a single configured endpoint behaves exactly
# as before and adding endpoints/quorum is the only change needed for robustness.
MONITOR_RPC_URLS="${MONITOR_RPC_URLS:-}"
MONITOR_RPC_CONSENSUS="${MONITOR_RPC_CONSENSUS:-}"
MONITOR_CAST_READ="${MONITOR_CAST_READ:-$SCRIPT_DIR/cast-read.sh}"
MONITOR_TARGET="${MONITOR_TARGET:-}"
MONITOR_INV_LHS_SIG="${MONITOR_INV_LHS_SIG:-}"
MONITOR_INV_RHS_SIG="${MONITOR_INV_RHS_SIG:-}"
MONITOR_INV_RHS_CONST="${MONITOR_INV_RHS_CONST:-}"
MONITOR_INV_REL="${MONITOR_INV_REL:-}"
MONITOR_INV_MARGIN_BP="${MONITOR_INV_MARGIN_BP:-}"
MONITOR_INV_LABEL="${MONITOR_INV_LABEL:-}"
MONITOR_INV_SPEC="${MONITOR_INV_SPEC:-}"
MONITOR_ORACLE="${MONITOR_ORACLE:-}"
MONITOR_ORACLE_PRICE_SIG="${MONITOR_ORACLE_PRICE_SIG:-}"
MONITOR_ORACLE_TS_SIG="${MONITOR_ORACLE_TS_SIG:-}"
MONITOR_ORACLE_MAX_AGE="${MONITOR_ORACLE_MAX_AGE:-}"
MONITOR_ORACLE_DEV_BP="${MONITOR_ORACLE_DEV_BP:-}"
MONITOR_ORACLE_MIN="${MONITOR_ORACLE_MIN:-}"
MONITOR_ORACLE_MAX="${MONITOR_ORACLE_MAX:-}"
MONITOR_ORACLE_LABEL="${MONITOR_ORACLE_LABEL:-}"
# governance-watcher (#1095) — flags a CHANGE vs the learned baseline.
MONITOR_GOV_TARGET="${MONITOR_GOV_TARGET:-}"
MONITOR_GOV_OWNER_SIG="${MONITOR_GOV_OWNER_SIG:-}"
MONITOR_GOV_ROLE_SIG="${MONITOR_GOV_ROLE_SIG:-}"
MONITOR_GOV_TIMELOCK_SIG="${MONITOR_GOV_TIMELOCK_SIG:-}"
MONITOR_GOV_LABEL="${MONITOR_GOV_LABEL:-}"
# liquidity-watcher (#1096) — flags a reserve / TVL drop past a learned band.
MONITOR_LIQ_TARGET="${MONITOR_LIQ_TARGET:-}"
MONITOR_LIQ_SIG="${MONITOR_LIQ_SIG:-}"
MONITOR_LIQ_DROP_BP="${MONITOR_LIQ_DROP_BP:-}"
MONITOR_LIQ_LABEL="${MONITOR_LIQ_LABEL:-}"
# flow-watcher (#1096) — flags an abnormal net outflow burst over a window.
MONITOR_FLOW_TARGET="${MONITOR_FLOW_TARGET:-}"
MONITOR_FLOW_SIG="${MONITOR_FLOW_SIG:-}"
MONITOR_FLOW_OUT_BP="${MONITOR_FLOW_OUT_BP:-}"
MONITOR_FLOW_LABEL="${MONITOR_FLOW_LABEL:-}"
# pause-state-watcher (#1096) — flags a paused() / circuit-breaker transition.
MONITOR_PAUSE_TARGET="${MONITOR_PAUSE_TARGET:-}"
MONITOR_PAUSE_SIG="${MONITOR_PAUSE_SIG:-}"
MONITOR_PAUSE_LABEL="${MONITOR_PAUSE_LABEL:-}"
MONITOR_WEBHOOK_URL="${MONITOR_WEBHOOK_URL:-}"
# Alert delivery (notifier #1092 / #1093 / notify.sh hardening #1094). All
# optional; unset preserves the single-webhook stdout-fallback behaviour.
MONITOR_WEBHOOK_URL_WARN="${MONITOR_WEBHOOK_URL_WARN:-}"
MONITOR_WEBHOOK_URL_HIGH="${MONITOR_WEBHOOK_URL_HIGH:-}"
MONITOR_HEARTBEAT_INTERVAL_S="${MONITOR_HEARTBEAT_INTERVAL_S:-}"
MONITOR_DEADMAN_WINDOW_S="${MONITOR_DEADMAN_WINDOW_S:-}"
MONITOR_NOTIFY_MAX_RETRIES="${MONITOR_NOTIFY_MAX_RETRIES:-}"
MONITOR_NOTIFY_BACKOFF_S="${MONITOR_NOTIFY_BACKOFF_S:-}"
MONITOR_NOTIFY_DEDUP_COOLDOWN_S="${MONITOR_NOTIFY_DEDUP_COOLDOWN_S:-}"
MONITOR_NOTIFY_STATE_DIR="${MONITOR_NOTIFY_STATE_DIR:-}"

export COLONY_DIR COLONY_NAME
export MONITOR_CAST MONITOR_RPC_URL
export MONITOR_RPC_URLS MONITOR_RPC_CONSENSUS MONITOR_CAST_READ
export MONITOR_TARGET MONITOR_INV_LHS_SIG MONITOR_INV_RHS_SIG MONITOR_INV_RHS_CONST
export MONITOR_INV_REL MONITOR_INV_MARGIN_BP MONITOR_INV_LABEL MONITOR_INV_SPEC
export MONITOR_ORACLE MONITOR_ORACLE_PRICE_SIG MONITOR_ORACLE_TS_SIG MONITOR_ORACLE_MAX_AGE
export MONITOR_ORACLE_DEV_BP MONITOR_ORACLE_MIN MONITOR_ORACLE_MAX MONITOR_ORACLE_LABEL
export MONITOR_GOV_TARGET MONITOR_GOV_OWNER_SIG MONITOR_GOV_ROLE_SIG
export MONITOR_GOV_TIMELOCK_SIG MONITOR_GOV_LABEL
export MONITOR_LIQ_TARGET MONITOR_LIQ_SIG MONITOR_LIQ_DROP_BP MONITOR_LIQ_LABEL
export MONITOR_FLOW_TARGET MONITOR_FLOW_SIG MONITOR_FLOW_OUT_BP MONITOR_FLOW_LABEL
export MONITOR_PAUSE_TARGET MONITOR_PAUSE_SIG MONITOR_PAUSE_LABEL
export MONITOR_WEBHOOK_URL MONITOR_WEBHOOK_URL_WARN MONITOR_WEBHOOK_URL_HIGH
export MONITOR_HEARTBEAT_INTERVAL_S MONITOR_DEADMAN_WINDOW_S
export MONITOR_NOTIFY_MAX_RETRIES MONITOR_NOTIFY_BACKOFF_S
export MONITOR_NOTIFY_DEDUP_COOLDOWN_S MONITOR_NOTIFY_STATE_DIR

AGENTS=(
    invariant-watcher
    oracle-watcher
    governance-watcher
    liquidity-watcher
    flow-watcher
    pause-state-watcher
    coordinator
    notifier
)

# Per-agent tick interval. The watchers + coordinator all run at 60000ms by
# default; MONITOR_TICK_MS overrides them all for faster/slower polling.
tick_interval_for() {
    case "$1" in
        invariant-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        oracle-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        governance-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        liquidity-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        flow-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        pause-state-watcher) echo "${MONITOR_TICK_MS:-60000}" ;;
        coordinator) echo "${MONITOR_TICK_MS:-60000}" ;;
        notifier) echo "${MONITOR_TICK_MS:-60000}" ;;
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
