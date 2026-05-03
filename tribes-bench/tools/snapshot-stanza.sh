#!/bin/bash
# snapshot-stanza.sh — Stage 2 M3 (#394) periodic snapshot writer.
#
# Emits the 7-section header-stanza form (plan Decision 3) on stdout
# from a hermetic .agentis/ root + bug-ledger + market-csv. Used by
# `tools/run-stage2.sh` and `tools/run-baseline.sh` periodic snapshots.
#
# All probes swallow stderr; missing inputs degrade to empty under each
# stanza header. The script never fails — caller is expected to redirect
# stdout to `<run>/snapshots/<elapsed>.txt` and ignore exit status.
#
# Usage:
#   snapshot-stanza.sh <run-dir> <elapsed_s>
#
# Output sections (fixed order):
#   ## daemon-list           agentis daemon list --json
#   ## experience-counts     wc -l per .agentis/experience/*.jsonl
#   ## spend-counts          wc -l per .agentis/spend/*.jsonl
#   ## bug-ledger            wc -l of bug-ledger.jsonl
#   ## market-csv            wc -l of knowledge-market.csv
#   ## reputation-memos      agentis memo get for every tribe-* memo key
#   ## per-tribe-cb          agentis memo get tribe-<x>:pool

set -u

RUN_DIR="${1:-}"
ELAPSED="${2:-}"

if [ -z "$RUN_DIR" ] || [ -z "$ELAPSED" ]; then
    echo "Usage: snapshot-stanza.sh <run-dir> <elapsed_s>" >&2
    exit 2
fi

AGENTIS_ROOT="$RUN_DIR/.agentis"
BUG_LEDGER="$RUN_DIR/bug-ledger.jsonl"
MARKET_CSV="$RUN_DIR/knowledge-market.csv"

# Run agentis subcommands with AGENTIS_ROOT bound + cwd at RUN_DIR so the
# memo store resolved is the per-run hermetic one, not the operator's.
export AGENTIS_ROOT

echo "# snapshot at elapsed=${ELAPSED}s"
date -u +%Y-%m-%dT%H:%M:%SZ

echo ""
echo "## daemon-list"
(cd "$RUN_DIR" 2>/dev/null && agentis daemon list --json 2>/dev/null) || true

echo ""
echo "## experience-counts"
if [ -d "$AGENTIS_ROOT/experience" ]; then
    for f in "$AGENTIS_ROOT/experience"/*.jsonl; do
        [ -f "$f" ] || continue
        n="$(wc -l < "$f" 2>/dev/null || echo 0)"
        printf '%s %s\n' "$n" "$(basename "$f")"
    done
fi

echo ""
echo "## spend-counts"
if [ -d "$AGENTIS_ROOT/spend" ]; then
    for f in "$AGENTIS_ROOT/spend"/*.jsonl; do
        [ -f "$f" ] || continue
        n="$(wc -l < "$f" 2>/dev/null || echo 0)"
        printf '%s %s\n' "$n" "$(basename "$f")"
    done
fi

echo ""
echo "## bug-ledger"
if [ -f "$BUG_LEDGER" ]; then
    n="$(wc -l < "$BUG_LEDGER" 2>/dev/null || echo 0)"
    printf '%s bug-ledger.jsonl\n' "$n"
fi

echo ""
echo "## market-csv"
if [ -f "$MARKET_CSV" ]; then
    n="$(wc -l < "$MARKET_CSV" 2>/dev/null || echo 0)"
    printf '%s knowledge-market.csv\n' "$n"
fi

echo ""
echo "## reputation-memos"
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon tribe-baseline; do
    val="$(cd "$RUN_DIR" 2>/dev/null && agentis memo get "reputation:tribes-bench-${tribe}" 2>/dev/null || true)"
    if [ -n "$val" ]; then
        printf '%s = %s\n' "reputation:tribes-bench-${tribe}" "$val"
    fi
done

echo ""
echo "## per-tribe-cb"
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon tribe-baseline; do
    val="$(cd "$RUN_DIR" 2>/dev/null && agentis memo get "tribe-${tribe}:pool" 2>/dev/null || true)"
    if [ -n "$val" ]; then
        printf '%s = %s\n' "tribe-${tribe}:pool" "$val"
    fi
done
