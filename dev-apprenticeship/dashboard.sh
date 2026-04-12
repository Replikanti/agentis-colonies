#!/bin/bash
# dashboard.sh - Web dashboard for the Dev Apprenticeship federation
#
# Thin wrapper around the generic federation dashboard tool.
#
# Usage: ./dashboard.sh [port]
#        ./dashboard.sh          # serves on http://localhost:8420
#        ./dashboard.sh 9000     # serves on http://localhost:9000

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

exec "$SCRIPT_DIR/../tools/federation-dashboard.sh" "$SCRIPT_DIR" "${1:-8420}"
