#!/usr/bin/env bash
# demo-forge-slot.sh — proof of the #2038 host-wide forge-subprocess concurrency
# cap (dark-factory/lib/forge-slot.sh).
#
# CI-safe: sources lib/forge-slot.sh directly against a temp FORGE_SLOTS_DIR, no
# real forge/toolchain, no network. Mirrors tools/test-llm-session-slot.sh's
# assertion shape for its sibling semaphore (#1352), plus a synthetic-concurrent-
# load check spawning K+1 background holders (this repo's demo-* naming
# convention for a "run it, watch it prove the thing" script — see
# demo-invariant-transient.sh, PR #2037).
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
if [ "$FAILS" -eq 0 ]; then
    echo "demo-forge-slot.sh: PASS — the forge-slot semaphore bounds concurrency at FORGE_MAX_SLOTS,"
    echo "                    self-heals a leaked slot via PID liveness, and fails open (never deadlocks)"
    echo "                    under a bounded wait; the batch/deep-hunt forge call sites are wired."
    exit 0
fi
echo "demo-forge-slot.sh: DEMO FAILED — a #2038 forge-slot assertion did not hold" >&2
exit 1
