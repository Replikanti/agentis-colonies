#!/bin/bash
# start-federation.sh - Start all 5 colonies of the Dev Apprenticeship federation
#
# Launches triage, code-review, planning, implementation, and release colonies
# in sequence. Each colony starts its agents as background daemon processes.
#
# Usage: ./start-federation.sh [path/to/federation-dir]
#        ./start-federation.sh              # uses script's own directory
#
# Env vars (forwarded to start-colony.sh):
#   TRUNCATE_LOGS=1   zero out .agentis/logs/*.log at spawn time.
#                     Zero-config fallback for boxes without logrotate;
#                     loses history between restarts. For long-running
#                     federations, use ops/logrotate.conf instead.

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
#
# NB: `agentis daemon list` writes the human-readable table to stderr
# (eprintln! in agentis-core src/cli/daemon.rs), so the previous
# version of this guard grepped empty stdout and never matched.
# `--json` goes to stdout and is table-layout-stable, so we key on
# the structured field instead of the table row.
if agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
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
    # *.pid / *.status / *.watchdog.pid go stale on the same axis as
    # *.heartbeat — on wake they point at PIDs from the previous boot
    # which may now belong to an unrelated process. Sweep them all.
    rm -f "$FED_AGENTIS_DIR"/*.heartbeat \
          "$FED_AGENTIS_DIR"/*.pid \
          "$FED_AGENTIS_DIR"/*.status \
          "$FED_AGENTIS_DIR"/*.watchdog.pid 2>/dev/null || true
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

# --- Auto-promote scheduler sidecar (#216) ---
#
# Reads .auto-promote-install.toml (written by install.sh §7) and, if
# enabled, spawns a background loop that invokes tools/auto-promote.sh
# every interval_s seconds. The sidecar self-terminates once no agentis
# daemons are running under this federation (e.g. after kill-federation.sh
# has swept them), so its lifetime tracks the federation's without
# needing kill-federation.sh to know about it. A trap on EXIT/TERM/INT
# kills it immediately when the operator Ctrl-Cs this script.
AUTO_PROMOTE_INSTALL_FILE="$FED_DIR/.auto-promote-install.toml"
AUTO_PROMOTE_PID=""
AP_PARSE_TOML="$SCRIPT_DIR/../tools/parse-toml.sh"
if [ -f "$AUTO_PROMOTE_INSTALL_FILE" ]; then
    if [ ! -r "$AP_PARSE_TOML" ]; then
        # Broken checkout — parse-toml.sh is expected to ship with the repo.
        # Sourcing a missing file under `set -e` would error-exit after the
        # 5 colonies have already been backgrounded, orphaning them. Skip
        # the sidecar block instead and let the federation run without it.
        echo "[!!] Auto-promote scheduler: tools/parse-toml.sh not readable, skipping."
    else
        CONFIG="$AUTO_PROMOTE_INSTALL_FILE"
        # shellcheck source=../tools/parse-toml.sh
        source "$AP_PARSE_TOML"
        AP_ENABLED="$(parse_toml auto_promote enabled 2>/dev/null || true)"
        AP_INTERVAL="$(parse_toml auto_promote interval_s 2>/dev/null || true)"
        case "$AP_INTERVAL" in
            ''|*[!0-9]*) AP_INTERVAL=1800 ;;
            *) [ "$AP_INTERVAL" -gt 0 ] || AP_INTERVAL=1800 ;;
        esac
        if [ "$AP_ENABLED" = "true" ]; then
            AP_LOG_DIR="$FED_DIR/.agentis/logs"
            AP_LOG="$AP_LOG_DIR/auto-promote.log"
            mkdir -p "$AP_LOG_DIR"
            AP_SCRIPT="$SCRIPT_DIR/../tools/auto-promote.sh"
            AP_FED_NAME="$(basename "$FED_DIR")"
            if [ ! -x "$AP_SCRIPT" ]; then
                echo "[!!] Auto-promote scheduler: tools/auto-promote.sh not executable, skipping."
            else
                (
                    while :; do
                        sleep "$AP_INTERVAL"
                        if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                            printf '=== %s: no running daemons; sidecar exiting ===\n' \
                                "$(date -Iseconds)" >> "$AP_LOG"
                            exit 0
                        fi
                        {
                            printf '=== %s: sidecar tick ===\n' "$(date -Iseconds)"
                            "$AP_SCRIPT" "$AP_FED_NAME" 2>&1 \
                                || printf '[sidecar] auto-promote.sh exited %s\n' "$?"
                        } >> "$AP_LOG"
                    done
                ) &
                AUTO_PROMOTE_PID=$!
                # shellcheck disable=SC2064  # Expand PID at trap-install time, not at trigger time.
                trap "[ -n \"$AUTO_PROMOTE_PID\" ] && kill \"$AUTO_PROMOTE_PID\" 2>/dev/null; exit" EXIT TERM INT
                echo "Auto-promote scheduler: PID $AUTO_PROMOTE_PID, every ${AP_INTERVAL}s (log: .agentis/logs/auto-promote.log)"
                echo ""
            fi
        fi
    fi
fi

wait
