# shellcheck shell=sh
# dark-factory/lib/forge-slot.sh — host-wide concurrency cap for `forge` invariant
# subprocesses spawned by the batch/deep-hunt loop (#2038).
#
# WHY: `run-invariant-hunt.sh` (and, transitively, `run-zone-hunt.sh --deep-hunt`,
# which subprocesses it) can spawn many `forge` invariant runs back to back — each
# a full `forge build` + hundreds of fuzzed call sequences. Under concurrent
# multi-hunt load these pile up on one host and starve each other (the #2033
# TRANSIENT_ERROR symptom: a valid harness gets OOM-killed / timed out purely from
# resource contention, not a real bug in the harness). This is the missing local
# cap: at most FORGE_MAX_SLOTS `forge` invariant subprocesses run at once, no
# matter how many hunts/candidates are in flight.
#
# MECHANISM: a counting semaphore over K slot directories, structured identically
# to tools/lib/llm-session-slot.sh (#1352). A slot is owned by whoever wins the
# shell's own exclusive create of slot-N/pid (`set -C` noclobber: bash and dash
# open the target O_CREAT|O_EXCL), which also stamps the holder PID. `mkdir` only
# creates the container directory; its exit status is NOT an ownership test
# (#2362): uutils mkdir 0.8.0-0.10.0, /usr/bin/mkdir on Ubuntu 26.04, exits 0
# when a concurrent creator wins the race. The primitive stays inside the shell,
# deliberately NOT flock(1), which stock macOS does not ship (dark-factory already
# cares about macOS portability: install.sh, run-audit.sh, run-zone-sweep.sh).
# A slot whose holder is dead (kill -0 fails, or the stamp is not a PID) is
# reclaimed, so a crashed run never leaks a slot forever; the reclaim is
# serialized by an exclusive per-holder reap token (see _fss_reclaim).
# All-slots-busy blocks with a bounded poll, then FAILS OPEN (proceeds without a
# slot) so a forge run is only ever delayed, never dropped — backpressure, not a
# new failure mode.
#
# TRUST BOUNDARY: the pool dir must be owned by the user running the hunts.
# noclobber only refuses an existing REGULAR file, so a `pid` replaced by a
# symlink to a device or by a FIFO is outside what this lock defends against.
#
# USAGE (source, then bracket the forge subprocess call):
#   . "<dir>/lib/forge-slot.sh"
#   acquire_forge_slot            # sets FORGE_SLOT_HELD to the held slot dir (or "")
#   ... run forge (directly or via forge-invariant.sh / invariant-prover.ag) ...
#   release_forge_slot            # idempotent; also safe to call from a cleanup trap
#
# CONFIG (env):
#   FORGE_MAX_SLOTS    max concurrent forge invariant subprocesses (default 2 —
#                      a full forge build + fuzz is a heavy, long-lived local
#                      process, closer in weight to the #1367
#                      CODE_EDIT_MAX_CONCURRENT=2 "heavy local process" cap than
#                      to LLM_MAX_CONCURRENT=3)
#   FORGE_SLOT_WAIT_S  max seconds to wait for a free slot before failing open
#                      (default 300)
#   FORGE_SLOTS_DIR    slot dir override, mainly for test isolation (mirrors
#                      AGENTIS_LLM_SLOTS_DIR)
#   DARK_FACTORY_DIR   dark-factory's existing host-wide state-dir convention
#                      (also used by bounty-payability-gate.sh /
#                      deliver-submission.sh / contest-watch.sh); the slot pool
#                      lives at <DARK_FACTORY_DIR>/forge-slots so it is shared
#                      host-wide across concurrent hunts, not per-run

# Resolve the slots directory once. Precedence: explicit override (test
# isolation), the DARK_FACTORY_DIR-derived host-wide path, then a cwd-local
# fallback (never fatal).
_forge_slots_dir() {
    if [ -n "${FORGE_SLOTS_DIR:-}" ]; then
        printf '%s' "$FORGE_SLOTS_DIR"
    elif [ -n "${DARK_FACTORY_DIR:-}" ]; then
        printf '%s' "$DARK_FACTORY_DIR/forge-slots"
    else
        printf '%s' "${HOME:-.}/.dark-factory/forge-slots"
    fi
}

# acquire_forge_slot: claim one of K slots. Sets FORGE_SLOT_HELD to the claimed
# slot directory on success, or "" when it fails open after the wait budget.
# Always returns 0 (fail-open) — callers never branch on it; a delayed forge
# run is fine, a dropped one is not.
acquire_forge_slot() {
    FORGE_SLOT_HELD=""
    _fss_k="${FORGE_MAX_SLOTS:-2}"
    case "$_fss_k" in ''|*[!0-9]*) _fss_k=2 ;; esac
    [ "$_fss_k" -ge 1 ] 2>/dev/null || _fss_k=2
    _fss_wait="${FORGE_SLOT_WAIT_S:-300}"
    case "$_fss_wait" in ''|*[!0-9]*) _fss_wait=300 ;; esac
    _fss_dir="$(_forge_slots_dir)"
    mkdir -p "$_fss_dir" 2>/dev/null || { FORGE_SLOT_HELD=""; return 0; }

    _fss_waited=0
    while :; do
        _fss_i=1
        while [ "$_fss_i" -le "$_fss_k" ]; do
            _fss_slot="$_fss_dir/slot-$_fss_i"
            # Container only: its exit status is ignored on purpose (#2362,
            # see MECHANISM) — the exclusive create below decides ownership.
            mkdir "$_fss_slot" 2>/dev/null || :
            if ( set -C; printf '%s' "$$" > "$_fss_slot/pid" ) 2>/dev/null; then
                # Won the slot; the PID stamp lets a future acquirer reclaim
                # it if we die without releasing.
                FORGE_SLOT_HELD="$_fss_slot"
                return 0
            fi
            # Occupied — reclaim if the holder PID is dead (crash-safety). An
            # empty stamp is a holder between its create and its write: never
            # reclaimed.
            _fss_holder="$(cat "$_fss_slot/pid" 2>/dev/null)" || _fss_holder=""
            if [ -n "$_fss_holder" ]; then
                _fss_reclaim "$_fss_slot" "$_fss_holder"
                # do NOT claim here; loop retries the create cleanly next pass
            fi
            _fss_i=$((_fss_i + 1))
        done
        # All K slots held by live holders. Wait, then fail open.
        if [ "$_fss_waited" -ge "$_fss_wait" ]; then
            FORGE_SLOT_HELD=""
            return 0
        fi
        sleep 1
        _fss_waited=$((_fss_waited + 1))
    done
}

# _fss_reclaim SLOT HOLDER: free SLOT when its stamped HOLDER is dead. Same
# protocol as _lss_reclaim in tools/lib/llm-session-slot.sh; the order of the
# steps is load-bearing:
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
# _FSS_REAP names the token while this shell may own it, stamped with our PID,
# so a TERM trap's release_forge_slot removes it and never another reclaimer's.
# Always returns 0: callers run under `set -e`.
_fss_reclaim() {
    [ -n "$2" ] || return 0
    case "$2" in
        *[!0123456789]* | 0* | ??????????*) _fss_tag=invalid ;;
        *) _fss_tag="$2" ;;
    esac
    if [ "$_fss_tag" != invalid ] && kill -0 "$2" 2>/dev/null; then
        return 0
    fi
    _FSS_REAP="$1/reap.$_fss_tag"
    if ! ( set -C; printf '%s' "$$" > "$_FSS_REAP" ) 2>/dev/null; then
        _FSS_REAP=""
        return 0
    fi
    _fss_now="$(cat "$1/pid" 2>/dev/null)" || _fss_now=""
    if [ "$_fss_now" = "$2" ]; then
        rm -f "$1/pid" 2>/dev/null || :
    fi
    rm -f "$_FSS_REAP" 2>/dev/null || :
    _FSS_REAP=""
    return 0
}

# release_forge_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap, so it also drops a reap token this shell owns when the trap
# fires mid-reclaim (_fss_reclaim).
release_forge_slot() {
    if [ -n "${_FSS_REAP:-}" ]; then
        if [ "$(cat "$_FSS_REAP" 2>/dev/null)" = "$$" ]; then
            rm -f "$_FSS_REAP" 2>/dev/null || :
        fi
        _FSS_REAP=""
    fi
    if [ -n "${FORGE_SLOT_HELD:-}" ]; then
        rm -f "$FORGE_SLOT_HELD/pid" 2>/dev/null || :
        # Best effort: a slot dir that still holds another reclaimer's token
        # stays, which is harmless (the next acquirer reuses it).
        rmdir "$FORGE_SLOT_HELD" 2>/dev/null || :
        FORGE_SLOT_HELD=""
    fi
}
