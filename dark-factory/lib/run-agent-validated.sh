#!/usr/bin/env bash
# dark-factory/lib/run-agent-validated.sh — shared reply-shape validation + retry layer for the
# DISCOVERY pipeline scrapers (#1707). Sourced (never executed) by the four scripts that invoke a
# substrate agent via `agentis go` and then SCRAPE its reply for a sentinel: map-zones.sh (zone-mapper),
# gen-briefs.sh (brief-writer), run-discovery.sh (hunter), run-refute.sh (refuter). verify-findings.sh
# inherits the fix transitively — it has no `agentis go`, it shells out to run-refute.sh.
#
# THE BUG THIS CLOSES. flat-cyborg drives an interactive Claude Code session over a PTY; when the session
# intermittently fails to submit/render, the captured reply is TUI chrome (`high · /effort`, `esc to
# interrupt`, a bare prompt frame) with NO sentinel line. Every scraper then greps for its sentinel, finds
# nothing, and SILENTLY treats "no sentinel" as a legitimate empty result (an unclassified zone, a
# mechanical-fallback brief, a rigorous NEGATIVE cell, a REFUTED candidate) — a false negative that hides a
# render flake as a real answer. This helper adds the missing gate: after each `agentis go` it checks the
# reply actually carries the stage's sentinel and, if not, RETRIES (bounded), then FAILS LOUDLY with a
# `.novalid` marker instead of accepting the chrome.
#
# WHY ONE SHARED PREDICATE. df_sentinel_present() is deliberately the SAME grep each scraper's own scrape
# uses, so "validation passes" iff "the downstream scrape will find something". A per-script inline loop
# would let the four stages drift on the retry count, the loud-failure wording, and — worst — the validity
# predicate could silently diverge from the scrape predicate, reintroducing this exact class of gap.
#
# SCOPE. This only answers "does the sentinel LINE exist at all". Content-validity of a PRESENT sentinel
# (bracket/template echo) is #1655's job; multi-line wrap of a captured sentinel is #1705's. The legit
# "empty" replies (a bare `SAFE` from the hunter, a bare `SKIP` from the brief-writer) ARE valid sentinels
# and PASS on the first attempt — matched anchored to a whole line so prose merely containing the word
# "safe"/"skip" cannot false-accept.
#
# RETRY SAFETY. A missing-sentinel reply is side-effect-free on the shared state: hunter.ag posts to the
# blackboard + emit()s a lead ONLY inside its `CANDIDATE|` branch, so a chrome reply posts nothing and a
# retry cannot double-post; zone-mapper/brief-writer/refuter write only an idempotent memo into the
# throwaway per-run store (discarded after the scrape), no blackboard, no verdict, no external write.
#
# Usage (bash; relies on dynamic scope so the caller-supplied attempt fn reads the call site's locals):
#   . "$HERE/lib/run-agent-validated.sh"
#   DF_AGENT_MAX_ATTEMPTS="$(df_max_attempts)"          # validated ceiling (env knob, default 5)
#   _attempt() { ( cd "$RUN" && env … "$AGENTIS" go <agent>.ag … ) >"$1" 2>&1 || echo "…" >&2; }
#   if df_run_agent_validated "$DF_AGENT_MAX_ATTEMPTS" "<label>" "$LOG" <stage> "$ZONE_ID" _attempt; then
#       … scrape "$LOG" …
#   else
#       … "$LOG.novalid" exists; record a FAILED, do NOT treat the empty log as a real negative …
#   fi

# df_max_attempts — the validated retry ceiling: DF_AGENT_MAX_ATTEMPTS env knob, default 5, floor 1. A
# garbage submit is a render/timing flake (not rate-limiting), so there is no backoff; the cost is bounded
# by this ceiling x the stage's fast-fail. 5 gives headroom over the 3 internal attempts that landed 6/6
# on the prior good run without unbounded hangs.
df_max_attempts() {
  dma="${DF_AGENT_MAX_ATTEMPTS:-5}"
  case "$dma" in ''|*[!0-9]*) dma=5 ;; esac
  [ "$dma" -ge 1 ] || dma=5
  printf '%s' "$dma"
}

# df_transport_max_retries — #2045: the BUDGET-EXEMPT fresh-session retry ceiling for a flat-cyborg TRANSPORT
# crash (`LLM transport error: flat-cyborg exited ...`). DF_AGENT_TRANSPORT_RETRIES env knob, default 2 (the
# issue's "<=2 retries"), floor 0 (0 = classify-only, no retry). These retries are counted SEPARATELY from
# df_max_attempts: a transport error is INFRA instability, not a content miss, so it must never consume one of
# the semantic sentinel attempts (AC3). Validated exactly like df_max_attempts (garbage => default 2).
df_transport_max_retries() {
  dtr="${DF_AGENT_TRANSPORT_RETRIES:-2}"
  case "$dtr" in ''|*[!0-9]*) dtr=2 ;; esac
  [ "$dtr" -ge 0 ] || dtr=2
  printf '%s' "$dtr"
}

# df_sentinel_present <stage> <log> [zone_id] — SINGLE SOURCE OF TRUTH for each stage's validity predicate,
# each mirroring that scraper's own scrape grep. Returns 0 when the log carries the stage's sentinel.
df_sentinel_present() {
  dsp_stage="$1"; dsp_log="$2"; dsp_zone="${3:-}"
  [ -f "$dsp_log" ] || return 1
  case "$dsp_stage" in
    zone-mapper)
      # map-zones.sh scrapes `grep -E '^[[:space:]]*ZONE\|'` (whitespace-tolerant, #1663).
      grep -Eq '^[[:space:]]*ZONE\|' "$dsp_log"
      ;;
    brief-writer)
      # gen-briefs.sh's slice_block() matches a WHOLE whitespace-trimmed line equal to
      # `DARK-FACTORY:BRIEF-BEGIN|<id>` (awk `s==...`, #1663 whitespace-tolerant), so this predicate must
      # anchor the same way — an unanchored substring would let prose that merely MENTIONS the sentinel pass
      # validation while slice_block extracts 0 bytes (#1707 in the opposite direction). A bare `SKIP` line is
      # the legit "skip this zone" reply (also anchored to a whole line so prose containing "skip" can't pass).
      grep -Eq "^[[:space:]]*DARK-FACTORY:BRIEF-BEGIN\|${dsp_zone}[[:space:]]*\$" "$dsp_log" \
        || grep -Eq '^[[:space:]]*SKIP[[:space:]]*$' "$dsp_log"
      ;;
    hunter)
      # run-discovery.sh scrapes a non-BLACKBOARD `CANDIDATE|` line; a bare `SAFE` line is the legit
      # "rigorous clean" reply (anchored to a whole line).
      grep -v '^BLACKBOARD-' "$dsp_log" | grep -q 'CANDIDATE|' \
        || grep -Eq '^[[:space:]]*SAFE[[:space:]]*$' "$dsp_log"
      ;;
    refuter)
      # run-refute.sh scrapes a `VERDICT|` line.
      grep -q 'VERDICT|' "$dsp_log"
      ;;
    *)
      return 1
      ;;
  esac
}

# df_llm_timeout_in_log <log> — #1955: did the call TERMINALLY time out (not merely recover from an internal
# retry)? Anchored to the terminal `[llm.timeout]` marker classify_llm_error() prints (agentis-core
# exec.rs:2795 -> `Error: runtime error: [llm.timeout] LLM call timed out after ...`). It must NOT match the
# NON-terminal internal-retry line (`[LLM retry N/M: LLM call timed out after ...]`, llm.rs:539/820/…), which
# agentis emits and then RECOVERS from with exit 0 — a bare `LLM call timed out` substring would misclassify
# such a recovered-then-chrome reply as a genuine timeout and DEFEAT the #1707 outer-retry recovery. The
# `[llm.timeout]` token is present on the terminal path only, so it is the safe discriminator: a heavy prompt
# that terminally times out will do so identically on retry, so "stop now" beats "spend another attempt".
df_llm_timeout_in_log() {
  grep -Fq '[llm.timeout] LLM call timed out' "$1"
}

# df_transport_error_in_log <log> — #2045: did the call TERMINALLY fail with a flat-cyborg/HTTP TRANSPORT error
# (as opposed to a content miss, a terminal timeout, or a transport blip agentis RECOVERED from)? Anchored to the
# `LlmError` Display prefix `LLM transport error:` (agentis-core src/llm.rs:45; the flat-cyborg backend surfaces
# `flat-cyborg exited with ...` behind it at src/llm.rs:1306). Unlike Timeout/Cancelled, classify_llm_error()
# tags a Transport error with NO `[llm.*]` marker (exec.rs:2789 `other => General(format!("{other}"))`), so this
# Display prefix is the only signal a Transport error leaves. But — exactly as a bare `LLM call timed out`
# substring would have defeated #1955 — the prefix ALSO appears in the NON-terminal internal-retry line
# `[LLM retry N/M: LLM transport error: flat-cyborg exited]` (llm.rs:539/820/…) that agentis PRINTS and then
# RECOVERS from with exit 0. A recovered-then-chrome reply (a genuine #1707 content miss whose log merely carries
# that retry line) must NOT be laundered into a re-runnable transient. So the terminal transport error is the only
# `LLM transport error:` occurrence NOT inside a `[LLM retry ` line — filter those out. When retries are exhausted
# (the real #2045 crash), agentis emits both the `[LLM retry …]` lines AND a terminal bare `LLM transport error:`
# line, so this still catches it. CRITICAL ORDERING: callers MUST check df_llm_timeout_in_log FIRST — a genuine
# terminal timeout must still early-stop (#1955), and a log that carries a `[llm.timeout]` marker alongside a
# transport-retry line is a timeout (the timeout won terminally).
df_transport_error_in_log() {
  grep -F 'LLM transport error:' "$1" | grep -qvF '[LLM retry'
}

# df_run_agent_validated <max_attempts> <label> <log> <stage> <zone_id> <attempt_fn> — run <attempt_fn>
# (which writes ONE `agentis go` invocation's output to its "$1" log arg) up to <max_attempts> times,
# validating each reply with df_sentinel_present. On the FIRST valid reply: clear any stale "$log.novalid"
# marker and return 0 (logging a one-line "valid on attempt K/N" when K > 1). After N failed attempts: log
# the loud FAILED line, drop an empty "$log.novalid" marker (so a backgrounded parallel run_cell can signal
# failure via a file, not a lost subshell exit code), and return 1.
df_run_agent_validated() {
  drav_max="$1"; drav_label="$2"; drav_log="$3"; drav_stage="$4"; drav_zone="$5"; drav_fn="$6"
  drav_tmax="$(df_transport_max_retries)"   # #2045: budget-exempt transport-retry ceiling
  drav_t=0
  drav_k=0
  # #2045 review: clear any reason markers left by a PRIOR run over the SAME log path before we start. Each
  # terminal path below writes only the marker it owns, so a re-run whose failure mode CHANGED (e.g. a previous
  # transient run left `.transient`, this run is a plain chrome miss) would otherwise let run-refute.sh /
  # run-invariant-hunt.sh misread the new failure off the stale marker. The success path clears all three too.
  rm -f "$drav_log.novalid" "$drav_log.timeout" "$drav_log.transient"
  while [ "$drav_k" -lt "$drav_max" ]; do
    drav_k=$((drav_k + 1))
    "$drav_fn" "$drav_log"
    if df_sentinel_present "$drav_stage" "$drav_log" "$drav_zone"; then
      # A valid reply resolves every prior failure mode — clear ALL stale markers (.novalid, plus the #1955
      # .timeout and #2045 .transient reason discriminators) so a re-run over the same log path reads clean.
      rm -f "$drav_log.novalid" "$drav_log.timeout" "$drav_log.transient"
      [ "$drav_k" -gt 1 ] && echo "$drav_label: valid $drav_stage sentinel on attempt $drav_k/$drav_max" >&2
      return 0
    fi
    # #1955 Lever 1b: a GENUINE [llm.timeout] (as opposed to TUI chrome) will time out identically on retry —
    # burning the remaining outer attempts buys nothing but a multiplied worst case. Stop after this one:
    # drop BOTH the .novalid marker (a timeout IS a no-valid-sentinel failure — every existing .novalid
    # consumer/counter is preserved) AND the .timeout reason discriminator (only run-discovery.sh reads it,
    # for a DISTINCT FAILED row; the other scrapers keep their existing .novalid handling untouched).
    # ORDER MATTERS: this MUST stay BEFORE the #2045 transport branch — a log carrying a terminal `[llm.timeout]`
    # alongside a transport-retry line is a genuine timeout, and must early-stop, not get a fresh-session retry.
    if df_llm_timeout_in_log "$drav_log"; then
      echo "$drav_label: $drav_stage LLM call timed out — a heavy prompt will time out identically on retry; not retrying (re-map or re-hunt)" >&2
      : > "$drav_log.novalid"
      : > "$drav_log.timeout"
      return 1
    fi
    # #2045 transport resilience: a flat-cyborg/HTTP TRANSPORT crash (`LLM transport error: flat-cyborg exited`)
    # is INFRA instability, not a content miss — the next `agentis go` is already a fresh flat-cyborg process, so
    # re-invoke on a fresh session. This retry is BUDGET-EXEMPT (AC3): refund the semantic attempt this iteration
    # spent (drav_k--) so an infra flake never counts as one of the df_max_attempts content attempts, and bound
    # it by its OWN counter (drav_tmax). On exhaustion, drop the .novalid marker (a transport crash IS a
    # no-valid-sentinel failure — every existing .novalid consumer is preserved) AND the .transient reason
    # discriminator (only run-refute.sh reads it, for a DISTINGUISHABLE RE-RUNNABLE row), then FAIL.
    if df_transport_error_in_log "$drav_log"; then
      if [ "$drav_t" -lt "$drav_tmax" ]; then
        drav_t=$((drav_t + 1))
        drav_k=$((drav_k - 1))
        echo "$drav_label: $drav_stage LLM transport error (flat-cyborg exited / transport crash) — retrying on a fresh session ($drav_t/$drav_tmax), NOT consuming a semantic attempt" >&2
        continue
      fi
      echo "$drav_label: $drav_stage LLM transport error persisted after $drav_tmax fresh-session retries — RE-RUNNABLE (not assessed), recording transient" >&2
      : > "$drav_log.novalid"
      : > "$drav_log.transient"
      return 1
    fi
  done
  echo "$drav_label: no valid $drav_stage sentinel after $drav_max attempts (reply was TUI chrome / no answer) — FAILED" >&2
  : > "$drav_log.novalid"
  return 1
}
