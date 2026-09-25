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
#
# #2258 WALL-CLOCK CAP (optional 4th positional, only the deep-hunt time-budget scheduler passes it):
#   cell-watchdog.sh <cell-dir> <stale-s> <poll-s> <wall-s> -- <cmd> [args...]
# With <wall-s> present the wrapper is always MANAGED (never an `exec` pass-through, unless there is no `setsid`,
# which it logs): it polls once a second, kills the engine group (TERM, then KILL after 3 s) once <wall-s> has
# elapsed and exits 124 — distinct from the staleness kill's 143/137. A <wall-s> of 0 means no wall bound (the
# wrapper still forwards TERM/INT to the engine group, so a stopped run leaves no orphan engine). A <stale-s> of 0
# turns the staleness check off in this mode. Three-argument calls are byte-identical to before.
set -u

CELL="${1:?cell-watchdog.sh: <cell-dir> required}"
STALE="${2:?cell-watchdog.sh: <stale-s> required}"
POLL="${3:?cell-watchdog.sh: <poll-s> required}"
shift 3
# #2258: the optional <wall-s> sits between <poll-s> and `--`; it is recognised only in exactly that shape (a
# whole number followed by `--`), so a three-argument call can never be misread as carrying one.
WALL=""
if [ "$#" -ge 2 ] && [ "${2:-}" = "--" ]; then
  case "${1:-}" in ''|*[!0-9]*) ;; *) WALL="$1"; shift ;; esac
fi
[ "${1:-}" = "--" ] && shift
[ "$#" -ge 1 ] || { echo "cell-watchdog.sh: no command after --" >&2; exit 2; }

# Pass-through when we cannot group-kill (no setsid) or the watchdog is disabled (stale/poll <= 0).
case "$STALE$POLL" in *[!0-9]*) STALE=0 ;; esac

# #2258: MANAGED mode (a <wall-s> was given). Kept apart from the legacy path below so a three-argument call is
# byte-identical. The poll loop runs in THIS process (not a subshell) so one loop serves the wall bound, the
# staleness bound and the TERM/INT forwarding.
if [ -n "$WALL" ]; then
  if ! command -v setsid >/dev/null 2>&1; then
    echo "cell-watchdog.sh: setsid unavailable — the ${WALL}s wall-clock cap for '$CELL' cannot be enforced; running unbounded (#2258)" >&2
    exec "$@"
  fi
  setsid "$@" &
  _cw_pid=$!
  # TERM the engine's whole process group, give it 3 s to exit, then KILL whatever is left.
  _cw_kill_group() {
    kill -TERM -- -"$_cw_pid" 2>/dev/null || true
    _cw_i=0
    while [ "$_cw_i" -lt 30 ] && kill -0 -- -"$_cw_pid" 2>/dev/null; do
      sleep 0.1
      _cw_i=$((_cw_i + 1))
    done
    kill -KILL -- -"$_cw_pid" 2>/dev/null || true
  }
  trap '_cw_kill_group; wait "$_cw_pid" 2>/dev/null; exit 143' TERM INT
  _cw_t0=$(date +%s)
  _cw_lastpoll="$_cw_t0"
  _cw_fired=""
  while kill -0 "$_cw_pid" 2>/dev/null; do
    sleep 1
    _cw_now=$(date +%s)
    if [ "$WALL" -gt 0 ] && [ "$(( _cw_now - _cw_t0 ))" -ge "$WALL" ]; then
      echo "cell-watchdog.sh: cell '$CELL' reached its ${WALL}s wall-clock cap -> killing the engine group (#2258)" >&2
      _cw_fired=wall
      _cw_kill_group
      break
    fi
    if [ "$STALE" -gt 0 ] && [ "$POLL" -gt 0 ] && [ "$(( _cw_now - _cw_lastpoll ))" -ge "$POLL" ]; then
      _cw_lastpoll="$_cw_now"
      _cw_last=$(find "$CELL" -type f -printf '%T@\n' 2>/dev/null | sort -n | tail -1 | cut -d. -f1)
      [ -z "$_cw_last" ] && _cw_last="$_cw_now"   # dir not created yet => give the engine time, not stale
      if [ "$(( _cw_now - _cw_last ))" -gt "$STALE" ]; then
        echo "cell-watchdog.sh: cell '$CELL' idle > ${STALE}s while engine alive -> force-killing (flat-cyborg hang #1925, fail-forward to HARNESS_ERROR)" >&2
        _cw_fired=stale
        _cw_kill_group
        break
      fi
    fi
  done
  _cw_rc=0
  wait "$_cw_pid" 2>/dev/null || _cw_rc=$?
  [ "$_cw_fired" = wall ] && exit 124
  # A staleness kill keeps the legacy 143/137 contract even if the engine swallowed the TERM and exited 0.
  if [ "$_cw_fired" = stale ] && [ "$_cw_rc" -eq 0 ]; then _cw_rc=143; fi
  exit "$_cw_rc"
fi
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
