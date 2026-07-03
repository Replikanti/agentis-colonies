#!/usr/bin/env bash
# test-llm-session-slot.sh — unit tests for the #1352 federation-wide LLM-session
# concurrency cap (tools/lib/llm-session-slot.sh). Dash-safe (CI runs sh=dash).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/llm-session-slot.sh
# shellcheck disable=SC1091
. "$HERE/lib/llm-session-slot.sh"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export AGENTIS_LLM_SLOTS_DIR="$TMP/slots"

# 1. acquire claims a slot; LLM_SLOT_HELD points at an existing dir.
LLM_MAX_CONCURRENT=2 acquire_llm_slot
if [ -n "${LLM_SLOT_HELD:-}" ] && [ -d "$LLM_SLOT_HELD" ]; then
    ok "acquire claims a slot (LLM_SLOT_HELD set to existing dir)"
else
    bad "acquire claims a slot"
fi

# 2. release frees it (slot dir gone, LLM_SLOT_HELD cleared).
_held="$LLM_SLOT_HELD"
release_llm_slot
if [ ! -d "$_held" ] && [ -z "${LLM_SLOT_HELD:-}" ]; then
    ok "release frees the slot"
else
    bad "release frees the slot"
fi

# 3. release is idempotent (second call, and call with no held slot, are no-ops).
release_llm_slot
LLM_SLOT_HELD=""
if release_llm_slot; then ok "release is idempotent / no-op when unheld"; else bad "release idempotent"; fi

# 4. all-K-busy (live holders) fails open after the wait budget.
rm -rf "$AGENTIS_LLM_SLOTS_DIR"; mkdir -p "$AGENTIS_LLM_SLOTS_DIR"
mkdir "$AGENTIS_LLM_SLOTS_DIR/slot-1"; printf '%s' "$$" > "$AGENTIS_LLM_SLOTS_DIR/slot-1/pid"  # this shell = alive
_t0=$(date +%s)
LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=2 acquire_llm_slot
_t1=$(date +%s)
if [ -z "${LLM_SLOT_HELD:-}" ] && [ "$((_t1 - _t0))" -ge 2 ]; then
    ok "all-busy (live holder) blocks the wait budget then fails open"
else
    bad "all-busy fails open after wait (held='${LLM_SLOT_HELD:-}', waited=$((_t1 - _t0))s)"
fi
rm -rf "$AGENTIS_LLM_SLOTS_DIR/slot-1"

# 5. a slot held by a DEAD pid is reclaimed.
rm -rf "$AGENTIS_LLM_SLOTS_DIR"; mkdir -p "$AGENTIS_LLM_SLOTS_DIR"
# spawn a child, capture its pid, let it exit -> that pid is now dead.
sleep 0 & _dead=$!; wait "$_dead" 2>/dev/null || true
mkdir "$AGENTIS_LLM_SLOTS_DIR/slot-1"; printf '%s' "$_dead" > "$AGENTIS_LLM_SLOTS_DIR/slot-1/pid"
LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=2 acquire_llm_slot
if [ -n "${LLM_SLOT_HELD:-}" ] && [ "$LLM_SLOT_HELD" = "$AGENTIS_LLM_SLOTS_DIR/slot-1" ]; then
    ok "dead-holder slot is reclaimed and re-acquired"
else
    bad "dead-holder slot reclaimed (held='${LLM_SLOT_HELD:-}')"
fi
release_llm_slot

# 6. K distinct slots can be held at once (two acquires in two subshells against K=2
#    both succeed on distinct dirs). Simulate by claiming slot-1 externally (live),
#    then acquire with K=2 must land on slot-2.
rm -rf "$AGENTIS_LLM_SLOTS_DIR"; mkdir -p "$AGENTIS_LLM_SLOTS_DIR"
mkdir "$AGENTIS_LLM_SLOTS_DIR/slot-1"; printf '%s' "$$" > "$AGENTIS_LLM_SLOTS_DIR/slot-1/pid"
LLM_MAX_CONCURRENT=2 LLM_SLOT_WAIT_S=2 acquire_llm_slot
if [ "${LLM_SLOT_HELD:-}" = "$AGENTIS_LLM_SLOTS_DIR/slot-2" ]; then
    ok "second concurrent acquire lands on a distinct slot (slot-2)"
else
    bad "K distinct slots (held='${LLM_SLOT_HELD:-}', expected slot-2)"
fi
release_llm_slot

# 7. bad LLM_MAX_CONCURRENT falls back to the default (does not crash).
rm -rf "$AGENTIS_LLM_SLOTS_DIR"
LLM_MAX_CONCURRENT=abc acquire_llm_slot
if [ -n "${LLM_SLOT_HELD:-}" ]; then ok "non-numeric LLM_MAX_CONCURRENT falls back to default"; else bad "non-numeric K fallback"; fi
release_llm_slot

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
