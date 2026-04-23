#!/bin/bash
# watch-suggestions.sh - Live feed of agent suggestions across all colonies
#
# Filters suggestion, draft, and emit lines from all agent logs into a
# single stream. Useful when agents are in suggest mode (confidence
# 0.6-0.84) and you want to review what they would do without digging
# through 21 separate log files.
#
# Usage: ./watch-suggestions.sh [path/to/.agentis/logs]

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

# Resolve log directory with fed-local-first precedence (mirrors
# federation-dashboard/bin/federation-dashboard after #238 / #252). The previous default
# "${SCRIPT_DIR}/../.agentis/logs" resolved to the repo-root shared
# .agentis/ when two federations live as siblings under one checkout,
# cross-reading the other federation's logs. Daemons write to
# <federation>/.agentis/logs, so prefer that first and only fall
# through to the parent-level or cwd path when the local one is absent.
if [ -n "${1:-}" ]; then
    LOG_DIR="$1"
else
    LOG_DIR="${SCRIPT_DIR}/.agentis/logs"
    if [ ! -d "$LOG_DIR" ]; then
        LOG_DIR="${SCRIPT_DIR}/../.agentis/logs"
    fi
    if [ ! -d "$LOG_DIR" ]; then
        LOG_DIR=".agentis/logs"
    fi
fi

if [ ! -d "$LOG_DIR" ]; then
    echo "Log directory not found: $LOG_DIR"
    echo "Usage: ./watch-suggestions.sh [path/to/.agentis/logs]"
    exit 1
fi

LOG_COUNT=$(find "$LOG_DIR" -name '*.log' 2>/dev/null | wc -l)
if [ "$LOG_COUNT" -eq 0 ]; then
    echo "No log files found in $LOG_DIR"
    echo "Start the federation first: ./start-federation.sh"
    exit 1
fi

echo "Watching $LOG_COUNT agent logs in $LOG_DIR"
echo "Filtering: suggestions, drafts, emits, findings"
echo "Press Ctrl+C to stop"
echo ""

tail -f "$LOG_DIR"/*.log 2>/dev/null | grep --line-buffered -iE 'suggest|draft|emit|finding'
