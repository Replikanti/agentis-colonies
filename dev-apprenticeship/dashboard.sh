#!/bin/bash
# dashboard.sh — Web dashboard for the Dev Apprenticeship federation
#
# Wrapper around the standalone federation-dashboard component (#252).
# Resolution order for the dashboard binary:
#   1. $FEDERATION_DASHBOARD_BIN env override
#   2. ${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/bin/federation-dashboard
#   3. command -v federation-dashboard (anything on $PATH)
#   4. clear error pointing the operator at the install instructions
#
# Usage: ./dashboard.sh [port]
#        ./dashboard.sh          # serves on http://localhost:8420
#        ./dashboard.sh 9000     # serves on http://localhost:9000

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

BIN=""

# 1. Explicit env override
if [ -n "${FEDERATION_DASHBOARD_BIN:-}" ] && [ -x "$FEDERATION_DASHBOARD_BIN" ]; then
    BIN="$FEDERATION_DASHBOARD_BIN"
fi

# 2. XDG data path (default install location)
if [ -z "$BIN" ]; then
    XDG_BIN="${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/bin/federation-dashboard"
    if [ -x "$XDG_BIN" ]; then
        BIN="$XDG_BIN"
    fi
fi

# 3. PATH lookup
if [ -z "$BIN" ]; then
    if command -v federation-dashboard >/dev/null 2>&1; then
        BIN="$(command -v federation-dashboard)"
    fi
fi

if [ -z "$BIN" ]; then
    PIN_FILE="$SCRIPT_DIR/.dashboard-version"
    if [ -r "$PIN_FILE" ]; then
        PIN="$(tr -d ' \n' < "$PIN_FILE")"
    else
        PIN=""
    fi
    {
        echo "dashboard.sh: federation-dashboard not found."
        echo
        echo "The dashboard is now a separately-versioned standalone component (#252)."
        if [ -n "$PIN" ]; then
            echo "Install the version pinned by this federation (federation-dashboard v$PIN):"
            echo
            echo "  curl -fsSL -o /tmp/fd.tar.gz \\"
            echo "    \"https://github.com/Replikanti/agentis-colonies/releases/download/federation-dashboard-v${PIN}/federation-dashboard-v${PIN}.tar.gz\""
            echo "  tar -xzf /tmp/fd.tar.gz -C /tmp"
            echo "  /tmp/federation-dashboard-v${PIN}/install.sh"
        else
            echo "Could not read the federation's pin file at:"
            echo "  $PIN_FILE"
            echo "Re-run dev-apprenticeship/install.sh to restore it (it will also offer to install the pinned dashboard)."
        fi
        echo
        echo "Or set FEDERATION_DASHBOARD_BIN to an explicit path."
    } >&2
    exit 1
fi

PORT="${1:-8420}"
exec "$BIN" "$SCRIPT_DIR" "$PORT"
