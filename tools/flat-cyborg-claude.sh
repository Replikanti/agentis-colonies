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
exec flat-cyborg --extract --extract-structural --no-jitter --auto-approve --wrap-input 72 \
  --idle-ms "${FLAT_CYBORG_IDLE_MS:-8000}" \
  --timeout-ms "${FLAT_CYBORG_TIMEOUT_MS:-180000}" \
  --cmd "$PROMPT" -- claude
