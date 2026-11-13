#!/usr/bin/env bash
# demo-forge-slot.sh — proof of the #2038 host-wide forge-subprocess concurrency
# cap (dark-factory/lib/forge-slot.sh).
#
# CI-safe: sources lib/forge-slot.sh directly against a temp FORGE_SLOTS_DIR, no
# real forge/toolchain, no network. Mirrors tools/test-llm-session-slot.sh's
# assertion shape for its sibling semaphore (#1352), plus a synthetic-concurrent-
# load check spawning K+1 background holders (this repo's demo-* naming
# convention for a "run it, watch it prove the thing" script — see
# demo-invariant-transient.sh, PR #2037). Part 4 runs #2362's cases, the same
# as tools/test-llm-session-slot.sh 10-43 under the forge names: a slot is owned
# by the exclusive create of slot-N/pid, never by mkdir's exit status; the
# reclaim never removes a newer holder's stamp; an empty stamp or reap token is
# dead only when no live creator claims it; a failed stamp write and a reclaimer
# SIGKILLed mid-reclaim never leak a slot.
#
# Usage:  dark-factory/demo-forge-slot.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/forge-slot.sh"
RIH="$HERE/run-invariant-hunt.sh"

[ -f "$LIB" ] || { echo "demo-forge-slot.sh: lib not found: $LIB" >&2; exit 3; }

FAILS=0
ok()  { echo "  [OK]   $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export FORGE_SLOTS_DIR="$TMP/slots"

# shellcheck source=lib/forge-slot.sh
# shellcheck disable=SC1091
. "$LIB"

echo "demo-forge-slot.sh: 1) unit-level acquire/release/reclaim/fail-open ..."

# (1) acquire claims a slot; FORGE_SLOT_HELD points at an existing dir.
FORGE_MAX_SLOTS=2 acquire_forge_slot
if [ -n "${FORGE_SLOT_HELD:-}" ] && [ -d "$FORGE_SLOT_HELD" ]; then
    ok "acquire claims a slot (FORGE_SLOT_HELD set to existing dir)"
else
    bad "acquire claims a slot"
fi

# (2) release frees it (stamp gone, FORGE_SLOT_HELD cleared; the slot dir stays, it is only a container).
_held="$FORGE_SLOT_HELD"
release_forge_slot
if [ ! -e "$_held/pid" ] && [ -d "$_held" ] && [ -z "${FORGE_SLOT_HELD:-}" ]; then
    ok "release frees the slot (stamp removed, slot dir kept)"
else
    bad "release frees the slot"
fi

# (3) release is idempotent (second call, and a call with no held slot, are no-ops).
release_forge_slot
FORGE_SLOT_HELD=""
if release_forge_slot; then ok "release is idempotent / no-op when unheld"; else bad "release idempotent"; fi

# (4) all-K-busy (live holder) blocks the wait budget then fails open.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR"
mkdir "$FORGE_SLOTS_DIR/slot-1"; printf '%s' "$$" > "$FORGE_SLOTS_DIR/slot-1/pid"  # this shell = alive
_t0=$(date +%s)
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot
_t1=$(date +%s)
if [ -z "${FORGE_SLOT_HELD:-}" ] && [ "$((_t1 - _t0))" -ge 2 ]; then
    ok "all-busy (live holder) blocks the wait budget then fails open (a delayed run, never a dropped one)"
else
    bad "all-busy fails open after wait (held='${FORGE_SLOT_HELD:-}', waited=$((_t1 - _t0))s)"
fi
rm -rf "$FORGE_SLOTS_DIR/slot-1"

# (5) a slot held by a DEAD pid is reclaimed (PID-liveness self-heal).
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR"
sleep 0 & _dead=$!; wait "$_dead" 2>/dev/null || true
mkdir "$FORGE_SLOTS_DIR/slot-1"; printf '%s' "$_dead" > "$FORGE_SLOTS_DIR/slot-1/pid"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot
if [ -n "${FORGE_SLOT_HELD:-}" ] && [ "$FORGE_SLOT_HELD" = "$FORGE_SLOTS_DIR/slot-1" ]; then
    ok "dead-holder slot is reclaimed and re-acquired"
else
    bad "dead-holder slot reclaimed (held='${FORGE_SLOT_HELD:-}')"
fi
release_forge_slot

# (6) non-numeric FORGE_MAX_SLOTS falls back to the default without crashing.
rm -rf "$FORGE_SLOTS_DIR"
FORGE_MAX_SLOTS=abc acquire_forge_slot
if [ -n "${FORGE_SLOT_HELD:-}" ]; then ok "non-numeric FORGE_MAX_SLOTS falls back to the default"; else bad "non-numeric K fallback"; fi
release_forge_slot

echo
echo "demo-forge-slot.sh: 2) synthetic concurrent load — K holders bound, (K+1)th blocks then fails open ..."

# Spawn K background subshells that each acquire a slot, hold it for a bit, then
# release it — proving K distinct slots really do serialize a (K+1)th late
# arrival instead of letting it barge in for free.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR"
K=2
HOLD_S=5
i=1
while [ "$i" -le "$K" ]; do
    (
        # shellcheck disable=SC1090
        . "$LIB"
        FORGE_MAX_SLOTS="$K" FORGE_SLOT_WAIT_S=5 acquire_forge_slot
        if [ -n "${FORGE_SLOT_HELD:-}" ]; then
            printf '%s\n' "$FORGE_SLOT_HELD" > "$TMP/holder-$i.slot"
        fi
        sleep "$HOLD_S"
        release_forge_slot
    ) &
    i=$((i + 1))
done
# Give the K holders a moment to actually claim their slots before the late
# arrival probes (avoids a race where the late arrival starts before any
# holder has mkdir'd).
sleep 1

# The (K+1)th arrival: all K slots are held by LIVE holders (the background
# subshells above are still sleeping), so this must block for the wait budget
# and then fail open — never barge past the cap.
_t0=$(date +%s)
FORGE_MAX_SLOTS="$K" FORGE_SLOT_WAIT_S=2 acquire_forge_slot
_t1=$(date +%s)
_late_held="${FORGE_SLOT_HELD:-}"
release_forge_slot
wait

_distinct_slots="$(cat "$TMP"/holder-*.slot 2>/dev/null | sort -u | wc -l | tr -d ' ')"
if [ "$_distinct_slots" = "$K" ] && [ -z "$_late_held" ] && [ "$((_t1 - _t0))" -ge 2 ]; then
    ok "$K concurrent holders claimed $K distinct slots; a (K+1)th arrival blocked then failed open (no more than $K ever held a slot)"
else
    bad "concurrency bound violated: distinct=$_distinct_slots (want $K), late-held='$_late_held', waited=$((_t1 - _t0))s"
fi

echo
echo "demo-forge-slot.sh: 3) integration — acquire/release bracket both forge subprocess call sites ..."

if [ -f "$RIH" ]; then
    if grep -Fq 'lib/forge-slot.sh' "$RIH" \
       && grep -c 'acquire_forge_slot' "$RIH" | grep -q '^2$' \
       && grep -c 'release_forge_slot' "$RIH" | grep -q '^3$'; then
        ok "run-invariant-hunt.sh sources lib/forge-slot.sh and calls acquire/release around both the"
        ok "  generation (run_one_candidate) and corpus-replay forge subprocess call sites, plus the EXIT trap backstop"
    else
        bad "run-invariant-hunt.sh does not wire acquire_forge_slot/release_forge_slot at both call sites + the EXIT trap"
    fi
else
    bad "run-invariant-hunt.sh not found at $RIH"
fi

echo
echo "demo-forge-slot.sh: 4) #2362: ownership by exclusive create, never mkdir's exit status; reclaim, write"
echo "                    failure, empty stamps and tokens judged by their creator's claim, SIGKILLed"
echo "                    reclaimers (same cases as tools/test-llm-session-slot.sh 10-43, forge names) ..."

# uutils mkdir 0.8.0-0.10.0 (the /usr/bin/mkdir of Ubuntu 26.04) exits 0 when a concurrent creator wins the race,
# so two contenders could both "win" one slot. LIAR/mkdir reproduces that deterministically on any host: it runs
# the real mkdir (same arguments, same stderr) and always exits 0.
SLOTS="$FORGE_SLOTS_DIR"
REAL_MKDIR="$(command -v mkdir)"
export SLOT_LIAR="$TMP/liar"
mkdir -p "$SLOT_LIAR"
printf '#!/bin/sh\n"%s" "$@"\nexit 0\n' "$REAL_MKDIR" > "$SLOT_LIAR/mkdir"
chmod +x "$SLOT_LIAR/mkdir"
# (a library under test may leave owner-locked entries; restore the owner's rights before removing)
fresh() { chmod -R u+rwx "$SLOTS" 2>/dev/null || true; rm -rf "$SLOTS"; mkdir -p "$SLOTS"; }
# child CODE — run CODE in a fresh `sh` process (its own PID) that sources the library under `set -eu`, the caller
# contract; prints CODE's output, then ABORTED if the library (or CODE) made that set -e shell exit non-zero.
child() { sh -c 'set -eu; . "$1"; eval "$2"' sh "$LIB" "$1" 2>/dev/null || printf 'ABORTED'; }
have_reclaim() { command -v _fss_reclaim >/dev/null 2>&1; }
# entries DIR SEP — DIR's entries joined by SEP, for failure messages only (the pool holds plain names).
# shellcheck disable=SC2012
entries() { ls -A "$1" 2>/dev/null | tr '\n' "$2"; }
sleep 0 & _dead2=$!; wait "$_dead2" 2>/dev/null || true

# 10. Lying mkdir, K=1: this shell holds slot-1; a second contender (another process) never gets it, waits its
#     budget (WAIT=1: two scans, >= 1 s) and fails open; the holder's pid stamp is untouched.
fresh
PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot
_h1="${FORGE_SLOT_HELD:-}"
_t0=$(date +%s)
# shellcheck disable=SC2016  # expanded by the child shell
_h2="$(child 'PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_h1" = "$SLOTS/slot-1" ] && [ -z "$_h2" ] && [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$$" ] \
   && [ "$((_t1 - _t0))" -ge 1 ]; then
    ok "lying mkdir, K=1: a second contender never shares the held slot (waited $((_t1 - _t0))s, failed open)"
else
    bad "lying mkdir, K=1: first='$_h1' second='$_h2' pid='$(cat "$SLOTS/slot-1/pid" 2>/dev/null)' (want $$) waited=$((_t1 - _t0))s"
fi
release_forge_slot

# 11. Lying mkdir, K=2: the first acquire gets slot-1, the second slot-2, the third (both holders live) fails open.
fresh
PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _a="${FORGE_SLOT_HELD:-}"
PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _b="${FORGE_SLOT_HELD:-}"
PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _c="${FORGE_SLOT_HELD:-}"
if [ "$_a" = "$SLOTS/slot-1" ] && [ "$_b" = "$SLOTS/slot-2" ] && [ -z "$_c" ]; then
    ok "lying mkdir, K=2: slot-1, then slot-2, then fail open"
else
    bad "lying mkdir, K=2: got '$_a' / '$_b' / '$_c'"
fi
FORGE_SLOT_HELD=""

# 12. An existing empty slot dir (an old-version crash between mkdir and the stamp) is acquirable, not a leak.
fresh; mkdir "$SLOTS/slot-1"
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ "$_r" = "$SLOTS/slot-1" ]; then
    ok "an empty slot dir with no pid is acquired"
else
    bad "empty slot dir with no pid: got '$_r'"
fi

# 13. An EMPTY pid whose creator is alive (its claim pid.c.<pid> names a live process: a holder between its create
#     and its write) is never reclaimed: with WAIT=1 the acquire fails open and both files are kept.
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/pid.c.$$"
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ -z "$_r" ] && [ -f "$SLOTS/slot-1/pid" ] && [ ! -s "$SLOTS/slot-1/pid" ]; then
    ok "an empty stamp claimed by a live creator is never reclaimed (fail open, file kept)"
else
    bad "empty pid stamp: got '$_r', pid file $( [ -f "$SLOTS/slot-1/pid" ] && echo kept || echo removed)"
fi

# 14. A reclaimer that read a holder which has since exited, while the slot was re-taken by a live holder, never
#     removes the new holder's stamp.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$$" > "$SLOTS/slot-1/pid"
if have_reclaim; then
    _fss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$$" ] && [ "$(ls -A "$SLOTS/slot-1")" = pid ]; then
        ok "reclaim of a stale (dead) holder never removes a newer live holder's stamp"
    else
        bad "stale reclaim touched the new holder: pid='$(cat "$SLOTS/slot-1/pid" 2>/dev/null)' entries=[$(entries "$SLOTS/slot-1" ' ')]"
    fi
else
    bad "stale reclaim: _fss_reclaim is not defined"
fi

# 15. Two reclaimers for one dead holder: only the owner of reap.<pid>.1 acts; while that owner lives, a second one
#     changes nothing.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; printf '%s' "$$" > "$SLOTS/slot-1/reap.$_dead2.1"
if have_reclaim; then
    _fss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_dead2" ] && [ -f "$SLOTS/slot-1/reap.$_dead2.1" ]; then
        ok "a reclaim whose reap token has a live owner changes nothing"
    else
        bad "second reclaimer acted: entries=[$(entries "$SLOTS/slot-1" ' ')]"
    fi
else
    bad "concurrent reclaim: _fss_reclaim is not defined"
fi

# 16. A dead holder is reclaimed through the acquire path, and no reap token is left behind.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot
if [ "${FORGE_SLOT_HELD:-}" = "$SLOTS/slot-1" ] && [ "$(ls -A "$SLOTS/slot-1")" = pid ] \
   && [ "$(cat "$SLOTS/slot-1/pid")" = "$$" ]; then
    ok "dead-holder slot is reclaimed and re-acquired with no reap token left"
else
    bad "dead-holder reclaim: held='${FORGE_SLOT_HELD:-}' entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi
release_forge_slot

# 17. Garbage holder content is a dead holder: reclaimed, and nothing is created outside the pool. The fullwidth
#     digits are literal UTF-8 glyphs (dash-safe: no \xHH escapes); 99999999999 is past any real PID (bash in POSIX
#     mode returns 0 for `kill -0` on it, as for `kill -0 abc`).
_t17_fail=""
_tmp_before="$(ls -A "$TMP")"
for _g in abc 0 007 ../x '１２３' 99999999999; do
    fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_g" > "$SLOTS/slot-1/pid"
    # shellcheck disable=SC2016
    _r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
    if [ "$_r" != "$SLOTS/slot-1" ] || [ "$(ls -A "$SLOTS")" != slot-1 ] || [ "$(ls -A "$SLOTS/slot-1")" != pid ] \
       || [ "$(ls -A "$TMP")" != "$_tmp_before" ]; then
        _t17_fail="$_t17_fail [$_g: held='$_r' slot=$(entries "$SLOTS/slot-1" ',')]"
    fi
done
if [ -z "$_t17_fail" ]; then
    ok "garbage holder content (abc, 0, 007, ../x, fullwidth digits, 11 digits) is reclaimed inside the pool"
else
    bad "garbage holder content:$_t17_fail"
fi

# 17b. ... and a garbage holder is reclaimed through the reap.invalid.<g> tokens: while reap.invalid.1 has a live
#      owner, a garbage holder is left alone (so no garbage ever becomes part of a path).
_t17b_fail=""
if have_reclaim; then
    for _g in abc 0 007 ../x '１２３' -1 99999999999; do
        fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_g" > "$SLOTS/slot-1/pid"; printf '%s' "$$" > "$SLOTS/slot-1/reap.invalid.1"
        _fss_reclaim "$SLOTS/slot-1" "$_g"
        [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_g" ] || _t17b_fail="$_t17b_fail [$_g]"
    done
else
    _t17b_fail=" _fss_reclaim is not defined"
fi
if [ -z "$_t17b_fail" ]; then
    ok "every garbage holder maps to reap.invalid (owned token -> left alone)"
else
    bad "garbage holder bypassed reap.invalid:$_t17b_fail"
fi

# 18. TERM during a reclaim: the trap's release removes the reap token this shell owns (named in _FSS_REAP and
#     stamped with this shell's pid) and clears the variable.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$$" > "$SLOTS/slot-1/reap.$_dead2.1"
_FSS_REAP="$SLOTS/slot-1/reap.$_dead2.1"; FORGE_SLOT_HELD=""
release_forge_slot
if [ ! -e "$SLOTS/slot-1/reap.$_dead2.1" ] && [ -z "${_FSS_REAP:-}" ]; then
    ok "release removes the reap token this shell owns and clears _FSS_REAP"
else
    bad "release left the reap token (exists=$( [ -e "$SLOTS/slot-1/reap.$_dead2.1" ] && echo yes || echo no), _FSS_REAP='${_FSS_REAP:-}')"
fi

# 18b. A TERM that lands after _FSS_REAP is named but before this shell created the token never removes another
#      reclaimer's token (stamped with that reclaimer's pid).
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/reap.$_dead2.1"
_FSS_REAP="$SLOTS/slot-1/reap.$_dead2.1"; FORGE_SLOT_HELD=""
release_forge_slot
if [ -e "$SLOTS/slot-1/reap.$_dead2.1" ] && [ -z "${_FSS_REAP:-}" ]; then
    ok "release never removes a reap token another reclaimer owns"
else
    bad "release removed a foreign reap token or kept _FSS_REAP='${_FSS_REAP:-}'"
fi
_FSS_REAP=""

# 19. A pool path containing a space: acquire, release and dead-holder reclaim all work.
SLOTS_SAVE="$SLOTS"
export FORGE_SLOTS_DIR="$TMP/pool dir/slots"
SLOTS="$FORGE_SLOTS_DIR"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _s1="${FORGE_SLOT_HELD:-}"
release_forge_slot
mkdir -p "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; _s2="${FORGE_SLOT_HELD:-}"
release_forge_slot
if [ "$_s1" = "$SLOTS/slot-1" ] && [ "$_s2" = "$SLOTS/slot-1" ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "" ]; then
    ok "a pool path with a space: acquire, release and dead-holder reclaim work"
else
    bad "pool path with a space: first='$_s1' reclaimed='$_s2'"
fi
export FORGE_SLOTS_DIR="$SLOTS_SAVE"
SLOTS="$SLOTS_SAVE"

# 20. The pool filesystem accepts the create but refuses the write (EFBIG under `ulimit -f 0` stands in for ENOSPC /
#     EDQUOT): the acquirer removes its own empty stamp and fails open at once instead of poisoning every free slot;
#     once writes work again the next acquire gets slot-1.
fresh
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'trap "" XFSZ; ulimit -f 0; FORGE_MAX_SLOTS=3 FORGE_SLOT_WAIT_S=5 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
_left=""; for _i in 1 2 3; do [ -n "$(entries "$SLOTS/slot-$_i" ' ')" ] && _left="$_left slot-$_i:$(entries "$SLOTS/slot-$_i" ',')"; done
# shellcheck disable=SC2016
_r2="$(child 'FORGE_MAX_SLOTS=3 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ -z "$_r" ] && [ "$((_t1 - _t0))" -lt 5 ] && [ -z "$_left" ] && [ "$_r2" = "$SLOTS/slot-1" ]; then
    ok "a failed stamp write gives the slot back (no stamp, no claim left) and fails open at once ($((_t1 - _t0))s); healthy writes get slot-1"
else
    bad "write failure: held='$_r' after $((_t1 - _t0))s, files left:[$_left], next acquire='$_r2'"
fi

# 21. A stalled but LIVE creator (claim names a live process) keeps its empty stamp for longer than any time bound
#     (12 s here, past the 10 s bound of an earlier revision): the waiter fails open, stamp and claim stay.
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/pid.c.$_live"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=12 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ -z "$_r" ] && [ "$((_t1 - _t0))" -ge 12 ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid pid.c.$_live " ]; then
    ok "a stalled live creator's empty stamp survives $((_t1 - _t0))s of waiting (fail open, stamp and claim kept)"
else
    bad "stalled live creator: held='$_r' after $((_t1 - _t0))s, entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 22. A reclaimer killed between creating its reap token and stamping it leaves an EMPTY token with no live claim:
#     it is taken over at once (next generation), and every token of that holder is swept. While the empty token's
#     claim names a live process, a climber stops there instead.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/reap.$_dead2.1"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
_t22_live=no
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
: > "$SLOTS/slot-1/reap.$_dead2.1"; : > "$SLOTS/slot-1/reap.$_dead2.1.c.$_live"
if have_reclaim; then
    _fss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_dead2" ] && [ ! -e "$SLOTS/slot-1/reap.$_dead2.2" ]; then
        _t22_live=yes
    fi
fi
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -lt 4 ] && [ "$_t22_live" = yes ]; then
    ok "an unclaimed empty reap token is taken over at once ($((_t1 - _t0))s); a live-claimed one stops the climb"
else
    bad "empty reap token: held='$_r' after $((_t1 - _t0))s, live-claimed token respected=$_t22_live"
fi

# 23. A reap token whose owner is dead (a reclaimer killed mid-reclaim) is taken over at once through the next
#     generation, and no token is left.
sleep 0 & _dead3=$!; wait "$_dead3" 2>/dev/null || true
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; printf '%s' "$_dead3" > "$SLOTS/slot-1/reap.$_dead2.1"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -lt 10 ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
    ok "a reap token with a dead owner is taken over at once (took $((_t1 - _t0))s), no token left"
else
    bad "dead-owner reap token: held='$_r' after $((_t1 - _t0))s, entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 24. Two takers never both proceed: a climber that finds generation 1 dead but generation 2 owned by a live
#     reclaimer stops; the stamp and both tokens stay.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
printf '%s' "$_dead3" > "$SLOTS/slot-1/reap.$_dead2.1"; printf '%s' "$$" > "$SLOTS/slot-1/reap.$_dead2.2"
if have_reclaim; then
    _fss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_dead2" ] && [ -f "$SLOTS/slot-1/reap.$_dead2.1" ] \
       && [ -f "$SLOTS/slot-1/reap.$_dead2.2" ] && [ ! -e "$SLOTS/slot-1/reap.$_dead2.3" ]; then
        ok "a token takeover stops at a live owner's generation (no second reclaimer proceeds)"
    else
        bad "takeover passed a live owner: entries=[$(entries "$SLOTS/slot-1" ' ')]"
    fi
else
    bad "takeover: _fss_reclaim is not defined"
fi

# 25. A reclaimer SIGKILLed at each external step of a reclaim (after winning its token, just before removing the
#     stamp; right after removing it; while sweeping its tokens) never leaks the slot: the next acquirer gets slot-1
#     and no token is left. A stop-shim for rm on the reclaimer's PATH records its PID and hangs at the named step
#     (the sweep point skips the token's own claim cleanup, which runs before the re-check, so it stops in the sweep
#     that follows the stamp's removal).
#     (A kill between a token's create and its stamp, inside one builtin redirection, leaves the empty token of
#     case 22.)
KSHIM="$TMP/kshim"; mkdir -p "$KSHIM"
KREAL_RM="$(command -v rm)"; KSTOP_READY="$TMP/kready"
export KREAL_RM KSTOP_READY
cat > "$KSHIM/rm" <<'KSHIM_EOF'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
case "$KSTOP_AT:$last" in
    prerm:*/pid)
        for t in "${last%/pid}"/reap.*; do
            if [ -e "$t" ]; then echo "$$" > "$KSTOP_READY"; exec sleep 60; fi
        done ;;
    rmstamp:*/pid)
        "$KREAL_RM" "$@"; echo "$$" > "$KSTOP_READY"; exec sleep 60 ;;
    sweep:*/reap.*.c.*) ;;
    sweep:*/reap.*)
        echo "$$" > "$KSTOP_READY"; exec sleep 60 ;;
esac
exec "$KREAL_RM" "$@"
KSHIM_EOF
chmod +x "$KSHIM/rm"
_t25_fail=""
for _step in prerm rmstamp sweep; do
    fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; rm -f "$KSTOP_READY"
    # shellcheck disable=SC2016
    env PATH="$KSHIM:$PATH" KSTOP_AT="$_step" sh -c '. "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=30 acquire_forge_slot' \
        sh "$LIB" >/dev/null 2>&1 &
    _rpid=$!
    _n=0
    while [ ! -s "$KSTOP_READY" ] && [ "$_n" -lt 100 ]; do sleep 0.1; _n=$((_n + 1)); done
    kill -KILL "$_rpid" 2>/dev/null || true
    [ -s "$KSTOP_READY" ] && { kill -KILL "$(cat "$KSTOP_READY")" 2>/dev/null || true; }
    wait "$_rpid" 2>/dev/null || true
    _state="$(entries "$SLOTS/slot-1" ',')"
    # shellcheck disable=SC2016
    _r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
    if [ ! -s "$KSTOP_READY" ]; then
        _t25_fail="$_t25_fail [$_step: never reached]"
    elif [ "$_r" != "$SLOTS/slot-1" ] || [ "$(entries "$SLOTS/slot-1" ' ')" != "pid " ]; then
        _t25_fail="$_t25_fail [$_step: killed with {$_state}, next held='$_r', left=$(entries "$SLOTS/slot-1" ',')]"
    fi
done
if [ -z "$_t25_fail" ]; then
    ok "a reclaimer SIGKILLed before removing the stamp, right after it, or while sweeping never leaks the slot"
else
    bad "SIGKILLed reclaimer leaked the slot:$_t25_fail"
fi

# 26. An EMPTY stamp whose only claim names a DEAD process (its creator was killed between create and write) is
#     reclaimed at once, and the dead claim is swept.
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/pid.c.$_dead2"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -lt 4 ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
    ok "an empty stamp with only a dead creator's claim is reclaimed at once ($((_t1 - _t0))s), the claim swept"
else
    bad "dead creator's claim: held='$_r' after $((_t1 - _t0))s, entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 27. Carry-over: two waiters both judge the same dead empty stamp; right after one of them removes it, a new
#     creator's stamp appears, still empty and claimed by a live process (an rm shim swaps it in instead of the
#     reclaim's removal). Neither waiter may take that slot from the live creator, however long they had been
#     watching the old stamp: both fail open and the new stamp and its claim stay. (WAIT=13 outlasts the 10 s
#     marker of an earlier revision, which carried over to the new stamp and double-admitted here.)
sleep 60 & _live=$!
CSHIM="$TMP/cshim"; mkdir -p "$CSHIM"; rm -f "$TMP/crecreated"
export CREAL_RM="$KREAL_RM" CLIVE="$_live" CMARK="$TMP/crecreated"
# Gap-free: the first removal of the stamp is replaced by an atomic rename of a fresh empty stamp over it (claim
# first), so the stamp never disappears and no waiter can legitimately win the slot in between.
cat > "$CSHIM/rm" <<'CSHIM_EOF'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    */pid)
        if ( set -C; true > "$CMARK" ) 2>/dev/null; then
            true > "$last.c.$CLIVE"; true > "$last.new"; mv -f "$last.new" "$last"
            exit 0
        fi ;;
esac
exec "$CREAL_RM" "$@"
CSHIM_EOF
chmod +x "$CSHIM/rm"
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"
_t0=$(date +%s)
# shellcheck disable=SC2016
env PATH="$CSHIM:$PATH" sh -c '. "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=13 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD" > "$2"' \
    sh "$LIB" "$TMP/w1.out" 2>/dev/null &
_w1=$!
# shellcheck disable=SC2016
env PATH="$CSHIM:$PATH" sh -c '. "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=13 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD" > "$2"' \
    sh "$LIB" "$TMP/w2.out" 2>/dev/null &
_w2=$!
wait "$_w1" 2>/dev/null || true; wait "$_w2" 2>/dev/null || true
_t1=$(date +%s)
_h1="$(cat "$TMP/w1.out" 2>/dev/null)"; _h2="$(cat "$TMP/w2.out" 2>/dev/null)"
_e27="$(entries "$SLOTS/slot-1" ' ')"
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ -f "$TMP/crecreated" ] && [ -z "$_h1" ] && [ -z "$_h2" ] && [ "$_e27" = "pid pid.c.$_live " ] \
   && [ ! -s "$SLOTS/slot-1/pid" ]; then
    ok "after a reclaim, a live creator's fresh empty stamp is never taken by either waiter ($((_t1 - _t0))s, both failed open)"
else
    bad "carry-over: recreated=$( [ -f "$TMP/crecreated" ] && echo yes || echo no) w1='$_h1' w2='$_h2' entries=[$_e27]"
fi

# 28. No generation bound: 20 reap tokens of one dead holder, each owned by a dead reclaimer (20 reclaimers killed
#     back to back, past the 16-generation cap of an earlier revision that then leaked the slot), are climbed; the
#     acquire reclaims the slot and sweeps every token.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
_g=1
while [ "$_g" -le 20 ]; do
    sleep 0 & _dg=$!; wait "$_dg" 2>/dev/null || true
    printf '%s' "$_dg" > "$SLOTS/slot-1/reap.$_dead2.$_g"
    _g=$((_g + 1))
done
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
    ok "20 dead-reclaimer token generations are climbed: the slot is reclaimed and every token swept"
else
    bad "20 dead token generations: held='$_r', entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 29. A holder that releases between an acquirer's `mkdir slot-1` and its claim neither makes that acquirer fail open
#     nor costs it the slot: release keeps the slot dir (it is only a container), so the claim and the create find
#     it. A `mkdir` shim on the acquirer's PATH hands control to the live holder right after the acquirer's mkdir of
#     the slot and records whether the dir survived the release. (An earlier revision removed the dir there; a waiter
#     re-creating it before the acquirer looked made the acquirer fail open at once while the waiter took the slot.)
MSHIM="$TMP/mshim"; mkdir -p "$MSHIM"; rm -f "$TMP/m.go" "$TMP/m.released" "$TMP/m.dir" "$TMP/m.mark"
export MREAL_MKDIR="$REAL_MKDIR" MGO="$TMP/m.go" MREL="$TMP/m.released" MDIR="$TMP/m.dir" MMARK="$TMP/m.mark"
cat > "$MSHIM/mkdir" <<'MSHIM_EOF'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
"$MREAL_MKDIR" "$@"; rc=$?
case "$last" in
    */slot-1)
        if ( set -C; true > "$MMARK" ) 2>/dev/null; then
            true > "$MGO"
            n=0
            while [ ! -e "$MREL" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
            if [ -d "$last" ]; then echo kept > "$MDIR"; else echo removed > "$MDIR"; fi
        fi ;;
esac
exit "$rc"
MSHIM_EOF
chmod +x "$MSHIM/mkdir"
fresh
# shellcheck disable=SC2016
sh -c '. "$1"; FORGE_MAX_SLOTS=1 acquire_forge_slot; n=0
       while [ ! -e "$2" ] && [ "$n" -lt 200 ]; do sleep 0.05; n=$((n + 1)); done
       release_forge_slot; true > "$3"' sh "$LIB" "$MGO" "$MREL" >/dev/null 2>&1 &
_hpid=$!
_n=0
while [ ! -s "$SLOTS/slot-1/pid" ] && [ "$_n" -lt 100 ]; do sleep 0.05; _n=$((_n + 1)); done
# shellcheck disable=SC2016
_r="$(env PATH="$MSHIM:$PATH" sh -c 'set -eu; . "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"' \
    sh "$LIB" 2>/dev/null || printf 'ABORTED')"
wait "$_hpid" 2>/dev/null || true
_d29="$(cat "$MDIR" 2>/dev/null)"
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$_d29" = kept ]; then
    ok "a release between an acquirer's mkdir and its claim keeps the slot dir; the acquirer takes the slot"
else
    bad "release during an acquirer's mkdir->claim gap: held='$_r', slot dir after the release: '${_d29:-never reached}'"
fi

# 30. PID reuse inside a reclaim: the reclaimer saw holder H dead, but at its re-check under the token the stamp names H
#     again and H is alive (a new holder reused the PID). It must not remove that stamp. A shell function `kill` that
#     reports H dead on its first call only stands in for the reuse (a function shadows the regular builtin in bash and
#     dash).
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_live" > "$SLOTS/slot-1/pid"
_t30=no
if have_reclaim; then
    (
        _kn=0
        # shellcheck disable=SC2329  # invoked by the library's `kill -0`, which this function shadows
        kill() { _kn=$((_kn + 1)); if [ "$_kn" = 1 ]; then return 1; fi; command kill "$@"; }
        _fss_reclaim "$SLOTS/slot-1" "$_live"
    )
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_live" ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
        _t30=yes
    fi
fi
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ "$_t30" = yes ]; then
    ok "a stamp whose PID came back to life (reuse) is never removed by the re-check under the token"
else
    bad "PID reuse at the re-check: stamp='$(cat "$SLOTS/slot-1/pid" 2>/dev/null)' (want $_live), entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 31. The slot dir vanishes between an acquirer's `mkdir slot-1` and its claim (a pre-#2362 holder still running during
#     an upgrade removes it on release, or the pool is deleted): the acquirer re-creates the dir and decides by one
#     more attempt, so it takes the freed slot instead of failing open at once. A `mkdir` shim does that old-style
#     release (stamp, then dir) right after the acquirer's mkdir of the slot.
VSHIM="$TMP/vshim"; mkdir -p "$VSHIM"; rm -f "$TMP/v.mark"
export VREAL_MKDIR="$REAL_MKDIR" VMARK="$TMP/v.mark"
cat > "$VSHIM/mkdir" <<'VSHIM_EOF'
#!/bin/sh
last=""
for a in "$@"; do last="$a"; done
"$VREAL_MKDIR" "$@"; rc=$?
case "$last" in
    */slot-1)
        if ( set -C; true > "$VMARK" ) 2>/dev/null; then
            rm -f "$last/pid"; rmdir "$last"
        fi ;;
esac
exit "$rc"
VSHIM_EOF
chmod +x "$VSHIM/mkdir"
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_live" > "$SLOTS/slot-1/pid"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(env PATH="$VSHIM:$PATH" sh -c 'set -eu; . "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=4 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"' \
    sh "$LIB" 2>/dev/null || printf 'ABORTED')"
_t1=$(date +%s)
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ -f "$TMP/v.mark" ] && [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -lt 4 ]; then
    ok "a slot dir removed between an acquirer's mkdir and its claim is re-created; the acquirer takes the slot ($((_t1 - _t0))s)"
else
    bad "slot dir removed under an acquirer: shim fired=$( [ -f "$TMP/v.mark" ] && echo yes || echo no), held='$_r' after $((_t1 - _t0))s"
fi

# 32-34 inject read faults on both ways a library can read a stamp or token: a `cat` that fails with no output (a
# PATH shim, for libraries that read through command substitution) and a shell function `read` that fails (it shadows
# the builtin in bash and dash). A failed read must never pass for an empty file: only the size test decides that.
FSHIM="$TMP/fshim"; mkdir -p "$FSHIM"
FREAL_CAT="$(command -v cat)"; export FREAL_CAT
cat > "$FSHIM/cat" <<'FSHIM_EOF'
#!/bin/sh
for a in "$@"; do
    case "$a" in
        $FAIL_GLOB)
            if [ -z "${FAIL_ONCE:-}" ]; then exit 1; fi
            if ( set -C; true > "$FAIL_ONCE" ) 2>/dev/null; then exit 1; fi ;;
    esac
done
exec "$FREAL_CAT" "$@"
FSHIM_EOF
chmod +x "$FSHIM/cat"

# 32. A live holder's stamp that cannot be read is never reclaimed: the acquirer (K=1) waits its budget and fails
#     open, and the holder's stamp stays.
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_live" > "$SLOTS/slot-1/pid"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(env PATH="$FSHIM:$PATH" FAIL_GLOB='*/slot-1/pid' sh -c 'set -eu; . "$1"; read() { return 1; }
    FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"' sh "$LIB" 2>/dev/null || printf 'ABORTED')"
_t1=$(date +%s)
_s32="$(cat "$SLOTS/slot-1/pid" 2>/dev/null)"
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ -z "$_r" ] && [ "$((_t1 - _t0))" -ge 2 ] && [ "$_s32" = "$_live" ]; then
    ok "an unreadable stamp of a live holder is never reclaimed (waited $((_t1 - _t0))s, failed open, stamp kept)"
else
    bad "unreadable live stamp: held='$_r' after $((_t1 - _t0))s, stamp='$_s32' (want $_live)"
fi

# 33. A reap token whose owner is live but whose content cannot be read never lets a climber pass: the dead holder's
#     stamp, the live owner's token and nothing else stay.
sleep 60 & _live=$!
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; printf '%s' "$_live" > "$SLOTS/slot-1/reap.$_dead2.1"
# shellcheck disable=SC2016
env PATH="$FSHIM:$PATH" FAIL_GLOB='*/reap.*' sh -c 'set -eu; . "$1"; read() { return 1; }; _fss_reclaim "$2" "$3"' \
    sh "$LIB" "$SLOTS/slot-1" "$_dead2" >/dev/null 2>&1 || true
_e33="$(entries "$SLOTS/slot-1" ' ')"
kill "$_live" 2>/dev/null || true; wait "$_live" 2>/dev/null || true
if [ "$_e33" = "pid reap.$_dead2.1 " ] && [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_dead2" ]; then
    ok "an unreadable live reap token stops the climb (stamp and token untouched)"
else
    bad "unreadable live reap token: entries=[$_e33]"
fi

# 34. Release reads its own stamp with the builtin and retries one unreadable read: a transient failure still frees
#     the slot; a stamp that stays unreadable is kept (it names us, so PID liveness frees it after we exit) and the
#     caller's handle is cleared either way.
fresh; rm -f "$TMP/f34.once"
# shellcheck disable=SC2016
_r34a="$(env PATH="$FSHIM:$PATH" FAIL_GLOB='*/slot-1/pid' FAIL_ONCE="$TMP/f34.once" sh -c 'set -eu; . "$1"
    FORGE_MAX_SLOTS=1 acquire_forge_slot
    _rn=0; read() { _rn=$((_rn + 1)); if [ "$_rn" = 1 ]; then return 1; fi; command read "$@"; }
    release_forge_slot; if [ -e "$2/slot-1/pid" ]; then printf kept; else printf freed; fi; printf "/%s" "$FORGE_SLOT_HELD"' \
    sh "$LIB" "$SLOTS" 2>/dev/null || printf 'ABORTED')"
fresh
# shellcheck disable=SC2016
_r34b="$(env PATH="$FSHIM:$PATH" FAIL_GLOB='*/slot-1/pid' sh -c 'set -eu; . "$1"
    FORGE_MAX_SLOTS=1 acquire_forge_slot; read() { return 1; }
    release_forge_slot; if [ "$(cat "$2/slot-1/pid" 2>/dev/null || command -p cat "$2/slot-1/pid")" = "$$" ]; then printf kept; else printf gone; fi
    printf "/%s" "$FORGE_SLOT_HELD"' sh "$LIB" "$SLOTS" 2>/dev/null || printf 'ABORTED')"
if [ "$_r34a" = "freed/" ] && [ "$_r34b" = "kept/" ]; then
    ok "release retries one unreadable read (transient: slot freed) and keeps a stamp that stays unreadable"
else
    bad "release with an unreadable stamp: transient='$_r34a' (want freed/), persistent='$_r34b' (want kept/)"
fi

# 35. A slot entry the gate cannot repair (here a non-empty directory at slot-1/pid: rm -f and rmdir both refuse it)
#     costs one slot, never the cap: at K=2 the first acquirer takes slot-2 and a second one waits its budget and
#     fails open (max concurrency 1). Only a pass in which every slot refused fails open at once.
fresh; mkdir -p "$SLOTS/slot-1/pid/x"
FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _a35="${FORGE_SLOT_HELD:-}"
_t0=$(date +%s)
# shellcheck disable=SC2016
_b35="$(child 'FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
release_forge_slot
fresh; mkdir -p "$SLOTS/slot-1/pid/x" "$SLOTS/slot-2/pid/x"
_t2=$(date +%s)
# shellcheck disable=SC2016
_c35="$(child 'FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=5 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t3=$(date +%s)
if [ "$_a35" = "$SLOTS/slot-2" ] && [ -z "$_b35" ] && [ "$((_t1 - _t0))" -ge 2 ] && [ -z "$_c35" ] \
   && [ "$((_t3 - _t2))" -lt 2 ]; then
    ok "a refused slot entry costs one slot (slot-2 taken, a second acquirer waited $((_t1 - _t0))s); all refused fails open at once"
else
    bad "refused slot: first='$_a35' second='$_b35' after $((_t1 - _t0))s, all-refused='$_c35' after $((_t3 - _t2))s"
fi

# 36. The empty-stamp verdict and the removal it leads to act on one file instance. A dead creator's empty stamp;
#     W reclaims it and re-creates the slot, stalled between create and write (a `printf` hook), then holds 2 s. R (a
#     copy of the library whose claim scan is wrapped in stalls) judges W's still-empty stamp: its scan runs after W
#     wrote and dropped its claim, and it then sleeps through W's whole hold and release, while C binds a fresh empty
#     stamp (stalled the same way). A verdict that re-reads the path (size after scan, without pinning) would now see
#     C's empty stamp and remove it. Judged on the pinned instance (W's, written), it does not. A probe counts the
#     holders: never more than 1 at K=1, and W, C and R all hold the slot in turn.
P36="$TMP/p36"; rm -rf "$P36"; mkdir -p "$P36"
sed 's/^_fss_unclaimed() {/_fss_unclaimed_real() {/' "$LIB" > "$TMP/rlib36.sh"
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/pid.c.$_dead2"
# shellcheck disable=SC2016,SC2089,SC2090  # code strings eval'd by the children below
HOLD36='_hold() { if [ -n "$FORGE_SLOT_HELD" ]; then : > "$P36/run.$$"; ls "$P36" | grep -c "^run\." >> "$P36/counts"; echo "$1" >> "$P36/held"; sleep "$2"; rm -f "$P36/run.$$"; fi; release_forge_slot; }'
# shellcheck disable=SC2016,SC2089,SC2090
STALL36='printf() { if [ "${2:-}" = "$$" ] && [ -z "${_FSS_REAP:-}" ]; then sleep "$STALL"; fi; command printf "$@"; }'
# shellcheck disable=SC2090
export P36 HOLD36 STALL36
# shellcheck disable=SC2016
sh -c '. "$1"; eval "$HOLD36"; _n=0
    _fss_unclaimed() { _n=$((_n + 1)); if [ "$_n" -eq 2 ]; then sleep 3; fi; _fss_unclaimed_real "$@"; _r=$?
        if [ "$_n" -eq 1 ]; then sleep 2; fi; if [ "$_n" -eq 2 ]; then sleep 4; fi; return "$_r"; }
    FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=40 acquire_forge_slot; _hold R 3' sh "$TMP/rlib36.sh" >/dev/null 2>&1 &
_r36=$!
sleep 0.3
# shellcheck disable=SC2016
STALL=3 sh -c '. "$1"; eval "$HOLD36"; eval "$STALL36"
    FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=40 acquire_forge_slot; _hold W 2' sh "$LIB" >/dev/null 2>&1 &
_w36=$!
sleep 5.7
# shellcheck disable=SC2016
STALL=6 sh -c '. "$1"; eval "$HOLD36"; eval "$STALL36"
    FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=40 acquire_forge_slot; _hold C 2' sh "$LIB" >/dev/null 2>&1 &
_c36=$!
wait "$_r36" "$_w36" "$_c36" 2>/dev/null || true
_max36="$(sort -n "$P36/counts" 2>/dev/null | tail -1)"
_held36="$(sort "$P36/held" 2>/dev/null | tr '\n' ' ')"
if [ "$_max36" = 1 ] && [ "$_held36" = "C R W " ]; then
    ok "the empty-stamp verdict is pinned to one instance: a whole hold cycle between scan and size test never doubles the slot"
else
    bad "empty-stamp verdict across a hold cycle: max holders='${_max36:-none}' (want 1), held=[$_held36] (want C R W)"
fi

# 37. A caller's restrictive umask never poisons the pool: an acquire+release under `umask 0177` (which strips the
#     owner's x bit) leaves slot dirs every later acquirer can use, and entries already left unusable by an earlier
#     run or another version (mode 0600 dirs) are repaired once and used.
fresh
# shellcheck disable=SC2016
_r37="$(child 'umask 0177; FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"; release_forge_slot')"
FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _a37="${FORGE_SLOT_HELD:-}"
# shellcheck disable=SC2016
_b37="$(child 'FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
release_forge_slot
fresh; mkdir -m 0600 "$SLOTS/slot-1" "$SLOTS/slot-2"
# shellcheck disable=SC2016
_c37="$(child 'FORGE_MAX_SLOTS=2 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
chmod 0700 "$SLOTS/slot-1" "$SLOTS/slot-2" 2>/dev/null || true
if [ "$_r37" = "$SLOTS/slot-1" ] && [ "$_a37" = "$SLOTS/slot-1" ] && [ "$_b37" = "$SLOTS/slot-2" ] && [ "$_c37" = "$SLOTS/slot-1" ]; then
    ok "umask 0177 leaves usable slot dirs, and 0600 slot dirs from an earlier run are repaired"
else
    bad "restrictive umask: under 0177 '$_r37', later '$_a37' + '$_b37' (want slot-1 + slot-2), over 0600 dirs '$_c37'"
fi

# 38. A stamp written under `umask 0477` (no owner read) can still be read back, so a crashed holder's slot is
#     reclaimed; a stamp already left unreadable by an earlier run (mode 0200, dead holder) is repaired once and
#     reclaimed. Neither leaks the slot.
fresh
# shellcheck disable=SC2016
child 'umask 0477; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot' >/dev/null
# shellcheck disable=SC2016
_a38="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=3 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; chmod 0200 "$SLOTS/slot-1/pid"
# shellcheck disable=SC2016
_b38="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=3 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ "$_a38" = "$SLOTS/slot-1" ] && [ "$_b38" = "$SLOTS/slot-1" ]; then
    ok "a stamp under umask 0477 stays readable (crashed holder reclaimed), and a 0200 stamp is repaired and reclaimed"
else
    bad "unreadable stamps: after a 0477 holder crashed '$_a38', over a 0200 dead stamp '$_b38' (want slot-1 both)"
fi

# 39. A stamp whose first line is empty (here only "\n") is content the gate never writes (it writes the PID with no
#     newline): it is reaped as `invalid`, not kept as an unreadable live holder.
fresh; mkdir "$SLOTS/slot-1"; printf '\n' > "$SLOTS/slot-1/pid"
# shellcheck disable=SC2016
_r39="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=3 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ "$_r39" = "$SLOTS/slot-1" ]; then
    ok "a blank-first-line stamp (not written by the gate) is reaped as invalid"
else
    bad "blank-first-line stamp: held='$_r39' (want slot-1)"
fi

# 40. A symlink at the stamp path (here to /dev/null) is never opened: noclobber would let every acquirer "win" it.
#     It is removed once, the slot gets a real stamp, and at K=1 a second acquirer waits and fails open.
fresh; mkdir "$SLOTS/slot-1"; ln -s /dev/null "$SLOTS/slot-1/pid"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; _a40="${FORGE_SLOT_HELD:-}"
# shellcheck disable=SC2016
_b40="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_s40="no"; if [ -f "$SLOTS/slot-1/pid" ] && [ ! -h "$SLOTS/slot-1/pid" ] && [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$$" ]; then _s40=yes; fi
release_forge_slot
if [ "$_a40" = "$SLOTS/slot-1" ] && [ -z "$_b40" ] && [ "$_s40" = yes ]; then
    ok "a symlinked stamp path is replaced by a real stamp; a second acquirer at K=1 does not get the slot"
else
    bad "symlinked stamp path: first='$_a40' second='$_b40' (want slot-1 then nothing), real stamp=$_s40"
fi

# 41. A FIFO at the stamp path is never opened (an open would block forever, with no bounded wait): it is removed
#     once and the acquire takes the slot within its budget.
fresh; mkdir "$SLOTS/slot-1"; mkfifo "$SLOTS/slot-1/pid"; rm -f "$TMP/r41"
# shellcheck disable=SC2016
sh -c '. "$1"; FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=3 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD" > "$2"' sh "$LIB" "$TMP/r41" \
    >/dev/null 2>&1 &
_p41=$!
_n=0
while [ ! -e "$TMP/r41" ] && [ "$_n" -lt 100 ]; do sleep 0.1; _n=$((_n + 1)); done
kill "$_p41" 2>/dev/null || true; wait "$_p41" 2>/dev/null || true
_r41="$(cat "$TMP/r41" 2>/dev/null)" || _r41=""
if [ "$_r41" = "$SLOTS/slot-1" ]; then
    ok "a FIFO at the stamp path is removed, not opened: the acquire took slot-1 within its budget"
else
    bad "FIFO at the stamp path: acquire result '${_r41:-none, still blocked after 10s}'"
fi

# 42. A stray non-directory at the slot path is removed once and the slot used, so an explicit K=1 does not turn it
#     into an all-refused pass (which would fail open and disable the cap).
fresh; : > "$SLOTS/slot-1"
# shellcheck disable=SC2016
_r42="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ "$_r42" = "$SLOTS/slot-1" ] && [ -d "$SLOTS/slot-1" ]; then
    ok "a stray file at the slot path is repaired at K=1 (slot taken, no fail-open)"
else
    bad "stray file at the slot path, K=1: held='$_r42' (want slot-1)"
fi

# 43. Subshells of one shell share $$, and each still gets its own claim. S1 (a subshell of this test) is stalled
#     between its stamp create and its write; S2 (a sibling subshell, same $$) loses to S1's empty stamp and drops its
#     own claim; R (another process) then judges S1's stamp. S1's claim must still be there, so R never declares the
#     stamp dead: R fails open and S1 keeps the slot.
fresh
(
    # shellcheck disable=SC2329  # shadows the builtin inside the library's stamp write
    printf() { if [ "${2:-}" = "$$" ] && [ -z "${_FSS_REAP:-}" ]; then sleep 3; fi; command printf "$@"; }
    FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot
    echo "${FORGE_SLOT_HELD:-}" > "$TMP/s1.held"; sleep 3; release_forge_slot
) &
_s143=$!
sleep 1
( FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=0 acquire_forge_slot ) || true
# shellcheck disable=SC2016
_r43="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
wait "$_s143" 2>/dev/null || true
_h43="$(cat "$TMP/s1.held" 2>/dev/null)" || _h43=""
if [ "$_h43" = "$SLOTS/slot-1" ] && [ -z "$_r43" ]; then
    ok "sibling subshells (one \$\$) keep separate claims: a sibling's cleanup never exposes the other's empty stamp"
else
    bad "shared \$\$: S1 held='$_h43' (want slot-1), R held='$_r43' (want nothing)"
fi


echo
if [ "$FAILS" -eq 0 ]; then
    echo "demo-forge-slot.sh: PASS — the forge-slot semaphore bounds concurrency at FORGE_MAX_SLOTS,"
    echo "                    self-heals a leaked slot via PID liveness, and fails open (never deadlocks)"
    echo "                    under a bounded wait; the batch/deep-hunt forge call sites are wired; ownership"
    echo "                    never depends on mkdir's exit status (#2362)."
    exit 0
fi
echo "demo-forge-slot.sh: DEMO FAILED — a #2038 forge-slot assertion did not hold" >&2
exit 1
