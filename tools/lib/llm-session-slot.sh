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
# stamp is not a PID) is reclaimed, and so is an EMPTY stamp that no live
# process claims (its creator died between create and write; see _lss_create),
# so a crashed session never leaks a slot forever (mirrors the daemon-registry
# PID-liveness idiom). The reclaim is
# serialized by generation-numbered reap tokens, so a reclaimer killed mid-reclaim
# is taken over too (see _lss_reclaim). A stamp whose write fails is removed by
# its own creator. All-slots-busy blocks with a bounded poll, then FAILS OPEN
# (proceeds without a slot) so a prompt is only ever delayed, never dropped —
# backpressure, not a new failure mode.
#
# DEPLOY: restart every federation that uses a pool after updating this file.
# A pre-#2362 acquirer still running writes its stamp without noclobber and can
# overwrite a new holder's stamp, and it treats a slot dir without a stamp
# (every free slot, since release keeps the dir) as busy; neither happens once
# every process runs this version.
#
# TRUST BOUNDARY: the pool dir must be owned by the user running the sessions.
# The gate creates the pool and slot dirs 0700 and its files 0600 whatever the
# caller's umask, and repairs once an entry it does not create (a symlink,
# FIFO, device or stray file at a stamp, token, claim or slot path; a mode
# that locks the owner out). An entry it cannot repair costs that one slot.
# Only another process of the same user swapping such an entry in between a
# check and an open is outside what this lock defends against.
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
    # 0700 whatever the caller's umask: the pool and its kept slot dirs must
    # stay usable by every later acquirer of this user.
    # shellcheck disable=SC2174  # only the pool dir itself needs 0700
    mkdir -p -m 0700 "$_lss_dir" 2>/dev/null || { LLM_SLOT_HELD=""; return 0; }

    _lss_waited=0
    while :; do
        _lss_i=1
        _lss_refused=0
        while [ "$_lss_i" -le "$_lss_k" ]; do
            _lss_slot="$_lss_dir/slot-$_lss_i"
            # Container only: its exit status is ignored on purpose (#2362,
            # see MECHANISM) — the exclusive create below decides ownership.
            mkdir -m 0700 "$_lss_slot" 2>/dev/null || :
            _lss_create "$_lss_slot/pid"
            if [ "$_lss_rc" = cfail ] || [ "$_lss_rc" = wfail ]; then
                # Refused: maybe an entry left unusable by an earlier run or
                # another version (a restrictive umask, a stray file). Repair
                # once and retry once; rm's and chmod's statuses decide nothing
                # (chmod fails harmlessly on entries we do not own), the create
                # does.
                # A non-directory at the slot path (a stray file, a symlink) is
                # removed once and the slot dir created again.
                if [ -h "$_lss_slot" ] || { [ -e "$_lss_slot" ] && [ ! -d "$_lss_slot" ]; }; then
                    rm -f "$_lss_slot" 2>/dev/null || :
                    mkdir -m 0700 "$_lss_slot" 2>/dev/null || :
                fi
                chmod u+rwx "$_lss_dir" "$_lss_slot" 2>/dev/null || :
                _lss_create "$_lss_slot/pid"
            fi
            if [ "$_lss_rc" = won ]; then
                # Won the slot; the PID stamp lets a future acquirer reclaim
                # it if we die without releasing. Reap tokens and claims left
                # in it by killed processes are garbage now: the stamp names
                # us, so no reclaim of an earlier holder can act any more.
                LLM_SLOT_HELD="$_lss_slot"
                _lss_sweep "$_lss_slot" ""
                _lss_sweep_claims "$_lss_slot/pid"
                return 0
            fi
            if [ "$_lss_rc" != lost ]; then
                # This slot refused our claim or our stamp write (a full or
                # read-only filesystem, or a slot entry we cannot write: a dir
                # of another user, a stray file); _lss_create already undid
                # both. Try the next slot: one bad entry must not disable the
                # cap. Only a pass in which every slot refused fails open.
                _lss_refused=$((_lss_refused + 1))
            else
                # Occupied — reclaim if the holder is dead (crash-safety). An
                # empty stamp is dead only when _lss_dead_empty proves it on
                # one pinned instance (its creator died between create and
                # write). A stamp that is not empty but reads as nothing is
                # unreadable: its holder counts as live.
                _lss_read_stamp "$_lss_slot/pid"
                if [ -n "$_lss_val" ]; then
                    _lss_reclaim "$_lss_slot" "$_lss_val"
                elif _lss_dead_empty "$_lss_slot/pid"; then
                    _lss_reclaim "$_lss_slot" ""
                fi
            fi
            _lss_i=$((_lss_i + 1))
        done
        if [ "$_lss_refused" -ge "$_lss_k" ]; then
            # Every slot refused in this pass: the pool cannot hold a stamp
            # at all (ENOSPC, EDQUOT, EROFS). Fail open now.
            LLM_SLOT_HELD=""
            return 0
        fi
        # No slot won: each was held by a live holder or refused. Wait, then
        # fail open.
        if [ "$_lss_waited" -ge "$_lss_wait" ]; then
            LLM_SLOT_HELD=""
            return 0
        fi
        sleep 1
        _lss_waited=$((_lss_waited + 1))
    done
}

# _lss_read FILE: the one way this library reads a stamp, claim or token: the
# shell's own `read`, with no command substitution and no external binary, so
# a failed fork or exec can never pass for an empty file. Sets _lss_val to
# FILE's first line, or "" when FILE is missing, empty or unreadable (the reset
# matters: a failed redirection leaves the variable untouched). Callers decide
# on the value, never on read's status: a file without a trailing newline
# returns 1 but is still read. _lss_rs is 0 only when a whole line was read.
# Whether a file is empty is decided only by the builtin `[ -s ]`, so "" from a
# non-empty file means unreadable, never empty (but see _lss_read_stamp).
_lss_read() {
    _lss_val=""
    _lss_rs=1
    { IFS= read -r _lss_val < "$1" && _lss_rs=0; } 2>/dev/null || :
}

# _lss_read_repair FILE: _lss_read, and if a non-empty FILE reads as nothing,
# give the owner read permission once (a stamp written under a restrictive
# umask by an earlier run or another version) and read again. chmod's status
# decides nothing; the second read does.
_lss_read_repair() {
    _lss_read "$1"
    if [ -z "$_lss_val" ] && [ -s "$1" ]; then
        chmod u+r "$1" 2>/dev/null || :
        _lss_read "$1"
    fi
}

# _lss_read_stamp FILE: read a stamp or reap token for a liveness decision.
# The gate writes `printf '%s' "$$"`, never a newline, so a first line that
# reads as empty with read's status 0 is content the gate did not write: it
# becomes the value `blank-line`, which is not a PID and is reaped through tag
# `invalid`. A read that failed (status non-zero) still gives "" and counts as
# unreadable, so a failed read never makes a stamp dead.
_lss_read_stamp() {
    _lss_read_repair "$1"
    if [ -z "$_lss_val" ] && [ "$_lss_rs" = 0 ]; then
        _lss_val=blank-line
    fi
}

# _lss_dead_empty FILE: succeed only when FILE is an empty regular file whose
# creator is dead, proven on one file instance. The steps and their order:
#   1. Pin the instance now at FILE on fd 4 (a compound-command redirection;
#      a failed open just fails the test, it never exits the shell).
#   2. Scan the claims: no FILE.c.<pid>.<n> names a live process. A creator's
#      claim exists from before its create until after its write, so...
#   3. ...the pinned instance still being empty (its size read through the
#      fd, so a later unlink or rebind of the path cannot change the answer)
#      means its creator died before writing: a live creator either still had
#      its claim at step 2 or had written before step 3.
#   4. FILE still names the pinned instance (-ef), so the caller's removal
#      that follows acts on the instance judged here. Between this test and
#      that removal nothing else can unlink an empty, dead-creator stamp:
#      only the owner of the reap token of tag `empty` removes such a stamp,
#      and that token is held by the caller (see _lss_reclaim).
# Without /dev/fd the instance cannot be pinned, and the answer is "not dead"
# (fail safe: no reclaim). Callers run under `set -e`; this is only ever used
# as a condition.
# shellcheck disable=SC2094  # fd 4 only reads FILE; 2>/dev/null is the only write
_lss_dead_empty() {
    _lss_de=no
    {
        if [ -f /dev/fd/4 ] && _lss_unclaimed "$1" && [ ! -s /dev/fd/4 ] && [ /dev/fd/4 -ef "$1" ]; then
            _lss_de=yes
        fi
    } 2>/dev/null 4< "$1" || :
    [ "$_lss_de" = yes ]
}

# _lss_mine FILE: succeed when FILE holds our PID. A non-empty FILE that reads
# as nothing is read once more; if it is still unreadable it is not ours to
# remove (see release_llm_slot).
_lss_mine() {
    _lss_read_repair "$1"
    if [ -z "$_lss_val" ] && [ -s "$1" ]; then
        _lss_read "$1"
    fi
    [ "$_lss_val" = "$$" ]
}

# _lss_create FILE: the one exclusivity primitive, used for stamps and reap
# tokens. First a claim (_lss_claim: FILE.c.<our PID>.<n>, a name no other
# process uses), then FILE itself only if it does not exist yet (`set -C`:
# O_CREAT|O_EXCL in bash and dash), with our PID written through that same
# descriptor. The claim covers the moment FILE exists but is still empty: an
# empty FILE is dead only when no claim names a live PID (_lss_dead_empty), so
# a live creator is never declared dead, however long it stalls. Sets _lss_rc:
#   won    FILE created and stamped (claim removed)
#   lost   FILE existed (claim removed)
#   wfail  FILE created but the write failed: FILE removed, then the claim
#   cfail  no claim could be created, or FILE is an entry the gate never
#          creates; after one repair (below) and one more attempt. Slot dirs
#          are never removed by this library (see release_llm_slot), so a
#          cfail that survives the repair means a refusing filesystem or an
#          entry we cannot remove.
# A failed redirection exits 1 (bash) or 2 (dash), never 3.
_lss_create() {
    _lss_try=1
    while :; do
        _lss_cl=""
        if _lss_odd "$1"; then
            # Never open an entry the gate does not create: noclobber refuses
            # only an existing regular file, so a symlink there would let every
            # acquirer "win" and a FIFO would block the open forever.
            _lss_rc=cfail
        elif ! _lss_claim "$1"; then
            _lss_rc=cfail
        elif ( umask 077; set -C; { printf '%s' "$$" >&3 || exit 3; } 3> "$1" ) 2>/dev/null; then
            _lss_rc=won
            # A win must leave a regular file that reads back our PID; an
            # entry swapped in under us is not a slot we hold.
            _lss_read "$1"
            if _lss_odd "$1" || [ "$_lss_val" != "$$" ]; then
                _lss_rc=cfail
            fi
        else
            case $? in
                3) _lss_rc=wfail ;;
                *) _lss_rc=lost ;;
            esac
        fi
        if [ "$_lss_rc" = wfail ]; then
            rm -f "$1" 2>/dev/null || :
        fi
        if [ -n "$_lss_cl" ]; then
            rm -f "$_lss_cl" 2>/dev/null || :
        fi
        if [ "$_lss_rc" != cfail ] || [ "$_lss_try" -ge 2 ]; then
            break
        fi
        # Repair once, then decide by one more attempt, never by a re-check:
        # remove an entry the gate never creates (a symlink, FIFO, device or
        # empty dir: rm -f, else rmdir, never rm -r), and re-create the dir,
        # which can vanish under us only from outside this version (a
        # pre-#2362 holder's release removes it, or the pool was deleted).
        _lss_unodd "$1"
        # shellcheck disable=SC2174  # only the slot dir itself needs 0700
        mkdir -p -m 0700 "${1%/*}" 2>/dev/null || :
        _lss_try=2
    done
}

# _lss_claim FILE: create our claim on FILE and name it in _lss_cl. The name is
# FILE.c.<our PID>.<n> for the first n this process creates exclusively
# (noclobber): subshells of one shell share $$, and each still gets its own
# claim, so one never removes a claim another still needs. An existing entry at
# a candidate name (a sibling's claim, a stale one, anything odd) is skipped,
# never opened; the walk ends because the dir holds finitely many entries.
# Fails (cfail) when a create at a free name is refused (missing dir, full or
# read-only filesystem).
_lss_claim() {
    _lss_n=1
    while :; do
        _lss_cl="$1.c.$$.$_lss_n"
        if [ -e "$_lss_cl" ] || [ -h "$_lss_cl" ]; then
            _lss_n=$((_lss_n + 1))
        elif ( umask 077; set -C; true > "$_lss_cl" ) 2>/dev/null; then
            return 0
        elif [ -e "$_lss_cl" ] || [ -h "$_lss_cl" ]; then
            _lss_n=$((_lss_n + 1))
        else
            _lss_cl=""
            return 1
        fi
    done
}

# _lss_odd PATH: succeed when PATH is a symlink, dir, FIFO, socket or device:
# never an entry the gate creates at a stamp, token or claim. Each test is one
# positive stat, so a path that vanishes meanwhile, or a regular file, is never
# odd (an exists-then-not-regular pair would call a stamp released between its
# two stats odd, and _lss_unodd would then remove whatever was created there).
_lss_odd() {
    [ -h "$1" ] || [ -d "$1" ] || [ -p "$1" ] || [ -S "$1" ] || [ -b "$1" ] || [ -c "$1" ]
}

# _lss_unodd PATH: remove PATH once if it is odd (rm -f; an empty dir by
# rmdir; never rm -r). Statuses decide nothing: the next create does.
_lss_unodd() {
    if _lss_odd "$1"; then
        rm -f "$1" 2>/dev/null || rmdir "$1" 2>/dev/null || :
    fi
}

# _lss_unclaimed FILE: succeed when no live process claims FILE, i.e. every
# FILE.c.<pid>.<n> names a dead or invalid PID. Under `set -f` the claims cannot be
# listed, so FILE counts as claimed (never wrongly dead).
_lss_unclaimed() {
    case $- in *f*) return 1 ;; esac
    for _lss_c in "$1".c.*; do
        if [ -e "$_lss_c" ]; then
            _lss_cp="${_lss_c##*.c.}"
            _lss_cp="${_lss_cp%%.*}"
            case "$_lss_cp" in
                '' | *[!0123456789]* | 0* | ??????????*) ;;
                *) if kill -0 "$_lss_cp" 2>/dev/null; then return 1; fi ;;
            esac
        fi
    done
    return 0
}

# _lss_sweep_claims FILE: remove FILE's claims whose PID is dead or invalid
# (left by a creator killed between its claim and its cleanup).
_lss_sweep_claims() {
    case $- in *f*) return 0 ;; esac
    for _lss_c in "$1".c.*; do
        if [ -e "$_lss_c" ]; then
            _lss_cp="${_lss_c##*.c.}"
            _lss_cp="${_lss_cp%%.*}"
            case "$_lss_cp" in
                '' | *[!0123456789]* | 0* | ??????????*) rm -f "$_lss_c" 2>/dev/null || : ;;
                *) if ! kill -0 "$_lss_cp" 2>/dev/null; then rm -f "$_lss_c" 2>/dev/null || :; fi ;;
            esac
        fi
    done
    return 0
}

# _lss_sweep SLOT PREFIX: remove SLOT's reap tokens (and their claims) named
# reap.PREFIX*, never those of tag `empty`. Only called once SLOT's stamp no
# longer names the holder those tokens are for: a PID tag's holder never comes
# back, so any reclaim they could still serialize is a no-op. An empty stamp,
# though, can appear again at any time (every creator passes through one), so
# tag `empty` tokens are never swept: removing a lower generation would let a
# new reclaimer re-create it while a climber that already passed it holds a
# higher one, and two `empty` reclaims would run at once. Only the owner of
# the top `empty` token removes it, after its own reclaim (_lss_reclaim).
_lss_sweep() {
    for _lss_tok in "$1"/reap."$2"*; do
        case "${_lss_tok##*/}" in
            reap.empty.*) continue ;;
        esac
        if [ -e "$_lss_tok" ]; then
            rm -f "$_lss_tok" 2>/dev/null || :
        fi
    done
    return 0
}

# _lss_reclaim SLOT HOLDER: free SLOT when its stamped HOLDER is dead. The
# order of the steps is load-bearing:
#   1. Liveness first. A live holder is left alone; a dead PID stays dead.
#   2. Win a reap token: the lowest generation g of SLOT/reap.TAG.g that we
#      create ourselves (_lss_create), where every lower generation exists and
#      belongs to a dead owner (its PID, or for an empty token its claims).
#      Two reclaimers never both pass: for one g only one create succeeds, and
#      a climber passes g only after seeing its owner dead (an empty token:
#      _lss_dead_empty on the pinned instance). This also takes over a token
#      whose owner was killed mid-reclaim. Tokens of a PID tag are only
#      removed once the stamp no longer names HOLDER, and `empty` tokens only
#      by their own owner (see _lss_sweep), so the set a climber walks only
#      grows while a reclaim of that tag can still act; it is finite, so the
#      climb always ends.
#   3. Re-check under the token, then act.
#      - A PID stamp: remove it only if it still names HOLDER and HOLDER is
#        still dead (a new holder may reuse the PID). A non-empty stamp never
#        changes content, and while it exists no acquirer can create the
#        path; it is unlinked only by its holder's release (HOLDER is dead) or
#        by the owner of this tag's token (us). So it cannot change between
#        this test and the removal.
#      - An empty stamp: remove it only if _lss_dead_empty proves, on one
#        pinned instance, that its creator died before writing, and the path
#        still names that instance. An empty stamp whose creator is dead is
#        unlinked only by the owner of the `empty` token, which is us, so the
#        path cannot be rebound between that proof and the removal.
#      A reclaimer that read a holder which has since released therefore
#      never removes a new holder's stamp.
#   4. The stamp no longer names HOLDER: sweep the tag's tokens (for `empty`,
#      only our own) and the stamp's dead claims.
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
        _LSS_REAP="$1/reap.$_lss_tag.$_lss_g"
        _lss_create "$_LSS_REAP"
        if [ "$_lss_rc" = won ]; then
            break
        fi
        _LSS_REAP=""
        if [ "$_lss_rc" != lost ]; then
            return 0
        fi
        _lss_read_stamp "$1/reap.$_lss_tag.$_lss_g"
        _lss_owner="$_lss_val"
        case "$_lss_owner" in
            '')
                # Empty and unclaimed on one pinned instance: its owner died
                # between create and write. Unreadable or claimed: live.
                if _lss_dead_empty "$1/reap.$_lss_tag.$_lss_g"; then
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
    _lss_read_stamp "$1/pid"
    _lss_now="$_lss_val"
    _lss_dead=no
    if [ "$_lss_now" = "$2" ]; then
        if [ -z "$2" ]; then
            if _lss_dead_empty "$1/pid"; then
                _lss_dead=yes
            fi
        elif [ "$_lss_tag" != "$2" ] || ! kill -0 "$2" 2>/dev/null; then
            # Liveness again under the token: the stamp may now be a new
            # holder whose PID reuses the dead one's.
            _lss_dead=yes
        fi
    fi
    if [ "$_lss_dead" = yes ]; then
        rm -f "$1/pid" 2>/dev/null || :
    fi
    if [ "$_lss_tag" = empty ]; then
        rm -f "$_LSS_REAP" 2>/dev/null || :
    else
        _lss_sweep "$1" "$_lss_tag."
    fi
    _lss_sweep_claims "$1/pid"
    _LSS_REAP=""
    return 0
}

# release_llm_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap, so it also drops a reap token this shell owns when the trap
# fires mid-reclaim (_lss_reclaim). It removes the stamp only while the stamp
# still names us, so it can never free a slot someone else holds. It keeps the
# slot dir: the dir is only a container, and removing it let a concurrent
# acquirer's claim fail between its `mkdir` and its create (#2362 review).
# Dirs above a lowered LLM_MAX_CONCURRENT stay as empty, unscanned dirs. A
# stamp or token that is still unreadable after one retry (_lss_mine) is kept:
# it names us, so PID liveness frees it once this process exits; until then
# that slot counts as held by us, which errs on the side of the cap.
release_llm_slot() {
    if [ -n "${_LSS_REAP:-}" ]; then
        if _lss_mine "$_LSS_REAP"; then
            rm -f "$_LSS_REAP" 2>/dev/null || :
        fi
        _LSS_REAP=""
    fi
    if [ -n "${LLM_SLOT_HELD:-}" ]; then
        if _lss_mine "$LLM_SLOT_HELD/pid"; then
            rm -f "$LLM_SLOT_HELD/pid" 2>/dev/null || :
        fi
        LLM_SLOT_HELD=""
    fi
}
