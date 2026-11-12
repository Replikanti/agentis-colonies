# shellcheck shell=sh
# tools/lib/llm-session-slot.sh — federation-wide concurrency cap for LLM
# (flat-cyborg / Claude Code PTY) sessions (#1352).
#
# WHY: running many agents at the autonomous tier makes every agent call
# prompt() each tick, each spawning a flat-cyborg -> Claude-Code PTY session.
# On a single host these thrash and wedge (agents pile up watchdog restarts,
# some hang on a stuck flat-cyborg). Lowering confidence does NOT help — a
# dormant agent still prompt()s each tick. The #1368 edit-job semaphore only
# caps code-edit ORCHESTRATORS, not the per-tick reasoning sessions. This is
# the missing global cap: at most LLM_MAX_CONCURRENT flat-cyborg sessions run
# at once across the whole federation, independent of the agent/tier count.
#
# MECHANISM: a counting semaphore over K slot directories. A slot is owned by
# whoever wins the shell's own exclusive create of slot-N/pid (`set -C`
# noclobber: bash and dash open the target O_CREAT|O_EXCL), which also stamps
# the holder PID. `mkdir` only creates the container directory; its exit status
# is NOT an ownership test (#2362): uutils mkdir 0.8.0-0.10.0, /usr/bin/mkdir on
# Ubuntu 26.04, exits 0 when a concurrent creator wins the race, so two
# contenders could both "win" one slot. The primitive stays inside the shell —
# deliberately NOT flock(1), which stock macOS does not ship (same reason
# auto-promote uses a Python fcntl helper). A slot whose holder is dead (kill -0
# fails, or the stamp is not a PID) is reclaimed, so a crashed session never
# leaks a slot forever (mirrors the daemon-registry PID-liveness idiom); the
# reclaim itself is serialized by an exclusive per-holder reap token (see
# _lss_reclaim). All-slots-busy blocks with a bounded poll, then FAILS OPEN
# (proceeds without a slot) so a prompt is only ever delayed, never dropped —
# backpressure, not a new failure mode.
#
# TRUST BOUNDARY: the pool dir must be owned by the user running the sessions.
# noclobber only refuses an existing REGULAR file, so a `pid` replaced by a
# symlink to a device or by a FIFO is outside what this lock defends against.
#
# USAGE (source, then bracket the flat-cyborg spawn):
#   . "<dir>/lib/llm-session-slot.sh"
#   acquire_llm_slot            # sets LLM_SLOT_HELD to the held slot dir (or "")
#   ... spawn flat-cyborg ...
#   release_llm_slot            # idempotent; also safe to call from a cleanup trap
#
# CONFIG (env):
#   LLM_MAX_CONCURRENT     max concurrent sessions (default 3; tune per host)
#   AGENTIS_LLM_SLOTS_DIR  slot dir override — honoured on DIRECT invocations
#                          only: agentis-core force-strips the entire AGENTIS_*
#                          namespace from daemon children REGARDLESS of the
#                          exec.env_passthrough allowlist (proven on v1.20.0 in
#                          the #1426 QA), so this var never crosses the exec
#                          boundary into reasoning/editing children
#   COLONY_DIR             the allowlisted, non-reserved var every daemon child
#                          DOES receive; the fed-fixed slot dir is derived from
#                          it (<COLONY_DIR>/../.agentis/llm-slots) — this is
#                          what makes the pool federation-wide in production
#   LLM_SLOT_WAIT_S        max seconds to wait for a free slot before failing
#                          open (default 120)

# Resolve the slots directory once. Precedence: explicit override (direct
# invocations only — see above), the COLONY_DIR-derived fed-fixed path (the
# production path: COLONY_DIR survives the exec boundary via the allowlist and
# is exported by every start-colony.sh, so reasoning + editing children all
# resolve the SAME pool), the agentis root, then a cwd-local fallback (never
# fatal).
_llm_slots_dir() {
    if [ -n "${AGENTIS_LLM_SLOTS_DIR:-}" ]; then
        printf '%s' "$AGENTIS_LLM_SLOTS_DIR"
    elif [ -d "${COLONY_DIR:-/nonexistent}" ]; then
        printf '%s' "$(cd "$COLONY_DIR/.." && pwd)/.agentis/llm-slots"
    elif [ -n "${AGENTIS_ROOT:-}" ]; then
        printf '%s' "$AGENTIS_ROOT/.agentis/llm-slots"
    else
        printf '%s' "${PWD:-.}/.agentis/llm-slots"
    fi
}

# acquire_llm_slot: claim one of K slots. Sets LLM_SLOT_HELD to the claimed
# slot directory on success, or "" when it fails open after the wait budget.
# Always returns 0 (fail-open) — callers never branch on it; a delayed prompt
# is fine, a dropped prompt is not.
acquire_llm_slot() {
    LLM_SLOT_HELD=""
    _lss_k="${LLM_MAX_CONCURRENT:-3}"
    case "$_lss_k" in ''|*[!0-9]*) _lss_k=3 ;; esac
    [ "$_lss_k" -ge 1 ] 2>/dev/null || _lss_k=3
    _lss_wait="${LLM_SLOT_WAIT_S:-120}"
    case "$_lss_wait" in ''|*[!0-9]*) _lss_wait=120 ;; esac
    _lss_dir="$(_llm_slots_dir)"
    mkdir -p "$_lss_dir" 2>/dev/null || { LLM_SLOT_HELD=""; return 0; }

    _lss_waited=0
    while :; do
        _lss_i=1
        while [ "$_lss_i" -le "$_lss_k" ]; do
            _lss_slot="$_lss_dir/slot-$_lss_i"
            # Container only: its exit status is ignored on purpose (#2362,
            # see MECHANISM) — the exclusive create below decides ownership.
            mkdir "$_lss_slot" 2>/dev/null || :
            if ( set -C; printf '%s' "$$" > "$_lss_slot/pid" ) 2>/dev/null; then
                # Won the slot; the PID stamp lets a future acquirer reclaim
                # it if we die without releasing.
                LLM_SLOT_HELD="$_lss_slot"
                return 0
            fi
            # Occupied — reclaim if the holder PID is dead (crash-safety). An
            # empty stamp is a holder between its create and its write: never
            # reclaimed.
            _lss_holder="$(cat "$_lss_slot/pid" 2>/dev/null)" || _lss_holder=""
            if [ -n "$_lss_holder" ]; then
                _lss_reclaim "$_lss_slot" "$_lss_holder"
                # do NOT claim here; loop retries the create cleanly next pass
            fi
            _lss_i=$((_lss_i + 1))
        done
        # All K slots held by live holders. Wait, then fail open.
        if [ "$_lss_waited" -ge "$_lss_wait" ]; then
            LLM_SLOT_HELD=""
            return 0
        fi
        sleep 1
        _lss_waited=$((_lss_waited + 1))
    done
}

# _lss_reclaim SLOT HOLDER: free SLOT when its stamped HOLDER is dead. The
# order of the steps is load-bearing:
#   1. Liveness first. A live holder is left alone; a dead PID stays dead.
#   2. Win the exclusive reap token SLOT/reap.TAG, or leave: another reclaimer
#      of the same holder owns the reap.
#   3. Re-read the stamp and remove it only if it is still HOLDER. Only the
#      token owner may remove it, and no acquirer can replace an existing file,
#      so a reclaimer that read a holder which has since released (and whose
#      slot a new holder took) never removes the new holder's stamp.
#   4. Drop the token.
# TAG is HOLDER only when it is a positive decimal with no leading zero and at
# most 9 digits (Linux caps PIDs at 2^22, macOS at 99999); any other content is
# a dead holder reaped through the one token reap.invalid, so garbage never
# becomes part of a path and never reaches `kill -0` (`0` and `-1` signal
# process groups; bash in POSIX mode returns 0 for `kill -0 abc` and for a PID
# past 2^31).
# _LSS_REAP names the token while this shell may own it, stamped with our PID,
# so a TERM trap's release_llm_slot removes it and never another reclaimer's.
# Always returns 0: callers run under `set -e`.
_lss_reclaim() {
    [ -n "$2" ] || return 0
    case "$2" in
        *[!0123456789]* | 0* | ??????????*) _lss_tag=invalid ;;
        *) _lss_tag="$2" ;;
    esac
    if [ "$_lss_tag" != invalid ] && kill -0 "$2" 2>/dev/null; then
        return 0
    fi
    _LSS_REAP="$1/reap.$_lss_tag"
    if ! ( set -C; printf '%s' "$$" > "$_LSS_REAP" ) 2>/dev/null; then
        _LSS_REAP=""
        return 0
    fi
    _lss_now="$(cat "$1/pid" 2>/dev/null)" || _lss_now=""
    if [ "$_lss_now" = "$2" ]; then
        rm -f "$1/pid" 2>/dev/null || :
    fi
    rm -f "$_LSS_REAP" 2>/dev/null || :
    _LSS_REAP=""
    return 0
}

# release_llm_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap, so it also drops a reap token this shell owns when the trap
# fires mid-reclaim (_lss_reclaim).
release_llm_slot() {
    if [ -n "${_LSS_REAP:-}" ]; then
        if [ "$(cat "$_LSS_REAP" 2>/dev/null)" = "$$" ]; then
            rm -f "$_LSS_REAP" 2>/dev/null || :
        fi
        _LSS_REAP=""
    fi
    if [ -n "${LLM_SLOT_HELD:-}" ]; then
        rm -f "$LLM_SLOT_HELD/pid" 2>/dev/null || :
        # Best effort: a slot dir that still holds another reclaimer's token
        # stays, which is harmless (the next acquirer reuses it).
        rmdir "$LLM_SLOT_HELD" 2>/dev/null || :
        LLM_SLOT_HELD=""
    fi
}
