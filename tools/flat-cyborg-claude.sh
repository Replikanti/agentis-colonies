#!/usr/bin/env sh
# flat-cyborg-claude.sh — the agentis `llm.command` CLI backend for the
# dev-apprenticeship federation: drives the INTERACTIVE Claude Code session
# through flat-cyborg's PTY wrapper (uses the Claude Code subscription, NOT the
# metered `claude -p` API path). agentis invokes the configured llm.command with
# the prompt as a trailing positional arg; this wrapper takes the prompt from
# "$1" (falling back to stdin) and returns only the model's reply on stdout
# (flat-cyborg --extract).
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
# Knobs (env vars): FLAT_CYBORG_IDLE_MS, FLAT_CYBORG_TIMEOUT_MS.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then PROMPT="$(cat)"; fi
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
trap 'rm -f "$REPLY_FILE" "$PROMPT_FILE"' EXIT
set +e
flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 \
  --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" \
  --timeout-ms "${FLAT_CYBORG_TIMEOUT_MS:-180000}" \
  --cmd-file "$PROMPT_FILE" -- claude > "$REPLY_FILE"
FC_RC=$?
set -e
[ "$FC_RC" -eq 0 ] || exit "$FC_RC"
python3 "$SCRIPT_DIR/flat-cyborg-unwrap.py" < "$REPLY_FILE"
