#!/usr/bin/env bash
# sidecar-restart.sh — restart a single sidecar by name.
#
# Restarts one of the federation's sidecars (auto-promote, cost-cap) by:
#   1. Killing any running PID owning the sidecar's `.sidecar_started_at`
#      (best-effort: TERM, then KILL on holdouts).
#   2. Touching the sidecar's `.sidecar_started_at` file with the current
#      epoch so the dashboard's startup grace window resets cleanly.
#   3. Re-exec'ing the sidecar's main loop in a detached background
#      subshell that mirrors the start-federation.sh block.
#
# This is the helper the dashboard's `/sidecar-restart` endpoint shells
# out to. Mirrors the cost-cap.sh `--override` precedent: the endpoint
# is a thin shell-out, the actual kill+respawn lives in shell.
#
# Usage:
#   ./tools/sidecar-restart.sh <fed-dir> <sidecar-name>
#
# Where <sidecar-name> is one of:
#   auto-promote
#   cost-cap
#
# Exit codes:
#   0  sidecar restarted (or was not running and is now spawned)
#   2  invalid invocation / unknown sidecar name
#   3  sidecar configured-off (sidecar.enabled = false) — no-op
#   4  spawn failed
#
# Per the CLAUDE.md no-heredoc invariant, this script never uses heredocs.

set -u

if [ $# -lt 2 ]; then
    echo "Usage: $0 <fed-dir> <sidecar-name>" >&2
    exit 2
fi

FED_DIR="$1"
SIDECAR_NAME="$2"

if [ ! -d "$FED_DIR" ]; then
    echo "sidecar-restart.sh: federation dir not found: $FED_DIR" >&2
    exit 2
fi

case "$SIDECAR_NAME" in
    auto-promote|cost-cap) : ;;
    *)
        echo "sidecar-restart.sh: unknown sidecar name: $SIDECAR_NAME" >&2
        echo "  expected one of: auto-promote, cost-cap" >&2
        exit 2
        ;;
esac

LOG_DIR="$FED_DIR/.agentis/logs"
LOG_FILE="$LOG_DIR/${SIDECAR_NAME}.log"
STARTED_AT_FILE="$LOG_DIR/${SIDECAR_NAME}.sidecar_started_at"

mkdir -p "$LOG_DIR" 2>/dev/null || true

# Resolve script dir to find the sidecar's main script.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

case "$SIDECAR_NAME" in
    auto-promote)
        SIDECAR_BIN="$SCRIPT_DIR/auto-promote.sh"
        ;;
    cost-cap)
        SIDECAR_BIN="$SCRIPT_DIR/cost-cap.sh"
        ;;
esac

if [ ! -x "$SIDECAR_BIN" ]; then
    echo "sidecar-restart.sh: sidecar binary not executable: $SIDECAR_BIN" >&2
    exit 4
fi

# Best-effort PID kill. The sidecar lives in a backgrounded subshell from
# start-federation.sh; we don't track its PID directly, so use pgrep on
# the sidecar binary path. macOS bash 3.2 portable.
KILLED=0
if command -v pgrep >/dev/null 2>&1; then
    PIDS="$(pgrep -f "$SIDECAR_BIN" 2>/dev/null || true)"
    if [ -n "$PIDS" ]; then
        for pid in $PIDS; do
            if kill -TERM "$pid" 2>/dev/null; then
                KILLED=$((KILLED + 1))
            fi
        done
        # Wait up to 5s for graceful exit, then SIGKILL holdouts.
        sleep 1
        STILL="$(pgrep -f "$SIDECAR_BIN" 2>/dev/null || true)"
        if [ -n "$STILL" ]; then
            sleep 4
            STILL="$(pgrep -f "$SIDECAR_BIN" 2>/dev/null || true)"
            if [ -n "$STILL" ]; then
                for pid in $STILL; do
                    kill -KILL "$pid" 2>/dev/null || true
                done
            fi
        fi
    fi
fi

# Reset the start-time file so the dashboard's grace window resets.
date +%s > "$STARTED_AT_FILE"

# Re-spawn in a detached subshell. setsid (where available) creates a new
# process group so the dashboard endpoint's subprocess.run can return
# without dragging the spawned child down with it.
SPAWN_LOG="$LOG_FILE"
if command -v setsid >/dev/null 2>&1; then
    setsid bash -c "while true; do bash '$SIDECAR_BIN' '$FED_DIR' >> '$SPAWN_LOG' 2>&1; sleep 60; done" </dev/null >/dev/null 2>&1 &
else
    nohup bash -c "while true; do bash '$SIDECAR_BIN' '$FED_DIR' >> '$SPAWN_LOG' 2>&1; sleep 60; done" </dev/null >/dev/null 2>&1 &
fi
disown $! 2>/dev/null || true

echo "sidecar-restart.sh: ${SIDECAR_NAME} restarted (killed=${KILLED}, log=${LOG_FILE})"
exit 0
