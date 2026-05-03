#!/bin/bash
# Start the Tribe Alpha colony (part of the Tribes Bench federation).
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

# §9 risk 7: refuse start if the agentis runtime cannot reach the M2
# floor (knowledge_buy / knowledge_sell are not .ag builtins pre-v1.5.0).
"$(cd "$(dirname "$0")/../.." && pwd)/tools/check-agentis-version.sh"

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

# Stage 0 env wiring. tribes-bench is not a forge-backed federation: the
# only data source is a checked-in synthetic Rust file under TARGET_DIR
# scanned by the deterministic verifier under VERIFIER_PATH. The
# [forge].type = "github" stub in colony.example.toml is a colony-lint
# requirement only (lint relaxation tracked in #258 deferred bucket); no
# Stage 0 agent calls forge-api.sh.
TRIBE_NAME="tribe-alpha"
TARGET_DIR="${TARGET_DIR:-$FED_DIR/targets/stage0}"
TARGET_FILE="${TARGET_FILE:-vulnerable.rs}"
BUGS_MANIFEST="${BUGS_MANIFEST:-$TARGET_DIR/bugs.json}"
VERIFIER_PATH="${VERIFIER_PATH:-$FED_DIR/tools/verify-finding.sh}"

export COLONY_DIR TRIBE_NAME TARGET_DIR TARGET_FILE BUGS_MANIFEST VERIFIER_PATH

# Stage 0: a single hunter agent per tribe. See tribes-bench/README.md for
# the staircase Stage 0 -> 1 -> 2 plan.
AGENTS=(
    hunter
)

if [ ${#AGENTS[@]} -eq 0 ] && [ "$RATE_LIMIT_STATUS" = "0" ] && [ -z "$RESTART_AGENT" ]; then
    echo "No agents defined yet. Edit AGENTS=( ... ) in this script after creating .ag files." >&2
    exit 1
fi

# Per-agent tick-interval override. Stage 0 hunter agents tick at 60s for
# ~15 ticks per agent over the 900s wall-clock cap.
tick_interval_for() {
    case "$1" in
        hunter) echo 60000 ;;
        *) echo 60000 ;;
    esac
}

# --rate-limit-status mode (federation-dashboard 0.3.0). Replace with the
# real rate-limit primitive your data source exposes; the platform consumes
# the JSON contract `{remaining, limit, reset_at}` only.
if [ "$RATE_LIMIT_STATUS" = "1" ]; then
    if [ -x "$COLONY_DIR/scripts/forge-api.sh" ]; then
        exec "$COLONY_DIR/scripts/forge-api.sh" rate-limit-status
    fi
    echo '{"remaining": null, "limit": null, "reset_at": null, "error": "rate-limit-status not implemented for this colony"}'
    exit 0
fi

# --restart-agent mode (#257). Single-agent respawn, no log truncation,
# no memo seeding (those are full-colony bootstrap concerns).
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
        --colony tribe-alpha \
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

# Stage 1 M2+M3 memo seeds: per-tribe pool, replication cost knobs,
# reward levels, death threshold, bug-ledger path, run dir. All derive
# from env vars exported by tools/run-stage1.sh from calibration.toml;
# the `:-` defaults below match calibration.toml documented values so an
# operator can launch the federation directly without the harness for
# Stage 0 reruns or smoke tests.
INITIAL_CB="${INITIAL_CB:-1000}"
BASE_COST="${BASE_COST:-100}"
K_MALTHUSIAN="${K_MALTHUSIAN:-3}"
MAX_REPLICAS="${MAX_REPLICAS:-5}"
REWARD_FULL="${REWARD_FULL:-200}"
REWARD_SUBSEQUENT="${REWARD_SUBSEQUENT:-50}"
DEATH_THRESHOLD="${DEATH_THRESHOLD:-100}"
BUG_LEDGER_PATH="${BUG_LEDGER_PATH:-}"
RUN_DIR="${RUN_DIR:-}"
# #405: seed TARGET_DIR / TARGET_FILE as memos so hunter.ag can read them
# via recall_latest() + file_read() instead of `exec sh "cat $TARGET_DIR/..."`.
# agentis 1.6.0 has no env_get builtin, and exec_foreign denial blocked the
# old shell-cat path even with --enable-exec.
agentis memo set "hunter:target_dir" "$TARGET_DIR" >/dev/null 2>&1 || true
agentis memo set "hunter:target_file" "$TARGET_FILE" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:pool" "$INITIAL_CB" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:size" "1" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:replication_base_cost" "$BASE_COST" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:replication_k" "$K_MALTHUSIAN" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:max_replicas" "$MAX_REPLICAS" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:reward_full" "$REWARD_FULL" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:reward_subsequent" "$REWARD_SUBSEQUENT" >/dev/null 2>&1 || true
agentis memo set "tribe-${TRIBE_NAME}:death_threshold" "$DEATH_THRESHOLD" >/dev/null 2>&1 || true
if [ -n "$BUG_LEDGER_PATH" ]; then
    agentis memo set "tribe-${TRIBE_NAME}:bug_ledger" "$BUG_LEDGER_PATH" >/dev/null 2>&1 || true
fi
if [ -n "$RUN_DIR" ]; then
    agentis memo set "tribe-${TRIBE_NAME}:run_dir" "$RUN_DIR" >/dev/null 2>&1 || true
fi

# Stage 2 M2 (#393) cognitive-market memos. Initial reputation 0.5
# (mid-band per plan §2 bootstrap analysis); cb_surplus_threshold,
# bundle_period, pool_minimum_for_buy are calibration-tunable knobs
# documented in calibration.toml [knowledge_market].
agentis memo set "reputation:tribes-bench-${TRIBE_NAME}" "0.5" >/dev/null 2>&1 || true
agentis memo set "cb_surplus_threshold" "300" >/dev/null 2>&1 || true
agentis memo set "bundle_period" "3" >/dev/null 2>&1 || true
agentis memo set "pool_minimum_for_buy" "50" >/dev/null 2>&1 || true
if [ -n "$RUN_DIR" ]; then
    agentis memo set "tribes-bench-${TRIBE_NAME}:knowledge_market_csv" "$RUN_DIR/knowledge-market.csv" >/dev/null 2>&1 || true
fi

echo "Starting Tribe Alpha colony (${#AGENTS[@]} agents)..."

for agent in "${AGENTS[@]}"; do
    interval=$(tick_interval_for "$agent")
    echo "  Starting $agent (tick=${interval}ms)..."
    agentis daemon "$COLONY_DIR/agents/${agent}.ag" \
        --colony tribe-alpha \
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
