#!/bin/bash
# kill-federation.sh - Reliably stop the Dev Apprenticeship federation
#
# Thin wrapper around the generic tools/kill-federation.sh. Stops every
# agentis daemon, the dashboard (if running), and cleans the registry
# sidecar files. See tools/kill-federation.sh --help for full options.
#
# Usage: ./kill-federation.sh [OPTIONS]
#        ./kill-federation.sh                # kill this federation
#        ./kill-federation.sh --dry-run      # preview, do nothing
#        ./kill-federation.sh --help         # full option list

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

exec "$SCRIPT_DIR/../tools/kill-federation.sh" --fed-dir "$SCRIPT_DIR" "$@"
