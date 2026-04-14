#!/bin/bash
# start-federation.sh - Start all 5 colonies of the Dev Apprenticeship federation
#
# Launches triage, code-review, planning, implementation, and release colonies
# in sequence. Each colony starts its agents as background daemon processes.
#
# Usage: ./start-federation.sh [path/to/federation-dir]
#        ./start-federation.sh              # uses script's own directory

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="${1:-$SCRIPT_DIR}"

COLONIES=(triage code-review planning implementation release)

echo ""
echo "Dev Apprenticeship Federation"
echo "============================="
echo ""

# Refuse to start if any agentis daemon is already running under this
# federation root. A second invocation would spawn 21 more daemons
# racing the first set for the same GitLab project (dup labels, dup
# comments, dup MRs) and there is no safe way to untangle them after
# the fact — stop-all hits both generations equally.
if agentis daemon list 2>/dev/null | grep -Eq '(^|[[:space:]])running([[:space:]]|$)'; then
    echo "[!!] A federation is already running under this directory."
    echo "     Stop it first:  agentis daemon stop --all"
    echo "     Inspect it:     agentis daemon list"
    exit 1
fi

# Pre-flight: check all configs exist
for colony in "${COLONIES[@]}"; do
    CONFIG="$FED_DIR/$colony/config/colony.toml"
    if [ ! -f "$CONFIG" ]; then
        echo "[!!] Missing config: $CONFIG"
        echo "     Run ./install.sh first."
        exit 1
    fi
done

# After laptop sleep/reboot, heartbeat files under .agentis/daemon/
# retain the pre-sleep mtime and the watchdog reads them as "last
# heartbeat was N hours ago", killing every fresh child on its first
# tick. Wipe them before any child writes a fresh one. Safe because
# the double-start guard above proved there is no live federation to
# disrupt.
FED_AGENTIS_DIR="$FED_DIR/.agentis/daemon"
if [ -d "$FED_AGENTIS_DIR" ]; then
    rm -f "$FED_AGENTIS_DIR"/*.heartbeat 2>/dev/null || true
fi

# Start each colony
TOTAL_AGENTS=0
for colony in "${COLONIES[@]}"; do
    echo "Starting $colony colony..."
    "$FED_DIR/$colony/scripts/start-colony.sh" &
    # Count agents in this colony's config
    AGENT_COUNT=$(grep -c '^\[\[agents\]\]' "$FED_DIR/$colony/config/colony.toml" 2>/dev/null || echo 0)
    TOTAL_AGENTS=$((TOTAL_AGENTS + AGENT_COUNT))
    sleep 3  # stagger colony starts
done

echo ""
echo "============================="
echo "Federation started: 5 colonies, $TOTAL_AGENTS agents"
echo ""
echo "Monitor:"
echo "  agentis daemon list           # Running agents"
echo "  agentis federation status     # Federation overview"
echo "  agentis colony health         # Colony health"
echo "  tail -f .agentis/logs/<agent>.log"
echo ""
echo "Stop:     agentis daemon stop --all"
echo ""

wait
