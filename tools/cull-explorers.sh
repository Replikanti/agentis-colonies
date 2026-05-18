#!/bin/bash
# tools/cull-explorers.sh -- back-compat wrapper forwarding to the
# generalised cull-replicas.sh with colony=explorer.
#
# Phase 9 PR-B of #663 renamed the Phase 3 explorer-only tool to
# `tools/cull-replicas.sh` and added a positional <colony_name>
# argument. This wrapper preserves the legacy invocation shape used
# by run-research.sh's RESEARCH_CULL_* env knobs so existing pilots
# keep working byte-identically.

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <fed_dir> [--bottom-pct 0.2] [--min-explorers 3] [--min-acting 10] [--dry-run]" >&2
    exit 2
fi

FED_DIR="$1"
shift

exec "$SCRIPT_DIR/cull-replicas.sh" "$FED_DIR" explorer "$@"
