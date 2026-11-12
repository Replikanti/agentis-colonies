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
# auto-promote uses a Python fcntl helper). Every exclusive step (the stamp, a
# reap token) is that one shell create (_lss_create); no external binary's exit
# status decides ownership. A slot whose holder is dead (kill -0 fails, or the
# stamp is not a PID) is reclaimed, and so is a stamp left EMPTY for 10 s (its
# creator died between create and write), so a crashed session never leaks a
# slot forever (mirrors the daemon-registry PID-liveness idiom). The reclaim is
# serialized by generation-numbered reap tokens, so a reclaimer killed mid-reclaim
# is taken over too (see _lss_reclaim). A stamp whose write fails is removed by
# its own creator. All-slots-busy blocks with a bounded poll, then FAILS OPEN
# (proceeds without a slot) so a prompt is only ever delayed, never dropped —
# backpressure, not a new failure mode.
#
# DEPLOY: restart every federation that uses a pool after updating this file.
# A pre-#2362 acquirer still running writes its stamp without noclobber and can
# overwrite a new holder's stamp, and it treats a slot dir without a stamp as
# busy; neither happens once every process runs this version.
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
    _lss_seen=""
    while :; do
        _lss_seen_next=""
        _lss_i=1
        while [ "$_lss_i" -le "$_lss_k" ]; do
            _lss_slot="$_lss_dir/slot-$_lss_i"
            # Container only: its exit status is ignored on purpose (#2362,
            # see MECHANISM) — the exclusive create below decides ownership.
            mkdir "$_lss_slot" 2>/dev/null || :
            _lss_create "$_lss_slot/pid"
            if [ "$_lss_rc" = won ]; then
                # Won the slot; the PID stamp lets a future acquirer reclaim
                # it if we die without releasing. Reap tokens left in it by
                # killed reclaimers are garbage now: the stamp names us, so no
                # reclaim of an earlier holder can act any more.
                LLM_SLOT_HELD="$_lss_slot"
                _lss_sweep "$_lss_slot" ""
                return 0
            fi
            if [ "$_lss_rc" = wfail ]; then
                # We created the stamp but the pool filesystem refused the
                # write (ENOSPC, EDQUOT): hand the slot back and fail open now.
                # A gate that cannot write a PID cannot hold, and leaving the
                # empty stamp would cost every later acquirer the staleness
                # wait below.
                rm -f "$_lss_slot/pid" 2>/dev/null || :
                return 0
            fi
            # Occupied — reclaim if the holder is dead (crash-safety). An
            # empty stamp is a holder between its create and its write, so it
            # is reclaimed only once it stayed empty for 10 s (_lss_aged).
            _lss_holder="$(cat "$_lss_slot/pid" 2>/dev/null)" || _lss_holder=""
            if [ -n "$_lss_holder" ]; then
                _lss_reclaim "$_lss_slot" "$_lss_holder" "$_lss_i"
            elif [ -f "$_lss_slot/pid" ] && _lss_aged "s$_lss_i"; then
                _lss_reclaim "$_lss_slot" "" "$_lss_i"
            fi
            _lss_i=$((_lss_i + 1))
        done
        _lss_seen="$_lss_seen_next"
        # All K slots held by live holders. Wait, then fail open.
        if [ "$_lss_waited" -ge "$_lss_wait" ]; then
            LLM_SLOT_HELD=""
            return 0
        fi
        sleep 1
        _lss_waited=$((_lss_waited + 1))
    done
}

# _lss_create FILE: the one exclusivity primitive. Creates FILE only if it does
# not exist yet (`set -C`: O_CREAT|O_EXCL in bash and dash) and writes our PID
# through that same descriptor, so the stamp lands in the inode we created.
# Sets _lss_rc to won (created and stamped), wfail (created, but the write
# failed: the caller owns an empty FILE and removes it) or lost (FILE existed).
# A failed redirection exits 1 (bash) or 2 (dash), never 3.
_lss_create() {
    if ( set -C; { printf '%s' "$$" >&3 || exit 3; } 3> "$1" ) 2>/dev/null; then
        _lss_rc=won
    else
        case $? in
            3) _lss_rc=wfail ;;
            *) _lss_rc=lost ;;
        esac
    fi
}

# _lss_aged KEY: KEY names a file seen EMPTY in this pass (s<i>: slot i's
# stamp, t<i>.<g>: its reap token of generation g). Remembers the pass it was
# first seen empty, carried over only while it is seen empty in every pass, and
# succeeds once that is at least 10 passes ago (>= 10 s, each pass ends in
# `sleep 1`). Why 10 s: a live creator's file is empty only between its
# open(O_EXCL) and its write of at most 10 bytes, inside one subshell with no
# fork or exec in between, so only a stalled CPU can stretch that window: CFS
# bandwidth throttling freezes a group for at most the rest of a 100 ms period,
# so 10 s is 100 periods. A shorter bound risks reclaiming a stalled live
# creator; a longer one only delays healing a leaked slot, and the bound must
# stay well below LLM_SLOT_WAIT_S (120 s) for a waiter to reach it.
_lss_aged() {
    _lss_t0="${_lss_waited:-0}"
    case " ${_lss_seen:-} " in
        *" $1="*) _lss_t0="${_lss_seen#*" $1="}"; _lss_t0="${_lss_t0%% *}" ;;
    esac
    _lss_seen_next="${_lss_seen_next:-} $1=$_lss_t0"
    [ "$(( ${_lss_waited:-0} - _lss_t0 ))" -ge 10 ]
}

# _lss_sweep SLOT PREFIX: remove SLOT's reap tokens named reap.PREFIX*. Only
# called once SLOT's stamp no longer names the holder those tokens are for, so
# any reclaim they could still serialize is a no-op.
_lss_sweep() {
    for _lss_tok in "$1"/reap."$2"*; do
        if [ -e "$_lss_tok" ]; then
            rm -f "$_lss_tok" 2>/dev/null || :
        fi
    done
    return 0
}

# _lss_reclaim SLOT HOLDER [I]: free SLOT when its stamped HOLDER is dead
# (I is the slot index, for _lss_aged). The order of the steps is load-bearing:
#   1. Liveness first. A live holder is left alone; a dead PID stays dead.
#   2. Win a reap token: the lowest generation g of SLOT/reap.TAG.g that we
#      create exclusively, where every lower generation exists and belongs to a
#      dead owner (or stayed empty for 10 s). Two reclaimers never both pass:
#      for the same g only one create succeeds, and a reclaimer only climbs
#      past g after seeing g's owner dead, so it can never pass a live one.
#      This also takes over a token whose owner was killed mid-reclaim. Tokens
#      of TAG are never removed while the stamp still names HOLDER, so the set
#      a climber walks only grows. 16 generations means 16 reclaimers of one
#      slot killed back to back; past that we give up and the wait fails open.
#   3. Re-read the stamp and remove it only if it is still HOLDER. Only the
#      token owner may remove it, and no acquirer can replace an existing file,
#      so a reclaimer that read a holder which has since released (and whose
#      slot a new holder took) never removes the new holder's stamp.
#   4. The stamp no longer names HOLDER: sweep every token of TAG.
# TAG is HOLDER only when it is a positive decimal with no leading zero and at
# most 9 digits (Linux caps PIDs at 2^22, macOS at 99999); an empty HOLDER is
# reaped as TAG `empty`, any other content as `invalid`, so garbage never
# becomes part of a path and never reaches `kill -0` (`0` and `-1` signal
# process groups; bash in POSIX mode returns 0 for `kill -0 abc` and for a PID
# past 2^31).
# _LSS_REAP names the token while this shell may own it; tokens hold their
# owner's PID, so a TERM trap's release_llm_slot removes ours and never
# another reclaimer's. Always returns 0: callers run under `set -e`.
_lss_reclaim() {
    case "$2" in
        '') _lss_tag=empty ;;
        *[!0123456789]* | 0* | ??????????*) _lss_tag=invalid ;;
        *) _lss_tag="$2" ;;
    esac
    if [ "$_lss_tag" = "$2" ] && kill -0 "$2" 2>/dev/null; then
        return 0
    fi
    _lss_g=1
    while :; do
        if [ "$_lss_g" -gt 16 ]; then
            return 0
        fi
        _LSS_REAP="$1/reap.$_lss_tag.$_lss_g"
        _lss_create "$_LSS_REAP"
        if [ "$_lss_rc" = won ]; then
            break
        fi
        if [ "$_lss_rc" = wfail ]; then
            rm -f "$_LSS_REAP" 2>/dev/null || :
            _LSS_REAP=""
            return 0
        fi
        _LSS_REAP=""
        _lss_owner="$(cat "$1/reap.$_lss_tag.$_lss_g" 2>/dev/null)" || _lss_owner=""
        case "$_lss_owner" in
            '')
                if [ -f "$1/reap.$_lss_tag.$_lss_g" ] && _lss_aged "t${3:-0}.$_lss_g"; then
                    :
                else
                    return 0
                fi
                ;;
            *[!0123456789]* | 0* | ??????????*) ;;
            *)
                if kill -0 "$_lss_owner" 2>/dev/null; then
                    return 0
                fi
                ;;
        esac
        _lss_g=$((_lss_g + 1))
    done
    _lss_now="$(cat "$1/pid" 2>/dev/null)" || _lss_now=""
    if [ "$_lss_now" = "$2" ]; then
        rm -f "$1/pid" 2>/dev/null || :
    fi
    _lss_sweep "$1" "$_lss_tag."
    _LSS_REAP=""
    return 0
}

# release_llm_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap, so it also drops a reap token this shell owns when the trap
# fires mid-reclaim (_lss_reclaim). It removes the stamp only while the stamp
# still names us, so it can never free a slot someone else holds.
release_llm_slot() {
    if [ -n "${_LSS_REAP:-}" ]; then
        if [ "$(cat "$_LSS_REAP" 2>/dev/null)" = "$$" ]; then
            rm -f "$_LSS_REAP" 2>/dev/null || :
        fi
        _LSS_REAP=""
    fi
    if [ -n "${LLM_SLOT_HELD:-}" ]; then
        if [ "$(cat "$LLM_SLOT_HELD/pid" 2>/dev/null)" = "$$" ]; then
            rm -f "$LLM_SLOT_HELD/pid" 2>/dev/null || :
        fi
        # Best effort: a slot dir that still holds a reap token stays, which
        # is harmless (the next acquirer reuses it).
        rmdir "$LLM_SLOT_HELD" 2>/dev/null || :
        LLM_SLOT_HELD=""
    fi
}
