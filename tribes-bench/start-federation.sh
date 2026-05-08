#!/bin/bash
# start-federation.sh — Start the Tribes Bench federation tribes.
#
# Launches every tribe in COLONIES in parallel by invoking each colony's
# start-colony.sh. The bench has no auto-promote sidecar, no cost-cap
# sidecar, no dashboard auto-launch. ADR-0003 expects the script to
# launch the federation and wait — that is all this does.
#
# Stage 0 (#363) shipped tribe-alpha + tribe-beta; Stage 1 M1 (#364)
# adds tribe-gamma. The default target stays targets/stage0/ (Stage 0
# back-compat); set TARGET_DIR/BUGS_MANIFEST in the env to point a run
# at targets/stage1/.
#
# Stage 1 M2 also spawns one local `agentis worker` so the hunter's
# replicate(target_node) call has a colony worker to dispatch to. The
# worker secret is randomised per run; the worker pid is recorded in
# runs/<ts>/worker.pid and its log in runs/<ts>/worker.log so the
# operator can clean it up. When `runs/<ts>/` is unavailable the worker
# step is skipped (Stage 0 reruns continue to work without replication).
#
# Usage:
#   ./start-federation.sh [path/to/federation-dir]
#   ./start-federation.sh                 # uses script's own directory

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="${1:-$SCRIPT_DIR}"

COLONIES=(tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon)

echo ""
echo "Tribes Bench Federation"
echo "======================="
echo ""

# Pre-flight: every tribe must have its colony.toml in place.
for colony in "${COLONIES[@]}"; do
    CONFIG="$FED_DIR/$colony/config/colony.toml"
    if [ ! -f "$CONFIG" ]; then
        echo "[!!] Missing config: $CONFIG"
        echo "     Run ./install.sh first."
        exit 1
    fi
done

# Refuse to start if a federation is already running under this directory.
# Stage 0 daemons would race the existing set for the same memo store.
if agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
    echo "[!!] A federation is already running under this directory."
    echo "     Stop it first:  agentis daemon stop --all"
    echo "     Inspect it:     agentis daemon list"
    exit 1
fi

# Stage 1 M2 colony worker. replicate(target_node) needs a worker to
# dispatch the new replica onto. We spawn one local worker per
# federation launch with a per-run secret. RUN_DIR is set by
# tools/run-stage1.sh (hermetic per-run dir); when RUN_DIR is unset (Stage 0
# reruns or ad-hoc launches) we skip the worker step so the legacy
# Stage 0 behaviour stays byte-identical.
if [ -n "${RUN_DIR:-}" ]; then
    WORKER_ADDR="${WORKER_ADDR:-127.0.0.1:9100}"
    WORKER_SECRET="$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)"
    mkdir -p "$RUN_DIR"
    # Stage 1 M2 colony auth (#468). Replicate's MSG_REPLICATE handshake
    # reads colony.secret from .agentis/config; the worker will reject
    # any caller missing the matching secret. Append unconditionally —
    # last-line-wins overrides agentis init's random default, mirroring
    # how federation.enabled / llm.backend overwrite the same way.
    CONFIG_FILE="$RUN_DIR/.agentis/config"
    if [ -f "$CONFIG_FILE" ]; then
        printf 'colony.secret = %s\n' "$WORKER_SECRET" >> "$CONFIG_FILE"
    fi
    agentis worker "$WORKER_ADDR" --secret "$WORKER_SECRET" --max-concurrent 8 \
        >>"$RUN_DIR/worker.log" 2>&1 &
    echo "$!" > "$RUN_DIR/worker.pid"
    agentis memo set "tribes-bench:worker_addr" "$WORKER_ADDR" >/dev/null 2>&1 || true
    echo "Started agentis worker on $WORKER_ADDR (pid=$(cat "$RUN_DIR/worker.pid"))"

    # Stage 3 cross-node replication (#460 PR B): when the operator declares
    # additional peer workers via PEER_WORKER_ADDRS (space-separated host:port
    # list), seed the indexed memo keys + count memo so hunter's
    # select_replication_target() rotates replicate(target) calls across
    # nodes. Empty / unset PEER_WORKER_ADDRS keeps the legacy single-node
    # path byte-identical (count=0 → fallback to self_node_addr()).
    if [ -n "${PEER_WORKER_ADDRS:-}" ]; then
        i=0
        for addr in $PEER_WORKER_ADDRS; do
            agentis memo set "tribes-bench:peer_worker_addr:$i" "$addr" >/dev/null 2>&1 || true
            i=$((i + 1))
        done
        agentis memo set "tribes-bench:peer_worker_count" "$i" >/dev/null 2>&1 || true
        echo "Seeded $i peer worker address(es) for cross-node replication"
    fi
fi

TOTAL_AGENTS=0
for colony in "${COLONIES[@]}"; do
    echo "Starting $colony colony..."
    "$FED_DIR/$colony/scripts/start-colony.sh" &
    AGENT_COUNT=$(grep -c '^\[\[agents\]\]' "$FED_DIR/$colony/config/colony.toml" 2>/dev/null || echo 0)
    TOTAL_AGENTS=$((TOTAL_AGENTS + AGENT_COUNT))
    sleep 1
done

echo ""
echo "================================="
echo "Federation started: ${#COLONIES[@]} tribes, $TOTAL_AGENTS agents"
echo ""
echo "Stop with: tools/kill-federation.sh --fed-dir $FED_DIR"
echo ""

wait
