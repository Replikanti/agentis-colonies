#!/usr/bin/env sh
# claude-p.sh — agentis llm.command backend that drives Claude Code in
# PRINT mode (`claude -p`). Non-interactive => clean single-shot stdout
# (no TUI screen-scrape, no line-wrap), billed against the flat-rate Claude
# subscription (same ~/.claude creds as interactive). Used by the
# trading-binance replay because flat-cyborg's --extract-structural scrape
# is unreliable for the strategist's structured JSON (#1163; cf #1152
# which routed code-gen to claude -p for the same fidelity reason).
# Prompt from "$1", falling back to stdin; reply on stdout.
set -eu
PROMPT="${1:-}"
if [ -z "$PROMPT" ]; then PROMPT="$(cat)"; fi
exec claude -p "$PROMPT"
