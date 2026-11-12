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

# 8. COLONY_DIR derivation (#1426): with the AGENTIS_* override absent (agentis-
#    core force-strips that namespace from daemon children regardless of the
#    exec.env_passthrough allowlist), the slot dir must resolve fed-fixed from
#    COLONY_DIR — <COLONY_DIR>/../.agentis/llm-slots — NOT the PWD fallback.
#    This is the resolution every reasoning/editing child actually uses in
#    production, so it is what makes the pool federation-wide.
FAKE_FED="$TMP/fake-fed"; mkdir -p "$FAKE_FED/implementation"
DERIVED="$(AGENTIS_LLM_SLOTS_DIR='' COLONY_DIR="$FAKE_FED/implementation" _llm_slots_dir)"
if [ "$DERIVED" = "$FAKE_FED/.agentis/llm-slots" ]; then
    ok "COLONY_DIR-derived fed-fixed slot dir (AGENTIS_* stripped by the runtime)"
else
    bad "COLONY_DIR derivation (got '$DERIVED', expected '$FAKE_FED/.agentis/llm-slots')"
fi

# 9. Missing/invalid COLONY_DIR falls through to the next resolution (no crash,
#    no half-derived path).
DERIVED2="$(AGENTIS_LLM_SLOTS_DIR='' COLONY_DIR="$TMP/does-not-exist" AGENTIS_ROOT="$TMP/root" _llm_slots_dir)"
if [ "$DERIVED2" = "$TMP/root/.agentis/llm-slots" ]; then
    ok "nonexistent COLONY_DIR falls through to AGENTIS_ROOT resolution"
else
    bad "COLONY_DIR fall-through (got '$DERIVED2')"
fi

# --- #2362: slot ownership is the exclusive create of slot-N/pid, never mkdir's exit status ---
# uutils mkdir 0.8.0-0.10.0 (the /usr/bin/mkdir of Ubuntu 26.04) exits 0 when a concurrent creator wins the race,
# so two contenders could both "win" one slot. LIAR/mkdir reproduces that deterministically on any host: it runs
# the real mkdir (same arguments, same stderr) and always exits 0.
LIB="$HERE/lib/llm-session-slot.sh"
SLOTS="$AGENTIS_LLM_SLOTS_DIR"
REAL_MKDIR="$(command -v mkdir)"
export SLOT_LIAR="$TMP/liar"
mkdir -p "$SLOT_LIAR"
printf '#!/bin/sh\n"%s" "$@"\nexit 0\n' "$REAL_MKDIR" > "$SLOT_LIAR/mkdir"
chmod +x "$SLOT_LIAR/mkdir"
fresh() { rm -rf "$SLOTS"; mkdir -p "$SLOTS"; }
# child CODE — run CODE in a fresh `sh` process (its own PID) that sources the library under `set -eu`, the caller
# contract; prints CODE's output, then ABORTED if the library (or CODE) made that set -e shell exit non-zero.
child() { sh -c 'set -eu; . "$1"; eval "$2"' sh "$LIB" "$1" 2>/dev/null || printf 'ABORTED'; }
have_reclaim() { command -v _lss_reclaim >/dev/null 2>&1; }
# entries DIR SEP — DIR's entries joined by SEP, for failure messages only (the pool holds plain names).
# shellcheck disable=SC2012
entries() { ls -A "$1" 2>/dev/null | tr '\n' "$2"; }
sleep 0 & _dead2=$!; wait "$_dead2" 2>/dev/null || true

# 10. Lying mkdir, K=1: this shell holds slot-1; a second contender (another process) never gets it, waits its
#     budget (WAIT=1: two scans, >= 1 s) and fails open; the holder's pid stamp is untouched.
fresh
PATH="$SLOT_LIAR:$PATH" LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=1 acquire_llm_slot
_h1="${LLM_SLOT_HELD:-}"
_t0=$(date +%s)
# shellcheck disable=SC2016  # expanded by the child shell
_h2="$(child 'PATH="$SLOT_LIAR:$PATH" LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=1 acquire_llm_slot; printf "%s" "$LLM_SLOT_HELD"')"
_t1=$(date +%s)
if [ "$_h1" = "$SLOTS/slot-1" ] && [ -z "$_h2" ] && [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$$" ] \
   && [ "$((_t1 - _t0))" -ge 1 ]; then
    ok "lying mkdir, K=1: a second contender never shares the held slot (waited $((_t1 - _t0))s, failed open)"
else
    bad "lying mkdir, K=1: first='$_h1' second='$_h2' pid='$(cat "$SLOTS/slot-1/pid" 2>/dev/null)' (want $$) waited=$((_t1 - _t0))s"
fi
release_llm_slot

# 11. Lying mkdir, K=2: the first acquire gets slot-1, the second slot-2, the third (both holders live) fails open.
fresh
PATH="$SLOT_LIAR:$PATH" LLM_MAX_CONCURRENT=2 LLM_SLOT_WAIT_S=1 acquire_llm_slot; _a="${LLM_SLOT_HELD:-}"
PATH="$SLOT_LIAR:$PATH" LLM_MAX_CONCURRENT=2 LLM_SLOT_WAIT_S=1 acquire_llm_slot; _b="${LLM_SLOT_HELD:-}"
PATH="$SLOT_LIAR:$PATH" LLM_MAX_CONCURRENT=2 LLM_SLOT_WAIT_S=1 acquire_llm_slot; _c="${LLM_SLOT_HELD:-}"
if [ "$_a" = "$SLOTS/slot-1" ] && [ "$_b" = "$SLOTS/slot-2" ] && [ -z "$_c" ]; then
    ok "lying mkdir, K=2: slot-1, then slot-2, then fail open"
else
    bad "lying mkdir, K=2: got '$_a' / '$_b' / '$_c'"
fi
LLM_SLOT_HELD=""

# 12. An existing empty slot dir (an old-version crash between mkdir and the stamp) is acquirable, not a leak.
fresh; mkdir "$SLOTS/slot-1"
# shellcheck disable=SC2016
_r="$(child 'LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=1 acquire_llm_slot; printf "%s" "$LLM_SLOT_HELD"')"
if [ "$_r" = "$SLOTS/slot-1" ]; then
    ok "an empty slot dir with no pid is acquired"
else
    bad "empty slot dir with no pid: got '$_r'"
fi

# 13. An existing EMPTY pid (a holder between its create and its stamp) is never reclaimed: fail open, file kept.
fresh; mkdir "$SLOTS/slot-1"; : > "$SLOTS/slot-1/pid"
# shellcheck disable=SC2016
_r="$(child 'LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=1 acquire_llm_slot; printf "%s" "$LLM_SLOT_HELD"')"
if [ -z "$_r" ] && [ -f "$SLOTS/slot-1/pid" ] && [ ! -s "$SLOTS/slot-1/pid" ]; then
    ok "an empty pid stamp is never reclaimed (fail open, file kept)"
else
    bad "empty pid stamp: got '$_r', pid file $( [ -f "$SLOTS/slot-1/pid" ] && echo kept || echo removed)"
fi

# 14. A reclaimer that read a holder which has since exited, while the slot was re-taken by a live holder, never
#     removes the new holder's stamp.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$$" > "$SLOTS/slot-1/pid"
if have_reclaim; then
    _lss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$$" ] && [ "$(ls -A "$SLOTS/slot-1")" = pid ]; then
        ok "reclaim of a stale (dead) holder never removes a newer live holder's stamp"
    else
        bad "stale reclaim touched the new holder: pid='$(cat "$SLOTS/slot-1/pid" 2>/dev/null)' entries=[$(entries "$SLOTS/slot-1" ' ')]"
    fi
else
    bad "stale reclaim: _lss_reclaim is not defined"
fi

# 15. Two reclaimers for one dead holder: only the owner of reap.<pid> acts; a second one changes nothing.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/reap.$_dead2"
if have_reclaim; then
    _lss_reclaim "$SLOTS/slot-1" "$_dead2"
    if [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_dead2" ] && [ -f "$SLOTS/slot-1/reap.$_dead2" ]; then
        ok "a reclaim whose reap token is already owned changes nothing"
    else
        bad "second reclaimer acted: entries=[$(entries "$SLOTS/slot-1" ' ')]"
    fi
else
    bad "concurrent reclaim: _lss_reclaim is not defined"
fi

# 16. A dead holder is reclaimed through the acquire path, and no reap token is left behind.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=2 acquire_llm_slot
if [ "${LLM_SLOT_HELD:-}" = "$SLOTS/slot-1" ] && [ "$(ls -A "$SLOTS/slot-1")" = pid ] \
   && [ "$(cat "$SLOTS/slot-1/pid")" = "$$" ]; then
    ok "dead-holder slot is reclaimed and re-acquired with no reap token left"
else
    bad "dead-holder reclaim: held='${LLM_SLOT_HELD:-}' entries=[$(entries "$SLOTS/slot-1" ' ')]"
fi
release_llm_slot

# 17. Garbage holder content is a dead holder: reclaimed, and nothing is created outside the pool. The fullwidth
#     digits are literal UTF-8 glyphs (dash-safe: no \xHH escapes); 99999999999 is past any real PID (bash in POSIX
#     mode returns 0 for `kill -0` on it, as for `kill -0 abc`).
_t17_fail=""
_tmp_before="$(ls -A "$TMP")"
for _g in abc 0 007 ../x '１２３' 99999999999; do
    fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_g" > "$SLOTS/slot-1/pid"
    # shellcheck disable=SC2016
    _r="$(child 'LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=2 acquire_llm_slot; printf "%s" "$LLM_SLOT_HELD"')"
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

# 17b. ... and a garbage holder is reclaimed through the single reap.invalid token: while that token is owned, a
#      garbage holder is left alone (so no garbage ever becomes part of a path).
_t17b_fail=""
if have_reclaim; then
    for _g in abc 0 007 ../x '１２３' -1 99999999999; do
        fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_g" > "$SLOTS/slot-1/pid"; : > "$SLOTS/slot-1/reap.invalid"
        _lss_reclaim "$SLOTS/slot-1" "$_g"
        [ "$(cat "$SLOTS/slot-1/pid" 2>/dev/null)" = "$_g" ] || _t17b_fail="$_t17b_fail [$_g]"
    done
else
    _t17b_fail=" _lss_reclaim is not defined"
fi
if [ -z "$_t17b_fail" ]; then
    ok "every garbage holder maps to reap.invalid (owned token -> left alone)"
else
    bad "garbage holder bypassed reap.invalid:$_t17b_fail"
fi

# 18. TERM during a reclaim: the trap's release removes the reap token this shell owns (named in _LSS_REAP and
#     stamped with this shell's pid) and clears the variable.
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$$" > "$SLOTS/slot-1/reap.$_dead2"
_LSS_REAP="$SLOTS/slot-1/reap.$_dead2"; LLM_SLOT_HELD=""
release_llm_slot
if [ ! -e "$SLOTS/slot-1/reap.$_dead2" ] && [ -z "${_LSS_REAP:-}" ]; then
    ok "release removes the reap token this shell owns and clears _LSS_REAP"
else
    bad "release left the reap token (exists=$( [ -e "$SLOTS/slot-1/reap.$_dead2" ] && echo yes || echo no), _LSS_REAP='${_LSS_REAP:-}')"
fi

# 18b. A TERM that lands after _LSS_REAP is named but before this shell created the token never removes another
#      reclaimer's token (stamped with that reclaimer's pid).
fresh; mkdir "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/reap.$_dead2"
_LSS_REAP="$SLOTS/slot-1/reap.$_dead2"; LLM_SLOT_HELD=""
release_llm_slot
if [ -e "$SLOTS/slot-1/reap.$_dead2" ] && [ -z "${_LSS_REAP:-}" ]; then
    ok "release never removes a reap token another reclaimer owns"
else
    bad "release removed a foreign reap token or kept _LSS_REAP='${_LSS_REAP:-}'"
fi
_LSS_REAP=""

# 19. A pool path containing a space: acquire, release and dead-holder reclaim all work.
SLOTS_SAVE="$SLOTS"
export AGENTIS_LLM_SLOTS_DIR="$TMP/pool dir/slots"
SLOTS="$AGENTIS_LLM_SLOTS_DIR"
LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=1 acquire_llm_slot; _s1="${LLM_SLOT_HELD:-}"
release_llm_slot
mkdir -p "$SLOTS/slot-1"; printf '%s' "$_dead2" > "$SLOTS/slot-1/pid"
LLM_MAX_CONCURRENT=1 LLM_SLOT_WAIT_S=2 acquire_llm_slot; _s2="${LLM_SLOT_HELD:-}"
release_llm_slot
if [ "$_s1" = "$SLOTS/slot-1" ] && [ "$_s2" = "$SLOTS/slot-1" ] && [ ! -e "$SLOTS/slot-1" ]; then
    ok "a pool path with a space: acquire, release and dead-holder reclaim work"
else
    bad "pool path with a space: first='$_s1' reclaimed='$_s2'"
fi
export AGENTIS_LLM_SLOTS_DIR="$SLOTS_SAVE"
SLOTS="$SLOTS_SAVE"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
