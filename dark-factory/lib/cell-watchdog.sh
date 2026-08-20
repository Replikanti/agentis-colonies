#!/usr/bin/env bash
# cell-watchdog.sh <cell-dir> <stale-s> <poll-s> -- <cmd> [args...]   (#1982)
#
# Runs <cmd> under a STALENESS watchdog and returns <cmd>'s exit code. A deep-hunt cell writes into its own
# artifact dir constantly while it works (the invariant engine's LLM sub-log appends a heartbeat every few
# seconds); when the flat-cyborg session hangs (#1925) agentis-core retries the transport error indefinitely,
# so the cell loops FOREVER with a silent dir and wedges the whole zone-hunt. This watchdog bounds that: if
# <cell-dir> has had NO file written for more than <stale-s> while <cmd> is still alive, it kills <cmd>'s whole
# process group so the caller can fail-forward (record HARNESS_ERROR + advance) instead of blocking indefinitely.
#
# The kill needs a controllable process group: <cmd> is started under `setsid` (its own session => PGID == its
# PID) so `kill -- -<pgid>` reaps the whole subtree (engine -> agentis -> flat-cyborg), never leaving orphans.
# PORTABILITY / SAFETY: without `setsid` (e.g. macOS) the watchdog cannot group-kill, so it `exec`s <cmd>
# directly and is a pure pass-through — byte-identical to no watchdog, so non-Linux hosts are unaffected. The
# staleness bound is generous by design (a live cell is never silent for even one poll interval), so a genuinely
# working cell is never false-killed.
#
# Exit: <cmd>'s own code; 143 (SIGTERM) / 137 (SIGKILL) when the watchdog fired -> the caller's `|| continue`
# fail-forward path. A <stale-s> or <poll-s> of 0/empty disables the watchdog (pass-through).
set -u

CELL="${1:?cell-watchdog.sh: <cell-dir> required}"
STALE="${2:?cell-watchdog.sh: <stale-s> required}"
POLL="${3:?cell-watchdog.sh: <poll-s> required}"
shift 3
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "cell-watchdog.sh: no command after --" >&2; exit 2; }

# Pass-through when we cannot group-kill (no setsid) or the watchdog is disabled (stale/poll <= 0).
case "$STALE$POLL" in *[!0-9]*) STALE=0 ;; esac
if ! command -v setsid >/dev/null 2>&1 || [ "$STALE" -le 0 ] || [ "$POLL" -le 0 ]; then
  exec "$@"
fi

setsid "$@" &
_cw_pid=$!

# Watchdog: poll the cell dir's freshest write; kill the group once it is silent past the bound.
(
  while kill -0 "$_cw_pid" 2>/dev/null; do
    sleep "$POLL"
    _cw_now=$(date +%s)
    _cw_last=$(find "$CELL" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
    [ -z "$_cw_last" ] && _cw_last="$_cw_now"   # dir not created yet => give the engine time, not stale
    if [ "$(( _cw_now - _cw_last ))" -gt "$STALE" ]; then
      echo "cell-watchdog.sh: cell '$CELL' idle > ${STALE}s while engine alive -> force-killing (flat-cyborg hang #1925, fail-forward to HARNESS_ERROR)" >&2
      kill -TERM -- -"$_cw_pid" 2>/dev/null || true
      sleep 3
      kill -KILL -- -"$_cw_pid" 2>/dev/null || true
      break
    fi
  done
) &
_cw_wd=$!

_cw_rc=0
wait "$_cw_pid" || _cw_rc=$?
kill "$_cw_wd" 2>/dev/null || true
wait "$_cw_wd" 2>/dev/null || true
exit "$_cw_rc"
