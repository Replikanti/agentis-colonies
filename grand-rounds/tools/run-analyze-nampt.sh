#!/usr/bin/env bash
# run-analyze-nampt.sh — plumbing only for tools/analyze-nampt.ag.
# Fetches/narrows the DepMap matrix if needed, runs the agent, maps its verdict
# marker to an exit code. Decides nothing itself.
#
# Exit: 0 verdict reached and matched the report · 1 refused or contradicted
#       the report · 2 not installed / no data
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GR="$(dirname "$HERE")"
COLONY="$GR/baseline"
TSV="${GR_NAMPT_TSV:-$GR/doc/depmap-nampt.tsv}"

[ -d "$COLONY/.agentis" ] || { echo "run-analyze-nampt: run ./install.sh first" >&2; exit 2; }
[ -s "$TSV" ] || "$HERE/fetch-depmap-nampt.sh" "$TSV"
[ -s "$TSV" ] || { echo "run-analyze-nampt: no data at $TSV" >&2; exit 2; }

GR_NAMPT_TSV="$(realpath "$TSV")"; export GR_NAMPT_TSV
GR_VERIFY_MARKER="$(mktemp)"; export GR_VERIFY_MARKER
trap 'rm -f "$GR_VERIFY_MARKER"' EXIT

cd "$COLONY"
agentis go ../tools/analyze-nampt.ag --enable-exec
[ "$(cat "$GR_VERIFY_MARKER" 2>/dev/null || true)" = "ok" ]
