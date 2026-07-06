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
# MECHANISM: a counting semaphore over K slot directories. `mkdir` is an atomic
# create on every POSIX filesystem (Linux + macOS), so it is the portable lock
# primitive here — deliberately NOT flock(1), which stock macOS does not ship
# (same reason auto-promote uses a Python fcntl helper). Each held slot stamps
# the holder PID; a slot whose holder is dead (kill -0 fails) is reclaimed, so a
# crashed session never leaks a slot forever (mirrors the daemon-registry
# PID-liveness idiom). All-slots-busy blocks with a bounded poll, then
# FAILS OPEN (proceeds without a slot) so a prompt is only ever delayed, never
# dropped — backpressure, not a new failure mode.
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
            if mkdir "$_lss_slot" 2>/dev/null; then
                # Won the slot. Stamp our PID so a future acquirer can reclaim
                # it if we die without releasing.
                printf '%s' "$$" > "$_lss_slot/pid" 2>/dev/null
                LLM_SLOT_HELD="$_lss_slot"
                return 0
            fi
            # Occupied — reclaim if the holder PID is dead (crash-safety).
            _lss_holder="$(cat "$_lss_slot/pid" 2>/dev/null)"
            if [ -n "$_lss_holder" ] && ! kill -0 "$_lss_holder" 2>/dev/null; then
                rm -f "$_lss_slot/pid" 2>/dev/null
                rmdir "$_lss_slot" 2>/dev/null
                # do NOT claim here; loop retries the mkdir cleanly next pass
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

# release_llm_slot: free the held slot. Idempotent — safe to call twice and
# safe to call when no slot was held (fail-open path). Designed to run from a
# cleanup/EXIT trap.
release_llm_slot() {
    if [ -n "${LLM_SLOT_HELD:-}" ]; then
        rm -f "$LLM_SLOT_HELD/pid" 2>/dev/null
        rmdir "$LLM_SLOT_HELD" 2>/dev/null
        LLM_SLOT_HELD=""
    fi
}
