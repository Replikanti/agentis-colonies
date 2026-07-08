#!/usr/bin/env bash
# claude-p-backend.sh — the reliable real-backend adapter for the capability bench's --live devise stage (#1495).
#
# agentis's `llm.command` "cli" contract IS `claude -p`-shaped: `agentis go` invokes the command as
# `<cmd> -p --output-format json` with the prompt on STDIN. So the simplest reliable backend for a one-shot
# bench measurement is `claude -p` itself: it reads the prompt from stdin, returns the `--output-format json`
# envelope agentis parses, and uses the logged-in Claude Code session — no flat-cyborg PTY (whose one-shot
# cold-start / result-file / extract paths proved flaky and could hang a standalone run for minutes).
#
# This adapter ignores whatever argv agentis passes (it re-specifies -p/--output-format/--model itself) and
# forwards STDIN — the prompt — straight to claude. Model is $BENCH_LLM_MODEL (default `opus`, to measure the
# DEVISE ceiling; override to `sonnet` for the federation-routing tier).
#
# Requires: `claude` (Claude Code CLI) on PATH + a logged-in ~/.claude. The bench SKIPs stage 2 when absent.
set -u
MODEL="${BENCH_LLM_MODEL:-opus}"
CLAUDE="${BENCH_CLAUDE_BIN:-claude}"
exec "$CLAUDE" -p --output-format json --model "$MODEL"
