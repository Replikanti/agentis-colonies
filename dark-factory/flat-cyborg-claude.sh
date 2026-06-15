#!/usr/bin/env sh
# flat-cyborg-claude.sh — $0 LLM backend for agentis prompt(): drives the
# INTERACTIVE claude CLI through flat-cyborg's PTY wrapper (uses the Claude Code
# subscription session, NOT the metered `claude -p` API path). agentis invokes
# the configured llm.command with the prompt as a trailing positional arg; this
# wrapper takes the prompt from "$1" (falling back to stdin) and returns only the
# model's reply on stdout (flat-cyborg --extract).
#
# Config (run-audit.sh and siblings): set
#   llm.command = <abs path to this script>
#   llm.args    =                       (empty — the prompt is the sole arg)
set -eu
PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then PROMPT="$(cat)"; fi
# --wrap-input 72: fold the (often single-line, ~700-char) instruction block so it
# does not overflow claude's editor input. flat-cyborg >=0.10.0 also gates --extract
# on the reply sentinel, so a slow first reply is no longer captured as empty.
exec flat-cyborg --extract --no-jitter --auto-approve --wrap-input 72 \
  --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" \
  --timeout-ms "${FLAT_CYBORG_TIMEOUT_MS:-180000}" \
  --cmd "$PROMPT" -- claude
