#!/usr/bin/env bash
# run-verify-citations.sh — plumbing only for tools/verify-citations.ag.
#
# Deliberately thin: this script decides NOTHING. It resolves paths, runs the
# agent from the configured colony dir (whose .agentis/config carries the
# exec.env_passthrough allowlist install.sh writes), and turns the agent's
# verdict marker into an exit code. Every judgement about what counts as a
# valid citation lives in the .ag, per the federation's .ag-first rule.
#
# Usage: tools/run-verify-citations.sh [bibliography.tsv]
# Exit:  0 all citations verified · 1 verification failed · 2 not installed

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR="$(dirname "$HERE")"
COLONY="$GR/baseline"

if [ ! -d "$COLONY/.agentis" ]; then
    echo "verify-citations: $COLONY/.agentis missing — run ./install.sh first" >&2
    exit 2
fi

GR_BIBLIOGRAPHY="${1:-${GR_BIBLIOGRAPHY:-$GR/doc/track2-bibliography.tsv}}"
if [ ! -s "$GR_BIBLIOGRAPHY" ]; then
    echo "verify-citations: bibliography not found or empty: $GR_BIBLIOGRAPHY" >&2
    exit 2
fi
export GR_BIBLIOGRAPHY

GR_VERIFY_MARKER="$(mktemp)"
export GR_VERIFY_MARKER
cleanup() { rm -f "$GR_VERIFY_MARKER"; }
trap cleanup EXIT

cd "$COLONY"
agentis go ../tools/verify-citations.ag --enable-exec

# The agent wrote the verdict; the shell only reports it. A missing marker means
# the agent died before deciding, which is a failure, not a pass.
[ "$(cat "$GR_VERIFY_MARKER" 2>/dev/null || true)" = "ok" ]
