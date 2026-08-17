#!/usr/bin/env bash
# hunt-dashboard.sh — loopback-only launcher for the read-only single-hunt dashboard (#1913 M1).
#
# Resolves python3 and execs hunt-dashboard.py with the caller's descriptor / path flags. The server binds
# 127.0.0.1 only and never writes to the hunt (it only READS the artifacts). Long runs: start it under
# `setsid` so it survives the launching shell, e.g.
#
#   setsid dark-factory/hunt-dashboard/hunt-dashboard.sh --descriptor my-hunt.json >/tmp/hunt-dashboard.log 2>&1 &
#
# All flags are passed through to hunt-dashboard.py (see its --help): --descriptor, --root/--out/--log,
# --label/--reward-line, --bounty-url/--repo-url/--project-url, --host, --port, --render, --emit-model.
# Default port 8420 (override with --port or $HUNT_DASHBOARD_PORT).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
PY="$HERE/hunt-dashboard.py"

if ! command -v python3 >/dev/null 2>&1; then
  echo "hunt-dashboard.sh: python3 is required but was not found on PATH" >&2
  exit 3
fi
if [ ! -f "$PY" ]; then
  echo "hunt-dashboard.sh: dashboard not found: $PY" >&2
  exit 3
fi

exec python3 "$PY" "$@"
