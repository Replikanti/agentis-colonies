#!/usr/bin/env bash
# test-tribes-bench-run-stage3-docker.sh — colony-lint wrapper for the
# Stage 3 Docker-orchestrator dry-run smoke test (#439).
#
# colony-lint.sh auto-discovers `tools/test-*.sh` at the repo root and
# runs every match. This shim delegates to the federation-local
# `tribes-bench/tools/test-run-stage3-docker.sh` so the dry-run
# orchestrator transcript gates on every CI run alongside the rest of
# the platform tests.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SH_TEST="$REPO_ROOT/tribes-bench/tools/test-run-stage3-docker.sh"

if [ ! -f "$SH_TEST" ]; then
    echo "[FAIL] test-tribes-bench-run-stage3-docker: missing $SH_TEST"
    exit 1
fi

exec bash "$SH_TEST"
