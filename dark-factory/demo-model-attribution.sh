#!/usr/bin/env bash
# demo-model-attribution.sh — the OFFLINE, CI-safe gate for model-attribution.py (#2157, milestone D3, epic
# #2130). model-attribution.py reads persisted Claude Code transcripts and reports, per STAGE, which model
# answered each request and whether a silent Fable->Opus fallback fired — the honesty check that proves the D3
# analysis stages ran on Fable (a fallback voids any Fable-capability claim).
#
# This demo runs the tool's own deterministic --self-test over the checked-in fixture transcripts
# (bench/corpus-bench/fixtures/model-attribution/) and independently re-asserts the load-bearing counts from
# the rendered table, so a regression in either the tool or the fixture fails the lint. NO network / LLM /
# forge — pure python3 + local files.
#
# Usage:  dark-factory/demo-model-attribution.sh
# Exit: 0 = all assertions held; non-zero = a regression. POSIX sh / dash-safe: literal glyphs only.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ATTR="$HERE/bench/corpus-bench/model-attribution.py"
FXDIR="$HERE/bench/corpus-bench/fixtures/model-attribution"

FAILS=0
note() { echo "demo-model-attribution.sh: $*"; }
ok()   { echo "  [PASS] $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

command -v python3 >/dev/null 2>&1 || { note "[SKIP] python3 not installed"; exit 0; }
[ -f "$ATTR" ] || { note "model-attribution.py not found: $ATTR" >&2; exit 3; }
for s in analysis-fable analysis-tainted poc-opus; do
  [ -d "$FXDIR/$s" ] || { note "fixture stage dir missing: $FXDIR/$s" >&2; exit 3; }
done

note "1) model-attribution.py --self-test holds over the checked-in fixture transcripts ..."
if python3 "$ATTR" --self-test >/dev/null 2>&1; then
  ok "model-attribution.py --self-test passed"
else
  bad "model-attribution.py --self-test FAILED"
  python3 "$ATTR" --self-test 2>&1 | sed 's/^/      /' >&2
fi

note "2) independent re-assertion of the rendered per-stage table ..."
TABLE="$(python3 "$ATTR" --dir "$FXDIR" 2>/dev/null)"

# _row <stage> -> the tab-separated table row for that stage.
_row() { printf '%s\n' "$TABLE" | awk -F'\t' -v s="$1" '$1==s {print; found=1} END{ if(!found) exit 1 }'; }

# analysis-fable: 3 requests, all Fable, 0 fallback -> PURE-FABLE (the D1 headline stays clean).
R="$(_row analysis-fable)"
if [ "$R" = "$(printf 'analysis-fable\t3\t3\t0\t0\t0\t0\tPURE-FABLE')" ]; then
  ok "analysis-fable: 3 requests, all Fable, no fallback -> PURE-FABLE"
else
  bad "analysis-fable row drifted: '$R'"
fi

# analysis-tainted: 2 requests, 1 Fable + 1 Opus via a fallback block, 1 fallback -> CONTAMINATED.
R="$(_row analysis-tainted)"
if [ "$R" = "$(printf 'analysis-tainted\t2\t1\t1\t0\t1\t0\tCONTAMINATED')" ]; then
  ok "analysis-tainted: a silent Fable->Opus fallback is flagged (fable=1 opus=1 fallback=1 -> CONTAMINATED)"
else
  bad "analysis-tainted row drifted: '$R'"
fi

# poc-opus: 2 requests, all Opus, 0 fallback -> PURE-OPUS (the D2 PoC step, honestly Opus).
R="$(_row poc-opus)"
if [ "$R" = "$(printf 'poc-opus\t2\t0\t2\t0\t0\t0\tPURE-OPUS')" ]; then
  ok "poc-opus: 2 requests, all Opus, no fallback -> PURE-OPUS"
else
  bad "poc-opus row drifted: '$R'"
fi

# The TOTAL row aggregates all three stages (7 requests, 4 Fable, 3 Opus, 1 fallback).
R="$(_row TOTAL)"
if [ "$R" = "$(printf 'TOTAL\t7\t4\t3\t0\t1\t0\t-')" ]; then
  ok "TOTAL aggregates the three stages (7 req, 4 Fable, 3 Opus, 1 fallback)"
else
  bad "TOTAL row drifted: '$R'"
fi

if [ "$FAILS" -eq 0 ]; then
  note "PASS — model-attribution.py attributes each request per stage and flags the silent Fable->Opus fallback"
  exit 0
fi
note "FAIL — $FAILS assertion(s) regressed" >&2
exit 1
