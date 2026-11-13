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
# Every exclusive step (the stamp, a reap token) is that one shell create
# (_fss_create); no external binary's exit status decides ownership. A slot
# whose holder is dead (kill -0 fails, or the stamp is not a PID) is reclaimed,
# and so is an EMPTY stamp that no live process claims (its creator died
# between create and write; see _fss_create), so a crashed run never leaks a
# slot forever. The reclaim is serialized
# by generation-numbered reap tokens, so a reclaimer killed mid-reclaim is taken
# over too (see _fss_reclaim). A stamp whose write fails is removed by its own
# creator. All-slots-busy blocks with a bounded poll, then FAILS OPEN (proceeds
# without a slot) so a forge run is only ever delayed, never dropped —
# backpressure, not a new failure mode. The functions below are the same code as
# tools/lib/llm-session-slot.sh under other names (colony-lint compares them).
#
# DEPLOY: restart every running hunt after updating this file. A pre-#2362
# acquirer still running writes its stamp without noclobber and can overwrite a
# new holder's stamp, and it treats a slot dir without a stamp (every free slot,
# since release keeps the dir) as busy; neither happens once every process runs
# this version.
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
        _fss_refused=0
        while [ "$_fss_i" -le "$_fss_k" ]; do
            _fss_slot="$_fss_dir/slot-$_fss_i"
            # Container only: its exit status is ignored on purpose (#2362,
            # see MECHANISM) — the exclusive create below decides ownership.
            mkdir "$_fss_slot" 2>/dev/null || :
            _fss_create "$_fss_slot/pid"
            if [ "$_fss_rc" = won ]; then
                # Won the slot; the PID stamp lets a future acquirer reclaim
                # it if we die without releasing. Reap tokens and claims left
                # in it by killed processes are garbage now: the stamp names
                # us, so no reclaim of an earlier holder can act any more.
                FORGE_SLOT_HELD="$_fss_slot"
                _fss_sweep "$_fss_slot" ""
                _fss_sweep_claims "$_fss_slot/pid"
                return 0
            fi
            if [ "$_fss_rc" != lost ]; then
                # This slot refused our claim or our stamp write (a full or
                # read-only filesystem, or a slot entry we cannot write: a dir
                # of another user, a stray file); _fss_create already undid
                # both. Try the next slot: one bad entry must not disable the
                # cap. Only a pass in which every slot refused fails open.
                _fss_refused=$((_fss_refused + 1))
            else
                # Occupied — reclaim if the holder is dead (crash-safety). An
                # empty stamp (the builtin size test, never a read that came
                # back empty) is dead only when no live process claims it
                # (its creator died between create and write). A stamp that
                # is not empty but reads as nothing is unreadable: its holder
                # counts as live.
                _fss_read "$_fss_slot/pid"
                if [ -n "$_fss_val" ]; then
                    _fss_reclaim "$_fss_slot" "$_fss_val"
                elif [ -f "$_fss_slot/pid" ] && [ ! -s "$_fss_slot/pid" ] && _fss_unclaimed "$_fss_slot/pid"; then
                    _fss_reclaim "$_fss_slot" ""
                fi
            fi
            _fss_i=$((_fss_i + 1))
        done
        if [ "$_fss_refused" -ge "$_fss_k" ]; then
            # Every slot refused in this pass: the pool cannot hold a stamp
            # at all (ENOSPC, EDQUOT, EROFS). Fail open now.
            FORGE_SLOT_HELD=""
            return 0
        fi
        # No slot won: each was held by a live holder or refused. Wait, then
        # fail open.
        if [ "$_fss_waited" -ge "$_fss_wait" ]; then
            FORGE_SLOT_HELD=""
            return 0
        fi
        sleep 1
        _fss_waited=$((_fss_waited + 1))
    done
}

# _fss_read FILE: the one way this library reads a stamp, claim or token: the
# shell's own `read`, with no command substitution and no external binary, so
# a failed fork or exec can never pass for an empty file. Sets _fss_val to
# FILE's first line, or "" when FILE is missing, empty or unreadable (the reset
# matters: a failed redirection leaves the variable untouched). Callers decide
# on the value, never on read's status: a file without a trailing newline
# returns 1 but is still read. Whether a file is empty is decided only by the
# builtin `[ -s ]`, so "" from a non-empty file means unreadable, never empty.
_fss_read() {
    _fss_val=""
    { IFS= read -r _fss_val < "$1"; } 2>/dev/null || :
}

# _fss_mine FILE: succeed when FILE holds our PID. A non-empty FILE that reads
# as nothing is read once more; if it is still unreadable it is not ours to
# remove (see release_forge_slot).
_fss_mine() {
    _fss_read "$1"
    if [ -z "$_fss_val" ] && [ -s "$1" ]; then
        _fss_read "$1"
    fi
    [ "$_fss_val" = "$$" ]
}

# _fss_create FILE: the one exclusivity primitive, used for stamps and reap
# tokens. First a claim FILE.c.<our PID> (a plain create of our own name, no
# data), then FILE itself only if it does not exist yet (`set -C`:
# O_CREAT|O_EXCL in bash and dash), with our PID written through that same
# descriptor. The claim covers the moment FILE exists but is still empty: an
# empty FILE is dead only when no claim names a live PID (_fss_unclaimed), so a
# live creator is never declared dead, however long it stalls. Sets _fss_rc:
#   won    FILE created and stamped (claim removed)
#   lost   FILE existed (claim removed)
#   wfail  FILE created but the write failed: FILE removed, then the claim
#   cfail  the claim could not be created, twice (the dir is re-created in
#          between); nothing was attempted. Slot dirs are never removed by this
#          library (see release_forge_slot), so that means a refusing filesystem.
# `true` (a regular builtin) carries the claim redirection, because a failed
# redirection on the special builtin `:` would exit the subshell before
# `exit 4`. A failed redirection exits 1 (bash) or 2 (dash), never 3 or 4.
_fss_create() {
    _fss_try=1
    while :; do
        if ( true > "$1.c.$$" || exit 4; set -C; { printf '%s' "$$" >&3 || exit 3; } 3> "$1" ) 2>/dev/null; then
            _fss_rc=won
        else
            case $? in
                3) _fss_rc=wfail ;;
                4) _fss_rc=cfail ;;
                *) _fss_rc=lost ;;
            esac
        fi
        if [ "$_fss_rc" != cfail ] || [ "$_fss_try" -ge 2 ]; then
            break
        fi
        # The claim's dir can vanish under us only from outside this version
        # (a pre-#2362 holder's release removes it, or the pool was deleted):
        # re-create it and decide by one more attempt, never by a re-check.
        mkdir -p "${1%/*}" 2>/dev/null || :
        _fss_try=2
    done
    if [ "$_fss_rc" = wfail ]; then
        rm -f "$1" 2>/dev/null || :
    fi
    if [ "$_fss_rc" != cfail ]; then
        rm -f "$1.c.$$" 2>/dev/null || :
    fi
}

# _fss_unclaimed FILE: succeed when no live process claims FILE, i.e. every
# FILE.c.<pid> names a dead or invalid PID. Under `set -f` the claims cannot be
# listed, so FILE counts as claimed (never wrongly dead).
_fss_unclaimed() {
    case $- in *f*) return 1 ;; esac
    for _fss_c in "$1".c.*; do
        if [ -e "$_fss_c" ]; then
            _fss_cp="${_fss_c##*.c.}"
            case "$_fss_cp" in
                '' | *[!0123456789]* | 0* | ??????????*) ;;
                *) if kill -0 "$_fss_cp" 2>/dev/null; then return 1; fi ;;
            esac
        fi
    done
    return 0
}

# _fss_sweep_claims FILE: remove FILE's claims whose PID is dead or invalid
# (left by a creator killed between its claim and its cleanup).
_fss_sweep_claims() {
    case $- in *f*) return 0 ;; esac
    for _fss_c in "$1".c.*; do
        if [ -e "$_fss_c" ]; then
            _fss_cp="${_fss_c##*.c.}"
            case "$_fss_cp" in
                '' | *[!0123456789]* | 0* | ??????????*) rm -f "$_fss_c" 2>/dev/null || : ;;
                *) if ! kill -0 "$_fss_cp" 2>/dev/null; then rm -f "$_fss_c" 2>/dev/null || :; fi ;;
            esac
        fi
    done
    return 0
}

# _fss_sweep SLOT PREFIX: remove SLOT's reap tokens (and their claims) named
# reap.PREFIX*. Only called once SLOT's stamp no longer names the holder those
# tokens are for, so any reclaim they could still serialize is a no-op.
_fss_sweep() {
    for _fss_tok in "$1"/reap."$2"*; do
        if [ -e "$_fss_tok" ]; then
            rm -f "$_fss_tok" 2>/dev/null || :
        fi
    done
    return 0
}

# _fss_reclaim SLOT HOLDER: free SLOT when its stamped HOLDER is dead. The
# order of the steps is load-bearing:
#   1. Liveness first. A live holder is left alone; a dead PID stays dead.
#   2. Win a reap token: the lowest generation g of SLOT/reap.TAG.g that we
#      create ourselves (_fss_create), where every lower generation exists and
#      belongs to a dead owner (its PID, or for an empty token its claims).
#      Two reclaimers never both pass: for one g only one create succeeds, and
#      a climber passes g only after seeing its owner dead. This also takes
#      over a token whose owner was killed mid-reclaim. Tokens of TAG are only
#      removed once the stamp no longer names HOLDER, so the set a climber
#      walks only grows while a reclaim can still act; it is finite, so the
#      climb always ends.
#   3. Re-check under the token, then act: remove the stamp only if it still
#      names HOLDER and HOLDER is still dead (a new holder may reuse the PID),
#      or, for an empty stamp, only if it is still empty and still unclaimed.
#      Only the token owner may remove it, and no acquirer can replace an
#      existing file, so the stamp cannot change between the re-check and the
#      removal, and a reclaimer that read a holder which has since released
#      never removes the new holder's stamp.
#   4. The stamp no longer names HOLDER: sweep every token of TAG and the
#      stamp's dead claims.
# TAG is HOLDER only when it is a positive decimal with no leading zero and at
# most 9 digits (Linux caps PIDs at 2^22, macOS at 99999); an empty HOLDER is
# reaped as TAG `empty`, any other content as `invalid`, so garbage never
# becomes part of a path and never reaches `kill -0` (`0` and `-1` signal
# process groups; bash in POSIX mode returns 0 for `kill -0 abc` and for a PID
# past 2^31).
# _FSS_REAP names the token while this shell may own it; tokens hold their
# owner's PID, so a TERM trap's release_forge_slot removes ours and never
# another reclaimer's. Always returns 0: callers run under `set -e`.
_fss_reclaim() {
    case "$2" in
        '') _fss_tag=empty ;;
        *[!0123456789]* | 0* | ??????????*) _fss_tag=invalid ;;
        *) _fss_tag="$2" ;;
    esac
    if [ "$_fss_tag" = "$2" ] && kill -0 "$2" 2>/dev/null; then
        return 0
    fi
    _fss_g=1
    while :; do
        _FSS_REAP="$1/reap.$_fss_tag.$_fss_g"
        _fss_create "$_FSS_REAP"
        if [ "$_fss_rc" = won ]; then
            break
        fi
        _FSS_REAP=""
        if [ "$_fss_rc" != lost ]; then
            return 0
        fi
        _fss_read "$1/reap.$_fss_tag.$_fss_g"
        _fss_owner="$_fss_val"
        case "$_fss_owner" in
            '')
                # Empty (size test) and unclaimed: its owner died between
                # create and write. Unreadable or claimed: a live owner.
                if [ -f "$1/reap.$_fss_tag.$_fss_g" ] && [ ! -s "$1/reap.$_fss_tag.$_fss_g" ] \
                    && _fss_unclaimed "$1/reap.$_fss_tag.$_fss_g"; then
                    :
                else
                    return 0
                fi
                ;;
            *[!0123456789]* | 0* | ??????????*) ;;
            *)
                if kill -0 "$_fss_owner" 2>/dev/null; then
                    return 0
                fi
                ;;
        esac
        _fss_g=$((_fss_g + 1))
    done
    _fss_read "$1/pid"
    _fss_now="$_fss_val"
    _fss_dead=no
    if [ "$_fss_now" = "$2" ]; then
        if [ -z "$2" ]; then
            if [ -f "$1/pid" ] && [ ! -s "$1/pid" ] && _fss_unclaimed "$1/pid"; then
                _fss_dead=yes
            fi
        elif [ "$_fss_tag" != "$2" ] || ! kill -0 "$2" 2>/dev/null; then
            # Liveness again under the token: the stamp may now be a new
            # holder whose PID reuses the dead one's.
            _fss_dead=yes
        fi
    fi
    if [ "$_fss_dead" = yes ]; then
        rm -f "$1/pid" 2>/dev/null || :
    fi
    _fss_sweep "$1" "$_fss_tag."
    _fss_sweep_claims "$1/pid"
    _FSS_REAP=""
    return 0
}

# release_forge_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap, so it also drops a reap token this shell owns when the trap
# fires mid-reclaim (_fss_reclaim). It removes the stamp only while the stamp
# still names us, so it can never free a slot someone else holds. It keeps the
# slot dir: the dir is only a container, and removing it let a concurrent
# acquirer's claim fail between its `mkdir` and its create (#2362 review).
# Dirs above a lowered FORGE_MAX_SLOTS stay as empty, unscanned dirs. A
# stamp or token that is still unreadable after one retry (_fss_mine) is kept:
# it names us, so PID liveness frees it once this process exits; until then
# that slot counts as held by us, which errs on the side of the cap.
release_forge_slot() {
    if [ -n "${_FSS_REAP:-}" ]; then
        if _fss_mine "$_FSS_REAP"; then
            rm -f "$_FSS_REAP" 2>/dev/null || :
        fi
        _FSS_REAP=""
    fi
    if [ -n "${FORGE_SLOT_HELD:-}" ]; then
        if _fss_mine "$FORGE_SLOT_HELD/pid"; then
            rm -f "$FORGE_SLOT_HELD/pid" 2>/dev/null || :
        fi
        FORGE_SLOT_HELD=""
    fi
}
