#!/usr/bin/env bash
# test-tribes-bench-analyse-stage3.sh — colony-lint wrapper for the
# Stage 3 lineage-analyser fixture suite (#439).
#
# colony-lint.sh auto-discovers `tools/test-*.sh` at the repo root and
# runs every match. This shim delegates to the federation-local
# `tribes-bench/tools/test-analyse-stage3.py` so the 4-case fixture
# suite gates on every CI run alongside the rest of the platform tests.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PY_TEST="$REPO_ROOT/tribes-bench/tools/test-analyse-stage3.py"

if [ ! -f "$PY_TEST" ]; then
    echo "[FAIL] test-tribes-bench-analyse-stage3: missing $PY_TEST"
    exit 1
fi

exec python3 "$PY_TEST"
