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
# as tools/test-llm-session-slot.sh 10-25 under the forge names: a slot is owned
# by the exclusive create of slot-N/pid, never by mkdir's exit status; the
# reclaim never removes a newer holder's stamp; a failed stamp write, a stale
# empty stamp or reap token, and a reclaimer SIGKILLed mid-reclaim never leak a
# slot.
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
trap 'rm -rf "$TMP"' EXIT
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

# (2) release frees it (slot dir gone, FORGE_SLOT_HELD cleared).
_held="$FORGE_SLOT_HELD"
release_forge_slot
if [ ! -d "$_held" ] && [ -z "${FORGE_SLOT_HELD:-}" ]; then
    ok "release frees the slot"
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
echo "                    failure, stale empty stamps and tokens, SIGKILLed reclaimers (same cases as"
echo "                    tools/test-llm-session-slot.sh 10-25, under the forge names) ..."

# uutils mkdir 0.8.0-0.10.0 (the /usr/bin/mkdir of Ubuntu 26.04) exits 0 when a concurrent creator wins the race,
# so two contenders could both "win" one slot. LIAR/mkdir reproduces that deterministically on any host: it runs
# the real mkdir (same arguments, same stderr) and always exits 0.
SLOTS="$FORGE_SLOTS_DIR"
REAL_MKDIR="$(command -v mkdir)"
export SLOT_LIAR="$TMP/liar"
mkdir -p "$SLOT_LIAR"
printf '#!/bin/sh\n"%s" "$@"\nexit 0\n' "$REAL_MKDIR" > "$SLOT_LIAR/mkdir"
chmod +x "$SLOT_LIAR/mkdir"
fresh() { rm -rf "$SLOTS"; mkdir -p "$SLOTS"; }
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

# 13. An existing EMPTY pid (a holder between its create and its stamp) is not reclaimed before it stayed empty for
#     10 s: with WAIT=1 the acquire fails open and the file is kept (case 21 covers the reclaim after 10 s).
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ -z "$_r" ] && [ -f "$SLOTS/slot-1/pid" ] && [ ! -s "$SLOTS/slot-1/pid" ]; then
    ok "an empty pid stamp is not reclaimed inside the 10 s staleness bound (fail open, file kept)"
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
if [ "$_s1" = "$SLOTS/slot-1" ] && [ "$_s2" = "$SLOTS/slot-1" ] && [ ! -e "$SLOTS/slot-1" ]; then
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
_left=""; for _i in 1 2 3; do [ -e "$SLOTS/slot-$_i/pid" ] && _left="$_left slot-$_i"; done
# shellcheck disable=SC2016
_r2="$(child 'FORGE_MAX_SLOTS=3 FORGE_SLOT_WAIT_S=1 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
if [ -z "$_r" ] && [ "$((_t1 - _t0))" -lt 5 ] && [ -z "$_left" ] && [ "$_r2" = "$SLOTS/slot-1" ]; then
    ok "a failed stamp write gives the slot back and fails open at once ($((_t1 - _t0))s); healthy writes get slot-1"
else
    bad "write failure: held='$_r' after $((_t1 - _t0))s, stamps left:[$_left], next acquire='$_r2'"
fi

# 21. An EMPTY stamp that stays empty for 10 s (its creator died between create and write, or could not remove it)
#     is reclaimed: the acquire gets slot-1 after >= 10 s instead of never.
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=14 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -ge 10 ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
    ok "an empty stamp is reclaimed once it stayed empty for 10 s (took $((_t1 - _t0))s)"
else
    bad "stale empty stamp: held='$_r' after $((_t1 - _t0))s, entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi

# 22. A reclaimer killed between creating its reap token and stamping it leaves an EMPTY token: it is taken over
#     (next generation) once it stayed empty for 10 s, and every token of that holder is swept.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/reap.$_dead2.1"
_t0=$(date +%s)
# shellcheck disable=SC2016
_r="$(child 'FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=14 acquire_forge_slot; printf "%s" "$FORGE_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_r" = "$SLOTS/slot-1" ] && [ "$((_t1 - _t0))" -ge 10 ] && [ "$(entries "$SLOTS/slot-1" ' ')" = "pid " ]; then
    ok "an empty reap token is taken over once it stayed empty for 10 s (took $((_t1 - _t0))s), no token left"
else
    bad "stale empty reap token: held='$_r' after $((_t1 - _t0))s, entries=[$(entries "$SLOTS/slot-1" ' ')]"
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

# 25. A reclaimer SIGKILLed at each external step of a reclaim (re-reading the stamp, right after removing it, while
#     sweeping its tokens) never leaks the slot: the next acquirer gets slot-1 and no token is left. Stop-shims for
#     cat and rm on the reclaimer's PATH record their PID and hang at the named step. (A kill between a token's
#     create and its stamp, inside one builtin redirection, leaves the empty token of case 22.)
KSHIM="$TMP/kshim"; mkdir -p "$KSHIM"
KREAL_CAT="$(command -v cat)"; KREAL_RM="$(command -v rm)"; KSTOP_READY="$TMP/kready"
export KREAL_CAT KREAL_RM KSTOP_READY
for _b in cat rm; do
    cat > "$KSHIM/$_b" <<'KSHIM_EOF'
#!/bin/sh
me="${0##*/}"
if [ "$me" = cat ]; then real="$KREAL_CAT"; else real="$KREAL_RM"; fi
last=""
for a in "$@"; do last="$a"; done
case "$me:$KSTOP_AT:$last" in
    cat:reread:*/pid)
        for t in "${last%/pid}"/reap.*; do
            if [ -e "$t" ]; then echo "$$" > "$KSTOP_READY"; exec sleep 60; fi
        done ;;
    rm:rmstamp:*/pid)
        "$real" "$@"; echo "$$" > "$KSTOP_READY"; exec sleep 60 ;;
    rm:sweep:*/reap.*)
        echo "$$" > "$KSTOP_READY"; exec sleep 60 ;;
esac
exec "$real" "$@"
KSHIM_EOF
    chmod +x "$KSHIM/$_b"
done
_t25_fail=""
for _step in reread rmstamp sweep; do
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
    ok "a reclaimer SIGKILLed while re-reading, after removing the stamp, or while sweeping never leaks the slot"
else
    bad "SIGKILLed reclaimer leaked the slot:$_t25_fail"
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
