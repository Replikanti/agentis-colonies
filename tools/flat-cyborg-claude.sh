#!/usr/bin/env sh
# flat-cyborg-claude.sh — the agentis `llm.command` CLI backend for the
# dev-apprenticeship federation: drives the INTERACTIVE Claude Code session
# through flat-cyborg's PTY wrapper (uses the Claude Code subscription, NOT the
# metered `claude -p` API path). agentis invokes the configured llm.command with
# the prompt as a trailing positional arg; this wrapper takes the prompt from
# "$1" (falling back to stdin) and returns only the model's reply on stdout
# (read from a result file claude writes; see the RESULT-FILE channel note
# below, with a flat-cyborg --extract screen-scrape as fallback).
#
# This generalizes the proven dark-factory/flat-cyborg-claude.sh into shared,
# path-independent tooling so every dev-apprenticeship colony can use the same
# CLI backend. install.sh §6 wires it as the default:
#   llm.backend = cli
#   llm.command = <abs path to this script>
#   llm.args    =                       (empty — the prompt is the sole arg)
#
# flat-cyborg and claude are resolved from PATH; this file contains NO absolute
# paths. flat-cyborg must be installed (https://github.com/Replikanti/flat-cyborg;
# an installed copy self-updates with `flat-cyborg update`).
#
# Knobs (env vars): FLAT_CYBORG_IDLE_MS, FLAT_CYBORG_TIMEOUT_MS,
# CLAUDE_REASONING_EFFORT (claude --settings effortLevel for this reasoning
# session; default "medium" — the measured sweet spot for typed-JSON
# extraction, binary discipline, and pattern-summary prompts; accepts
# low|medium|high|xhigh, an unrecognised value falls back to "medium" with a
# warning), FLAT_CYBORG_RESULT_FILE (#1449; default "1"/on — set "0" to opt a
# WEAK model into screen-scrape-only mode: no [OUTPUT CHANNEL] directive is
# appended and flat-cyborg runs with plain `--extract` only, dropping
# `--extract-structural`. Live-diagnosed root cause: a weak model (e.g. haiku)
# can silently no-op its file-write tool against the RESULT_FILE path, leaving
# it empty while the directive text still sits on screen confusing
# --extract-structural's chrome-scrape fallback; the plain sentinel-only
# `--extract` path is what was proven reliable for that model. This reintroduces
# the pre-#1219 scroll limitation for long replies — short-reply/weak-model use
# only, see doc/llm-backend.md).
#
# RESULT-FILE channel (#1219): the historical extraction path reads claude's
# reply off the rendered TUI via --extract / --extract-structural. That is a
# screen-scrape: a reply taller than the screen scrolls the start sentinel out
# of view, so --extract returns nothing and --extract-structural falls back to
# whatever chrome/prose is on screen — the caller then decodes invalid JSON.
# (Observed live: drafting prompts intermittently failed "CLI returned invalid
# JSON".) The fix is to stop trusting the screen: we ask claude to write its
# COMPLETE reply to a temp file with its file-write tool and read THAT. claude's
# Write tool emits exact bytes (no scroll, no line-wrap, no chrome). The
# screen-scrape path is kept as a FALLBACK for when claude does not write the
# file, so this is strictly >= the old behaviour. A non-empty result file even
# after a flat-cyborg non-zero exit (idle/timeout that still produced the answer)
# is honoured — same spirit as commit-on-diff in code-edit-in-checkout.sh (#1216).
# FLAT_CYBORG_RESULT_FILE=0 (#1449) opts OUT of this channel entirely and falls
# back to the pre-#1219 screen-scrape path — defaults ON (opt-out is for a
# weak/short-reply model only; see the knob doc above and doc/llm-backend.md).
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Federation-wide LLM-session concurrency cap (#1352): hold one of K slots for
# the duration of this flat-cyborg session so at most LLM_MAX_CONCURRENT sessions
# run across the whole federation, independent of how many agents are at
# autonomous tier. Sourcing is best-effort — an absent lib must never break the
# wrapper (acquire/release degrade to no-ops).
# shellcheck source=lib/llm-session-slot.sh
# shellcheck disable=SC1091
[ -r "$SCRIPT_DIR/lib/llm-session-slot.sh" ] && . "$SCRIPT_DIR/lib/llm-session-slot.sh"
command -v acquire_llm_slot >/dev/null 2>&1 || { acquire_llm_slot() { :; }; release_llm_slot() { :; }; }
PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then PROMPT="$(cat)"; fi
# Screen-scrape opt-out gate (#1449): exactly "0" disables the result-file
# channel below; anything else (including unset, the default "1") keeps it on.
# A plain boolean gate, not interpolated into `claude --settings` JSON, so
# there is no injection surface to harden against (unlike CLAUDE_REASONING_EFFORT).
FLAT_CYBORG_RESULT_FILE="${FLAT_CYBORG_RESULT_FILE:-1}"
# The authoritative output channel: a file claude writes its reply to. Created
# empty up front; claude is told (below) to overwrite it with the raw reply.
RESULT_FILE="$(mktemp)"
# Append the output-channel directive to the caller's prompt. It is additive and
# backend-generic (JSON and prose consumers alike): claude writes its exact reply
# to RESULT_FILE; if it doesn't, the screen-scrape fallback preserves old behaviour.
# Skipped entirely when FLAT_CYBORG_RESULT_FILE=0 (#1449): $RESULT_FILE is still
# created above (harmless — cleaned up by the existing _cleanup trap) but is
# never written to, so the "prefer the result-file channel" check further down
# is naturally false and falls through to the screen-scrape REPLY_FILE read —
# this is NOT dead code, it is the intended no-op path for the opt-out.
if [ "$FLAT_CYBORG_RESULT_FILE" != "0" ]; then
    PROMPT="$PROMPT

[OUTPUT CHANNEL] Write your COMPLETE reply — and nothing else — to this exact file path using your file-writing tool: $RESULT_FILE
Write the raw reply content only: for a JSON reply, the raw JSON object with NO markdown code fences; for prose, the prose itself. This file is the authoritative channel for your answer — write it before you finish."
fi
# --wrap-input 72: fold the (often single-line, ~700-char) instruction block so it
# does not overflow claude's editor input.
# --extract-structural (needs flat-cyborg >=0.10.2): claude INTERMITTENTLY omits the
# reply sentinel; strict --extract then burns the full --timeout-ms and exits "no
# fenced reply", which the agentis caller retries -> repeated ~700s gen hangs that end
# in HARNESS_ERROR. Structural mode completes on a SETTLED screen and recovers the
# reply marker-first -> structural-fallback (fast + marker-less-tolerant); a reply that
# DOES carry the markers is extracted exactly as before.
# JSON-shaped-reply unwrap (#1163): --extract-structural is a TUI screen-scrape,
# so claude's TUI LINE-WRAPS long output, injecting newline+indent INSIDE a JSON
# string and breaking the JSON the caller decodes. Post-process the extracted
# reply through tools/flat-cyborg-unwrap.py: when the trimmed reply is a single
# JSON object (`{…}`) it collapses soft-wrap whitespace to one line; any other
# reply (prose/code/markdown from non-JSON consumers) passes through
# byte-for-byte. The filter only ever fires on `{…}`-shaped replies, so prose
# consumers are safe.
#
# We do NOT pipe directly (POSIX sh / dash has no `pipefail` and no PIPESTATUS):
# capture flat-cyborg's stdout to a temp file AND its exit status first,
# propagate that status unchanged (a flat-cyborg failure must still reach the
# agentis caller as before), then feed the captured reply through the unwrap
# filter. A temp file (not `$(...)`) preserves the reply's bytes exactly,
# including any trailing newline, so prose consumers stay byte-identical.
REPLY_FILE="$(mktemp)"
# #1171: pass the prompt via --cmd-file (a file), NOT --cmd (an argv value). A
# multi-MB prompt as a command-line argument overflows ARG_MAX (exec fails
# E2BIG / "Argument list too long") — agents on a real repo build multi-MB
# contexts (MR diffs + history) and hit exactly this. Requires flat-cyborg
# >= 0.11.0 (the --cmd-file flag).
PROMPT_FILE="$(mktemp)"
printf '%s' "$PROMPT" > "$PROMPT_FILE"
# Descendant reap (#1369). flat-cyborg drives claude through its OWN PTY session,
# so the leaked claude (Node) child + its Bash-tool grandchildren sit behind a
# process-group AND session boundary a group-kill can't reach; and `set -m`/PGID
# job control no-ops without a controlling terminal — which is exactly the agentis
# daemon's runtime context, so the retired #1367 `set -m` reap silently no-op'd
# where it mattered. Do it tty-independently instead: capture flat-cyborg's PID
# from `&`/`$!` (no job control needed) and, at teardown, SIGKILL the whole
# transitive /proc parent-PID-chain closure rooted at it — crossing any group or
# session boundary. Mirrors the cwd-match reap already proven on the edit-job path
# (code-edit-in-checkout.sh:reap_editing_strays, #1248/#1249).
reap_fc_descendants() {
    _root="${1:-}"
    { [ -n "$_root" ] && [ -d /proc ]; } || return 0
    # Transitive descendant closure of $_root via repeated PPid sweeps over /proc
    # (fixpoint; POSIX, no arrays — a space-padded PID-set string).
    _set=" $_root "
    _changed=1
    while [ "$_changed" = 1 ]; do
        _changed=0
        for _st in /proc/[0-9]*/status; do
            [ -r "$_st" ] || continue
            _pid="${_st#/proc/}"; _pid="${_pid%/status}"
            case "$_set" in *" $_pid "*) continue ;; esac
            _ppid="$(awk '/^PPid:/{print $2; exit}' "$_st" 2>/dev/null || true)"
            [ -n "$_ppid" ] || continue
            case "$_set" in
                *" $_ppid "*) _set="$_set$_pid "; _changed=1 ;;
            esac
        done
    done
    # Closure captured; SIGKILL every member except this wrapper. SIGKILL needs no
    # ordering, and a member reparented mid-loop is already in the set.
    for _pid in $_set; do
        [ "$_pid" != "$$" ] || continue
        kill -KILL "$_pid" 2>/dev/null || true
    done
}

FC_PID=""
_CLEANED=0
_cleanup() {
    [ "$_CLEANED" = 0 ] || return 0
    _CLEANED=1
    set +e   # a teardown reap must never abort mid-cleanup under `set -e`
    reap_fc_descendants "$FC_PID"
    release_llm_slot   # free our concurrency slot (#1352); idempotent
    rm -f "$REPLY_FILE" "$PROMPT_FILE" "$RESULT_FILE"
}
# EXIT covers the normal + `exit` paths; the signal traps cover the daemon tearing
# a wedged wrapper down (SIGKILL is untrappable, but INT/TERM/HUP are not). The
# once-guard keeps the EXIT trap from re-reaping after a signal handler already did.
trap '_cleanup' EXIT
trap '_cleanup; exit 130' INT
trap '_cleanup; exit 143' TERM
trap '_cleanup; exit 129' HUP
set +e
# Idle/timeout defaults (#1345): under concurrent multi-agent load a long reply
# (e.g. the ~140s code-writer draft) stalls mid-generation for several seconds;
# an 8s idle window mistakes that stall for a settled screen and screen-scrapes
# an empty/partial reply, so the JSON decode fails and the tick silently dies
# ("exit 124: no fenced reply"). Raise the idle settle window to 30s and the
# total wall-clock timeout to 240s so a mid-reply pause is not read as "done".
# The FLAT_CYBORG_IDLE_MS / FLAT_CYBORG_TIMEOUT_MS env overrides still win.
# Background flat-cyborg (#1369) so we can capture its PID (`$!`) for the reap,
# then wait for it exactly as a foreground run would (its stdout is still
# redirected to REPLY_FILE). A trapped signal interrupts the wait, runs _cleanup
# (reap + rm), and exits.
# Concurrency cap (#1352): claim a slot BEFORE spawning flat-cyborg. Under
# contention this waits its turn (bounded, fails open) — backpressure that keeps
# the host from thrashing on N simultaneous PTY sessions. The _cleanup trap (set
# above, before any early exit) releases it. Acquire here, after the traps are
# armed, so a signal during the wait still releases cleanly.
acquire_llm_slot
# Model routing (tier-by-workload): every agent's prompt() reasoning runs on the
# lighter/faster model by default (Sonnet 5 via the `sonnet` alias = latest
# sonnet). The heavier code-generation path (tools/code-edit-in-checkout.sh)
# routes to Opus 4.8 separately. Override with CLAUDE_REASONING_MODEL (a claude
# --model value: an alias like `sonnet`/`opus`/`fable`, or a full model id).
#
# Effort-level routing (#1444): reasoning sessions default to "medium" instead
# of inheriting the operator's account-level effortLevel (an operator with a
# high personal default would otherwise have all 22 daemons burn max-effort
# chain-of-thought on routine, low-complexity prompts). Harden against a typo
# reaching `claude --settings` unvalidated: only a known-good value is ever
# interpolated into the JSON string.
CLAUDE_REASONING_EFFORT="${CLAUDE_REASONING_EFFORT:-medium}"
case "$CLAUDE_REASONING_EFFORT" in
    low|medium|high|xhigh) ;;
    *)
        echo "flat-cyborg-claude.sh: invalid CLAUDE_REASONING_EFFORT '$CLAUDE_REASONING_EFFORT', falling back to medium" >&2
        CLAUDE_REASONING_EFFORT=medium
        ;;
esac
EFFORT_SETTINGS='{"effortLevel":"'"$CLAUDE_REASONING_EFFORT"'"}'
# Extraction mode (#1449): plain sentinel-only --extract by default when the
# result-file channel is opted out (FLAT_CYBORG_RESULT_FILE=0); otherwise keep
# the existing --extract-structural TUI-chrome fallback too. $EXTRACT_FLAGS is
# used UNQUOTED below (intentional word-splitting on a fixed, space-only
# literal — same idiom already used for the other unquoted flags on this line;
# neither value contains glob metacharacters, so `set -f` is not needed. If a
# future edit ever puts a path or other user-controlled value into this
# variable, it MUST be re-quoted).
EXTRACT_FLAGS="--extract"
[ "$FLAT_CYBORG_RESULT_FILE" = "0" ] || EXTRACT_FLAGS="--extract --extract-structural"
# shellcheck disable=SC2086 # intentional word-splitting: fixed literal, no metacharacters
flat-cyborg $EXTRACT_FLAGS --no-jitter --auto-approve --wrap-input 72 \
  --idle-ms "${FLAT_CYBORG_IDLE_MS:-30000}" \
  --timeout-ms "${FLAT_CYBORG_TIMEOUT_MS:-240000}" \
  --cmd-file "$PROMPT_FILE" -- claude --model "${CLAUDE_REASONING_MODEL:-sonnet}" --settings "$EFFORT_SETTINGS" > "$REPLY_FILE" &
FC_PID=$!
wait "$FC_PID"
FC_RC=$?
set -e
# Prefer the result-file channel: if claude wrote a non-empty reply there, that
# is authoritative — even when flat-cyborg exited non-zero (an idle/timeout that
# still produced the answer; claude's Write is atomic so a non-empty file is a
# complete reply, not a partial one). Only when the file is empty do we fall back
# to the screen-scrape reply, and only then does a flat-cyborg failure propagate.
if [ -s "$RESULT_FILE" ] && grep -q '[^[:space:]]' "$RESULT_FILE"; then
    python3 "$SCRIPT_DIR/flat-cyborg-unwrap.py" < "$RESULT_FILE"
    exit 0
fi
[ "$FC_RC" -eq 0 ] || exit "$FC_RC"
python3 "$SCRIPT_DIR/flat-cyborg-unwrap.py" < "$REPLY_FILE"
