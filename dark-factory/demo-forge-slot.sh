#!/usr/bin/env bash
# demo-forge-slot.sh — proof of the #2038 host-wide forge-subprocess concurrency
# cap (dark-factory/lib/forge-slot.sh).
#
# CI-safe: sources lib/forge-slot.sh directly against a temp FORGE_SLOTS_DIR, no
# real forge/toolchain, no network. Mirrors tools/test-llm-session-slot.sh's
# assertion shape for its sibling semaphore (#1352), plus a synthetic-concurrent-
# load check spawning K+1 background holders (this repo's demo-* naming
# convention for a "run it, watch it prove the thing" script — see
# demo-invariant-transient.sh, PR #2037). Part 4 pins #2362: a slot is owned by
# the exclusive create of slot-N/pid, never by mkdir's exit status (a lying
# mkdir that always exits 0 still yields one holder), and the dead-holder
# reclaim never removes a newer holder's stamp.
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
echo "demo-forge-slot.sh: 4) slot ownership is the exclusive create of slot-N/pid, never mkdir's exit status (#2362) ..."

# uutils mkdir 0.8.0-0.10.0 (Ubuntu 26.04's /usr/bin/mkdir) exits 0 when a concurrent creator wins the race. A
# lying mkdir (the real one, same arguments and stderr, always exit 0) reproduces that on any host.
REAL_MKDIR="$(command -v mkdir)"
export SLOT_LIAR="$TMP/liar"
mkdir -p "$SLOT_LIAR"
printf '#!/bin/sh\n"%s" "$@"\nexit 0\n' "$REAL_MKDIR" > "$SLOT_LIAR/mkdir"
chmod +x "$SLOT_LIAR/mkdir"
have_reclaim() { command -v _fss_reclaim >/dev/null 2>&1; }
# entries DIR — DIR's entries on one line, for failure messages only (the pool holds plain names).
# shellcheck disable=SC2012
entries() { ls -A "$1" 2>/dev/null | tr '\n' ' '; }
sleep 0 & _dead2=$!; wait "$_dead2" 2>/dev/null || true

# (T10) lying mkdir, K=1: this shell holds slot-1; a second contender (another process) never gets it, fails open
# after its budget (WAIT=1: two scans, >= 1 s) and the holder's pid stamp is untouched.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR"
PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot
_h1="${FORGE_SLOT_HELD:-}"
_t0=$(date +%s)
# shellcheck disable=SC2016  # expanded by the child shell
_h2="$(sh -c 'set -eu; . "$1"; PATH="$SLOT_LIAR:$PATH" FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=1 acquire_forge_slot
              printf "%s" "$FORGE_SLOT_HELD"' sh "$LIB" 2>/dev/null || printf 'ABORTED')"
_t1=$(date +%s)
if [ "$_h1" = "$FORGE_SLOTS_DIR/slot-1" ] && [ -z "$_h2" ] && [ "$(cat "$FORGE_SLOTS_DIR/slot-1/pid" 2>/dev/null)" = "$$" ] \
   && [ "$((_t1 - _t0))" -ge 1 ]; then
    ok "lying mkdir, K=1: a second contender never shares the held slot (waited $((_t1 - _t0))s, failed open)"
else
    bad "lying mkdir, K=1: first='$_h1' second='$_h2' pid='$(cat "$FORGE_SLOTS_DIR/slot-1/pid" 2>/dev/null)' (want $$)"
fi
release_forge_slot

# (T14) a reclaimer that read a since-exited holder never removes the stamp of the slot's new live holder.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR/slot-1"; printf '%s' "$$" > "$FORGE_SLOTS_DIR/slot-1/pid"
if have_reclaim; then
    _fss_reclaim "$FORGE_SLOTS_DIR/slot-1" "$_dead2"
    if [ "$(cat "$FORGE_SLOTS_DIR/slot-1/pid" 2>/dev/null)" = "$$" ] && [ "$(ls -A "$FORGE_SLOTS_DIR/slot-1")" = pid ]; then
        ok "reclaim of a stale (dead) holder never removes a newer live holder's stamp"
    else
        bad "stale reclaim touched the new holder: entries=[$(entries "$FORGE_SLOTS_DIR/slot-1")]"
    fi
else
    bad "stale reclaim: _fss_reclaim is not defined"
fi

# (T15) two reclaimers for one dead holder: only the owner of reap.<pid> acts; a second one changes nothing.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR/slot-1"
printf '%s' "$_dead2" > "$FORGE_SLOTS_DIR/slot-1/pid"; : > "$FORGE_SLOTS_DIR/slot-1/reap.$_dead2"
if have_reclaim; then
    _fss_reclaim "$FORGE_SLOTS_DIR/slot-1" "$_dead2"
    if [ "$(cat "$FORGE_SLOTS_DIR/slot-1/pid" 2>/dev/null)" = "$_dead2" ] && [ -f "$FORGE_SLOTS_DIR/slot-1/reap.$_dead2" ]; then
        ok "a reclaim whose reap token is already owned changes nothing"
    else
        bad "second reclaimer acted: entries=[$(entries "$FORGE_SLOTS_DIR/slot-1")]"
    fi
else
    bad "concurrent reclaim: _fss_reclaim is not defined"
fi

# (T16) a dead holder is reclaimed through the acquire path and no reap token is left behind.
rm -rf "$FORGE_SLOTS_DIR"; mkdir -p "$FORGE_SLOTS_DIR/slot-1"; printf '%s' "$_dead2" > "$FORGE_SLOTS_DIR/slot-1/pid"
FORGE_MAX_SLOTS=1 FORGE_SLOT_WAIT_S=2 acquire_forge_slot
if [ "${FORGE_SLOT_HELD:-}" = "$FORGE_SLOTS_DIR/slot-1" ] && [ "$(ls -A "$FORGE_SLOTS_DIR/slot-1")" = pid ]; then
    ok "dead-holder slot is reclaimed and re-acquired with no reap token left"
else
    bad "dead-holder reclaim: held='${FORGE_SLOT_HELD:-}' entries=[$(entries "$FORGE_SLOTS_DIR/slot-1")]"
fi
release_forge_slot

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
