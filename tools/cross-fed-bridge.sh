#!/usr/bin/env bash
# tools/cross-fed-bridge.sh -- Bidirectional cross-fed:* memo <-> host-dir
# sync sidecar (Phase 8 PR-1 of #629).
#
# Thin shell wrapper around tools/cross-fed-bridge.py. PR-1 ships the
# bridge as a no-op against every existing federation; no agent reads
# or writes `cross-fed:*` keys yet. PR-2 wires the source-side export
# from research-foundry, PR-3 wires the target-side import, PR-4 closes
# the cooperative search loop. See doc/cross-fed-memo.md for the
# namespace contract.
#
# Invocation forms:
#
#   tools/cross-fed-bridge.sh sync <fed_dir>
#       Run one bidirectional sync pass between <fed_dir>'s memo store
#       and the host-level shared dir at <repo-root>/cross-fed-memo/.
#       Suitable for cron-style invocation.
#
#   tools/cross-fed-bridge.sh sidecar <fed_dir> [--interval N]
#       Long-running sidecar loop. Holds a non-blocking flock on the
#       host dir's .lock file; if the lock is held by another sidecar
#       on the same host, logs `lock held by other process; no-op`
#       and exits 0 (only one bridge can own the shared dir at a time).
#       Defaults to a 60s sync cadence.
#
# Exit codes:
#   0 -- clean pass (or lock held by another sidecar -- the existing
#        owner is doing the work)
#   1 -- missing fed_dir, unknown flag, helper crashed
#
# The host dir lives at <repo-root>/cross-fed-memo/ by default. Override
# via CROSS_FED_HOST_DIR for ad-hoc tests; the wrapper resolves it to an
# absolute path before passing it to the Python helper.
#
# This script intentionally does NOT touch the agentis CLI: every memo
# read/write goes through the Python helper's direct .jsonl file
# manipulation. The bridge therefore runs on any host with python3 +
# flock(2), regardless of whether `agentis` is on PATH.

set -euo pipefail

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
PY_HELPER="$SCRIPT_DIR/cross-fed-bridge.py"

if [ ! -f "$PY_HELPER" ]; then
    echo "cross-fed-bridge: missing helper at $PY_HELPER" >&2
    exit 1
fi

usage() {
    cat >&2 <<'EOF'
Usage:
  tools/cross-fed-bridge.sh sync <fed_dir>
  tools/cross-fed-bridge.sh sidecar <fed_dir> [--interval N]

Mirrors `cross-fed:*` memo keys between <fed_dir>/.agentis/memo/ and
the host-level shared dir at <repo-root>/cross-fed-memo/. PR-1 of #629.
EOF
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

MODE="$1"
shift

if [ "$MODE" != "sync" ] && [ "$MODE" != "sidecar" ]; then
    usage
    exit 1
fi

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

FED_ARG="$1"
shift

# Resolve fed_dir against $REPO_ROOT first (so callers may pass a
# repo-relative name like `research-foundry`), then fall back to
# treating it as an absolute/relative path verbatim.
if [ -d "$REPO_ROOT/$FED_ARG" ]; then
    FED_DIR="$REPO_ROOT/$FED_ARG"
else
    FED_DIR="$FED_ARG"
fi
if [ ! -d "$FED_DIR" ]; then
    echo "cross-fed-bridge: fed_dir not found: $FED_ARG" >&2
    exit 1
fi
# Canonicalise so subsequent operations don't trip over `./` and `..`.
FED_DIR="$(cd "$FED_DIR" && pwd)"

INTERVAL=60
while [ $# -gt 0 ]; do
    case "$1" in
        --interval)
            if [ $# -lt 2 ]; then
                echo "cross-fed-bridge: --interval requires a value" >&2
                exit 1
            fi
            INTERVAL="$2"
            shift 2
            ;;
        *)
            echo "cross-fed-bridge: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

HOST_DIR="${CROSS_FED_HOST_DIR:-$REPO_ROOT/cross-fed-memo}"
mkdir -p "$HOST_DIR"

LOG_DIR="$FED_DIR/.agentis/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/cross-fed-bridge.log"

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] cross-fed-bridge: $*" | tee -a "$LOG_FILE"
}

if [ "$MODE" = "sync" ]; then
    # One-shot bidirectional pass. The Python helper acquires the lock
    # itself and exits 0 if another process holds it.
    exec python3 "$PY_HELPER" sync "$FED_DIR" "$HOST_DIR" --lock-mode nonblocking
fi

# --- Sidecar loop ---
#
# We acquire the lock once at the wrapper level via fd 200, then the
# inner Python sync call runs with --lock-mode release so it does not
# try to re-acquire the same file lock. Only one sidecar per host.
LOCK_FILE="$HOST_DIR/.lock"
exec 200>"$LOCK_FILE"
if ! python3 -c '
import fcntl, sys
try:
    fcntl.flock(int(sys.argv[1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    sys.exit(1)
' 200 2>/dev/null; then
    log "lock held by other process; no-op"
    exit 0
fi

log "sidecar started (fed_dir=$FED_DIR host_dir=$HOST_DIR interval=${INTERVAL}s)"

# Sidecar loop. Each iteration runs one bidirectional pass; the lock
# stays held on fd 200 for the lifetime of this process so concurrent
# sidecar starts on the same host bail out at the gate above. Sleep
# happens via a foreground call so SIGTERM at any point terminates the
# loop cleanly.
while true; do
    if ! python3 "$PY_HELPER" sync "$FED_DIR" "$HOST_DIR" --lock-mode release >>"$LOG_FILE" 2>&1; then
        log "sync pass failed; continuing"
    fi
    sleep "$INTERVAL"
done
