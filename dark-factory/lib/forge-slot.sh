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
# to tools/lib/llm-session-slot.sh (#1352) — `mkdir` is an atomic create on every
# POSIX filesystem (Linux + macOS), so it is the portable lock primitive here,
# deliberately NOT flock(1), which stock macOS does not ship (dark-factory already
# cares about macOS portability: install.sh, run-audit.sh, run-zone-sweep.sh).
# Each held slot stamps the holder PID; a slot whose holder is dead (kill -0
# fails) is reclaimed, so a crashed run never leaks a slot forever. All-slots-busy
# blocks with a bounded poll, then FAILS OPEN (proceeds without a slot) so a forge
# run is only ever delayed, never dropped — backpressure, not a new failure mode.
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
            if mkdir "$_fss_slot" 2>/dev/null; then
                # Won the slot. Stamp our PID so a future acquirer can reclaim
                # it if we die without releasing.
                printf '%s' "$$" > "$_fss_slot/pid" 2>/dev/null
                FORGE_SLOT_HELD="$_fss_slot"
                return 0
            fi
            # Occupied — reclaim if the holder PID is dead (crash-safety).
            _fss_holder="$(cat "$_fss_slot/pid" 2>/dev/null)"
            if [ -n "$_fss_holder" ] && ! kill -0 "$_fss_holder" 2>/dev/null; then
                rm -f "$_fss_slot/pid" 2>/dev/null
                rmdir "$_fss_slot" 2>/dev/null
                # do NOT claim here; loop retries the mkdir cleanly next pass
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

# release_forge_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap.
release_forge_slot() {
    if [ -n "${FORGE_SLOT_HELD:-}" ]; then
        rm -f "$FORGE_SLOT_HELD/pid" 2>/dev/null
        rmdir "$FORGE_SLOT_HELD" 2>/dev/null
        FORGE_SLOT_HELD=""
    fi
}
