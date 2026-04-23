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
    cat >&2 <<EOF
dashboard.sh: federation-dashboard not found.

The dashboard is now a separately-versioned standalone component (#252).
Install the version pinned by this federation:

  PIN="\$(cat "$SCRIPT_DIR/.dashboard-version" 2>/dev/null || echo 0.1.0)"
  curl -fsSL -o /tmp/fd.tar.gz \\
    "https://github.com/Replikanti/agentis-colonies/releases/download/federation-dashboard-v\$PIN/federation-dashboard-v\$PIN.tar.gz"
  tar -xzf /tmp/fd.tar.gz -C /tmp
  /tmp/federation-dashboard-v\$PIN/install.sh

Or set FEDERATION_DASHBOARD_BIN to an explicit path.
EOF
    exit 1
fi

PORT="${1:-8420}"
exec "$BIN" "$SCRIPT_DIR" "$PORT"
