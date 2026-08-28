#!/usr/bin/env bash
# demo-transport-resilience.sh — proof of the #2045 flat-cyborg TRANSPORT-crash resilience in the shared
# reply-validation/retry helper `lib/run-agent-validated.sh` and its two consumers (run-refute.sh,
# run-invariant-hunt.sh).
#
# THE BUG (#2045): under concurrent load flat-cyborg exits mid-LLM-call. agentis-core surfaces this as an
# `LlmError::Transport` whose Display string is `LLM transport error: flat-cyborg exited ...`. Unlike a Timeout
# (`[llm.timeout]`) or Cancelled (`[llm.cancelled]`), classify_llm_error() tags a Transport error with NO
# `[llm.*]` marker — so the Display prefix `LLM transport error:` is the ONLY discriminator. Today such a crash
# collapses a refute candidate to terminal ERROR and a deep-hunt cell to HARNESS_ERROR (measured live on
# alchemix-v3: 15/15 refute + 12/12 deep-hunt cells lost). The fix: treat a transport crash as a BOUNDED,
# BUDGET-EXEMPT fresh-session retry (AC1/AC3) and, on exhaustion, a RE-RUNNABLE transient (AC2/AC5) — never a
# semantic content miss.
#
# This demo is CI-safe: it needs NO agentis/flat-cyborg/forge binary. It feeds CRAFTED logs to the helper's
# discriminators and drives `df_run_agent_validated` with a scripted state-counter attempt fn. Two parts:
#   1) LIVE helper behaviour (always): the discriminator truth-table + the retry/budget/marker semantics.
#   2) SOURCE-GUARD (always): the transient marker is wired through run-refute.sh's row emission and the
#      transport->TRANSIENT_ERROR mapping (+ lib source) is wired through run-invariant-hunt.sh.
#
# Usage:  dark-factory/demo-transport-resilience.sh
# Exit: 0 = all assertions hold ; 1 = a regression ; 3 = a script/lib is missing.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/run-agent-validated.sh"
REFUTE="$HERE/run-refute.sh"
RIH="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-transport-resilience.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$LIB" ]    || { note "helper not found: $LIB" >&2; exit 3; }
[ -f "$REFUTE" ] || { note "run-refute.sh not found: $REFUTE" >&2; exit 3; }
[ -f "$RIH" ]    || { note "run-invariant-hunt.sh not found: $RIH" >&2; exit 3; }

# shellcheck source=lib/run-agent-validated.sh
# shellcheck disable=SC1091
. "$LIB"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/demo-transport-resilience.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CALLC="$WORK/calls"      # attempt-fn call counter (persists across the helper's retries)
SEQFILE="$WORK/seq"      # scripted per-attempt token list, one per line
LOG="$WORK/cell.log"

# The scripted attempt fn: on the N-th call, write the canned reply for token N of $SEQFILE to the helper's log
# arg ($1). Past the end of the sequence, fall back to `chrome` (a no-sentinel reply). Each token maps to the
# EXACT log shape the corresponding failure mode leaves behind.
_seq_attempt() {
  _n="$(cat "$CALLC" 2>/dev/null || echo 0)"; _n=$((_n + 1)); printf '%s' "$_n" > "$CALLC"
  _tok="$(sed -n "${_n}p" "$SEQFILE")"
  [ -n "$_tok" ] || _tok=chrome
  case "$_tok" in
    transport) printf '%s\n' 'Error: runtime error: LLM transport error: flat-cyborg exited with status 1' > "$1" ;;
    timeout)   printf '%s\n' 'Error: runtime error: [llm.timeout] LLM call timed out after 600s' > "$1" ;;
    mixed)     printf '%s\n' '[LLM retry 1/2: LLM transport error: flat-cyborg exited]' \
                             'Error: runtime error: [llm.timeout] LLM call timed out after 600s' > "$1" ;;
    recovered) printf '%s\n' '[LLM retry 2/2: LLM transport error: flat-cyborg exited]' \
                             'high · /effort' 'esc to interrupt' > "$1" ;;
    chrome)    printf '%s\n' 'high · /effort' 'esc to interrupt' > "$1" ;;
    valid)     printf '%s\n' 'Reasoning about the candidate ...' 'VERDICT|REAL|C1|high|conservation of value broken' > "$1" ;;
    *)         printf '%s\n' 'high · /effort' > "$1" ;;
  esac
}

# Drive df_run_agent_validated over a scripted sequence. Sets globals RC (helper return) and CALLS (attempt-fn
# invocations). Clears all markers first so each scenario starts clean.
run_seq() {  # run_seq <token> [<token> ...]
  : > "$CALLC"
  rm -f "$LOG" "$LOG.novalid" "$LOG.timeout" "$LOG.transient"
  printf '%s\n' "$@" > "$SEQFILE"
  df_run_agent_validated "$(df_max_attempts)" "demo-transport" "$LOG" refuter "" _seq_attempt
  RC=$?
  CALLS="$(cat "$CALLC")"
}

# =====================================================================================================
note "1) LIVE helper behaviour (no agentis/flat-cyborg binary) ..."
# =====================================================================================================

# --- (1a) discriminator truth-table -------------------------------------------------------------------
printf '%s\n' 'Error: runtime error: LLM transport error: flat-cyborg exited with status 1' > "$WORK/t.log"
printf '%s\n' 'Error: runtime error: [llm.timeout] LLM call timed out after 600s' > "$WORK/to.log"
printf '%s\n' 'high · /effort' 'esc to interrupt' > "$WORK/chrome.log"
printf '%s\n' 'VERDICT|REAL|C1|high|thing is broken' > "$WORK/v.log"

if df_transport_error_in_log "$WORK/t.log" && ! df_llm_timeout_in_log "$WORK/t.log"; then
  ok "(1a-i) transport log -> transport=yes, timeout=no"
else bad "(1a-i) transport log misclassified"; fi

if df_llm_timeout_in_log "$WORK/to.log" && ! df_transport_error_in_log "$WORK/to.log"; then
  ok "(1a-ii) [llm.timeout] log -> timeout=yes, transport=no"
else bad "(1a-ii) timeout log misclassified"; fi

if ! df_transport_error_in_log "$WORK/chrome.log" && ! df_llm_timeout_in_log "$WORK/chrome.log" \
   && ! df_sentinel_present refuter "$WORK/chrome.log"; then
  ok "(1a-iii) TUI-chrome log -> transport=no, timeout=no, no refuter sentinel"
else bad "(1a-iii) chrome log misclassified"; fi

if df_sentinel_present refuter "$WORK/v.log" \
   && ! df_transport_error_in_log "$WORK/v.log" && ! df_llm_timeout_in_log "$WORK/v.log"; then
  ok "(1a-iv) VERDICT| log -> refuter sentinel present, transport=no, timeout=no"
else bad "(1a-iv) valid sentinel log misclassified"; fi

# A log whose ONLY `LLM transport error:` occurrence is a NON-terminal `[LLM retry N/M: …]` line = agentis
# RECOVERED from a transport blip (exit 0). It is NOT a terminal crash and must read transport=NO, else a
# recovered-then-chrome reply (a genuine #1707 content miss) is laundered into a re-runnable transient.
printf '%s\n' '[LLM retry 2/2: LLM transport error: flat-cyborg exited]' 'high · /effort' > "$WORK/rec.log"
if ! df_transport_error_in_log "$WORK/rec.log" && ! df_llm_timeout_in_log "$WORK/rec.log" \
   && ! df_sentinel_present refuter "$WORK/rec.log"; then
  ok "(1a-v) recovered internal-retry-line-only log -> transport=NO (agentis recovered; not a terminal crash)"
else bad "(1a-v) recovered internal-retry-line log misclassified as a terminal transport crash"; fi

# --- (1b) AC3: transport flakes do NOT consume the semantic attempt budget ---------------------------
# max_attempts=2, transport_retries=2, sequence [transport, transport, valid] must RECOVER (0): the 2 infra
# flakes did not eat either of the 2 content attempts.
DF_AGENT_MAX_ATTEMPTS=2 DF_AGENT_TRANSPORT_RETRIES=2 run_seq transport transport valid
if [ "$RC" -eq 0 ] && [ "$CALLS" -eq 3 ]; then
  ok "(1b) AC3: 2 transport flakes budget-exempt — [transport,transport,valid] recovers (RC=0, 3 calls, 2 content attempts intact)"
else bad "(1b) AC3 failed: expected RC=0 after 3 calls, got RC=$RC CALLS=$CALLS"; fi

# --- (1c) AC1: a recovered sentinel after a transport flake -> success, markers cleared ---------------
DF_AGENT_TRANSPORT_RETRIES=2 run_seq transport valid
if [ "$RC" -eq 0 ] && [ "$CALLS" -eq 2 ] \
   && [ ! -f "$LOG.transient" ] && [ ! -f "$LOG.novalid" ] && [ ! -f "$LOG.timeout" ]; then
  ok "(1c) AC1: [transport,valid] recovers (RC=0) and clears every stale marker on the success path"
else bad "(1c) AC1 failed: RC=$RC CALLS=$CALLS transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# --- (1d) transport EXHAUSTED -> return 1 with BOTH .transient and .novalid ---------------------------
DF_AGENT_MAX_ATTEMPTS=5 DF_AGENT_TRANSPORT_RETRIES=2 run_seq transport transport transport transport
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 3 ] && [ -f "$LOG.transient" ] && [ -f "$LOG.novalid" ]; then
  ok "(1d) transport persisted past 2 retries -> RC=1 after 3 calls, drops .transient + .novalid (RE-RUNNABLE)"
else bad "(1d) exhausted-transport failed: RC=$RC CALLS=$CALLS transient=$([ -f "$LOG.transient" ] && echo y) novalid=$([ -f "$LOG.novalid" ] && echo y)"; fi

# --- (1e) #1955 non-regression: a terminal [llm.timeout] early-stops after exactly ONE attempt --------
DF_AGENT_MAX_ATTEMPTS=5 DF_AGENT_TRANSPORT_RETRIES=2 run_seq timeout
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] && [ -f "$LOG.timeout" ] && [ ! -f "$LOG.transient" ]; then
  ok "(1e) #1955: terminal [llm.timeout] early-stops after 1 call, drops .timeout, NOT .transient"
else bad "(1e) #1955 regression: RC=$RC CALLS=$CALLS timeout=$([ -f "$LOG.timeout" ] && echo y) transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# --- (1f) mixed transport-retry-line + terminal timeout -> timeout WINS (early-stop, not a retry) -----
DF_AGENT_MAX_ATTEMPTS=5 DF_AGENT_TRANSPORT_RETRIES=2 run_seq mixed
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 1 ] && [ -f "$LOG.timeout" ] && [ ! -f "$LOG.transient" ]; then
  ok "(1f) mixed transport-retry-line + [llm.timeout] -> timeout wins (early-stop after 1 call, .timeout not .transient)"
else bad "(1f) mixed-signal ordering broke: RC=$RC CALLS=$CALLS timeout=$([ -f "$LOG.timeout" ] && echo y) transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# --- (1g) #1707 non-regression: chrome-without-transport consumes exactly max_attempts, .novalid only -
DF_AGENT_MAX_ATTEMPTS=3 DF_AGENT_TRANSPORT_RETRIES=2 run_seq chrome chrome chrome chrome chrome
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 3 ] && [ -f "$LOG.novalid" ] && [ ! -f "$LOG.transient" ]; then
  ok "(1g) #1707: chrome (no transport) consumes exactly 3 semantic attempts, drops .novalid, NO .transient"
else bad "(1g) #1707 regression: RC=$RC CALLS=$CALLS (expected 3) transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# --- (1h) knob validation: DF_AGENT_TRANSPORT_RETRIES default 2, floor 0, garbage -> 2 ----------------
if [ "$(df_transport_max_retries)" = "2" ] \
   && [ "$(DF_AGENT_TRANSPORT_RETRIES=0 df_transport_max_retries)" = "0" ] \
   && [ "$(DF_AGENT_TRANSPORT_RETRIES=junk df_transport_max_retries)" = "2" ]; then
  ok "(1h) df_transport_max_retries: default 2, honours 0, coerces garbage back to 2"
else bad "(1h) df_transport_max_retries validation broke"; fi

# --- (1i) reviewer (PR #2048): a call that RECOVERED from an internal transport retry but ended in CHROME is a
# genuine #1707 content miss, NOT a re-runnable transient — the leftover `[LLM retry …]` line must not launder it.
DF_AGENT_MAX_ATTEMPTS=3 DF_AGENT_TRANSPORT_RETRIES=2 run_seq recovered recovered recovered
if [ "$RC" -eq 1 ] && [ "$CALLS" -eq 3 ] && [ -f "$LOG.novalid" ] && [ ! -f "$LOG.transient" ]; then
  ok "(1i) recovered-then-chrome consumes exactly 3 semantic attempts, drops .novalid, NO .transient (not laundered)"
else bad "(1i) recovered-then-chrome laundered to transient: RC=$RC CALLS=$CALLS transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# --- (1j) reviewer (PR #2048, stale marker): a leftover .transient from a PRIOR run over the same log path must
# not survive into a fresh run whose failure mode changed (entry-clear), else run-refute misreads a chrome miss.
: > "$CALLC"; rm -f "$LOG" "$LOG.novalid" "$LOG.timeout" "$LOG.transient"
: > "$LOG.transient"                        # plant a stale marker from an imagined prior transient run
printf '%s\n' chrome chrome chrome > "$SEQFILE"
df_run_agent_validated 3 "demo-transport" "$LOG" refuter "" _seq_attempt; RCJ=$?
if [ "$RCJ" -eq 1 ] && [ -f "$LOG.novalid" ] && [ ! -f "$LOG.transient" ]; then
  ok "(1j) stale .transient from a prior run is cleared at entry; a fresh chrome miss drops .novalid only"
else bad "(1j) stale .transient leaked into a fresh chrome-miss run: transient=$([ -f "$LOG.transient" ] && echo y)"; fi

# =====================================================================================================
note "2) SOURCE-GUARD: the transient wiring in both consumers ..."
# =====================================================================================================

# run-refute.sh emits a DISTINGUISHABLE RE-RUNNABLE ERROR row off the .transient marker (verdict cell stays ERROR).
if grep -Fq 'CELL_LOG.transient' "$REFUTE" \
   && grep -Fq 'TRANSIENT, RE-RUNNABLE (not assessed)' "$REFUTE"; then
  ok "run-refute.sh emits a distinguishable RE-RUNNABLE ERROR row off .transient (verdict cell stays ERROR)"
else bad "run-refute.sh does not wire the .transient RE-RUNNABLE row"; fi

# run-invariant-hunt.sh sources the lib and maps a no-verdict transport crash (timeout FIRST) to TRANSIENT_ERROR.
if grep -Fq '. "$HERE/lib/run-agent-validated.sh"' "$RIH" \
   && grep -Fq 'df_transport_error_in_log "$_celllog" && ! df_llm_timeout_in_log "$_celllog"' "$RIH" \
   && grep -Fq '_cverd="TRANSIENT_ERROR"' "$RIH"; then
  ok "run-invariant-hunt.sh sources the lib and maps a no-verdict transport crash -> TRANSIENT_ERROR (timeout checked first)"
else bad "run-invariant-hunt.sh does not wire the transport->TRANSIENT_ERROR mapping"; fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: a flat-cyborg TRANSPORT crash is a bounded budget-exempt fresh-session retry (AC1/AC3) that, on"
  note "      exhaustion, is a RE-RUNNABLE transient (AC2/AC5) — never a semantic content miss; timeout (#1955)"
  note "      and chrome (#1707) early-stop/budget behaviour is unchanged."
  exit 0
fi
note "DEMO FAILED — a #2045 transport-resilience assertion did not hold" >&2
exit 1
