#!/usr/bin/env bash
# demo-pointed-ladder.sh — proof of the #2311 pointed-ladder diagnostic classifier
# (bench/corpus-bench/ladder-classify.py).
#
# #2311 classifies every rare row the held-out sets missed as LOCATION (reached once the hunter is pointed at the
# function), EXECUTION (only the pointed STAGE 4.5 deep hunt reaches it), HINT (only an L1 / L2 hint reaches it) or
# MECHANISM (nothing reaches it), and picks the next lever from the counts under a pre-registered rule.
# ladder-classify.py does the mechanical part: the hint-leak gate before any run, the per-arm scorer, and the
# precedence + decision rule after the runs. Pointed runs are an upper bound on reach, never recall.
#
# This demo has TWO parts (both CI-safe: no network, no LLM):
#   1) SOURCE-GUARD (always): ladder-classify.py IMPORTS score-match.py's judge request builder, reply parser and
#      judging loop (no local re-implementation, so a decision here is a score-match.py decision); it imports no
#      network module and nothing outside the stdlib; every output it writes carries the DIAGNOSTIC header and its
#      pinned fixture outputs carry no `%`; fixtures/ladder/ carries no absolute home path, no corpus.tsv contest
#      id (as a word) and no \xHH escape; the judge stub is executable and parses under `sh -n` (dash-safe CI).
#   2) BEHAVIOURAL (when python3 is present): `ladder-classify.py --self-test` reproduces the pinned table +
#      verdict from fixtures/ladder/ byte for byte (one row per class and sub-label), holds the three precedence
#      conflicts, all four verdict kinds (DOMINANT, a majority lost under the worst case, SELECTED by a lead >= 3,
#      SPLIT), the hint-gate exit codes 0 / 3 / 4 and the scorer over a synthetic pointed arm.
#
# Usage:  dark-factory/demo-pointed-ladder.sh
# Exit: 0 = all assertions hold (SKIPs the behavioural part cleanly when python3 is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
LC="$CB/ladder-classify.py"
FIX="$CB/fixtures/ladder"

FAILS=0
note() { echo "demo-pointed-ladder.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$LC" ] || { note "ladder-classify.py not found: $LC" >&2; exit 3; }
for f in inventory.tsv expected-table.md expected-verdict.txt judge-stub.sh hint-ladder.tsv truth/fx/truth.tsv; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #2311 ladder classifier ..."

if grep -q '"score-match.py"' "$LC" && grep -q 'spec_from_file_location' "$LC" \
   && grep -q 'sm\.judge_request(' "$LC" && grep -q 'sm\.parse_verdicts(' "$LC" && grep -q 'sm\.run_judge(' "$LC" \
   && ! grep -qE '^def (judge_request|parse_verdicts|run_judge|invoke_judge)\(' "$LC"; then
  ok "ladder-classify.py imports score-match.py's judge request / reply parser / judging loop (no local re-implementation)"
else
  bad "ladder-classify.py does not import score-match.py's judge, or re-defines part of it"
fi

imports="$(grep -E '^(import|from) ' "$LC" | awk '{ print $2 }' | sed 's/\..*//' | sort -u | paste -sd' ' -)"
if [ "$imports" = "importlib json os re shutil subprocess sys tempfile" ]; then
  ok "ladder-classify.py imports only the stdlib and no network module ($imports)"
else
  bad "ladder-classify.py import set changed: $imports"
fi

if grep -q '^HEADER = "DIAGNOSTIC: pointed upper bound, not recall"$' "$LC" \
   && head -1 "$FIX/expected-table.md" | grep -qF 'DIAGNOSTIC: pointed upper bound, not recall' \
   && head -1 "$FIX/expected-verdict.txt" | grep -qxF 'DIAGNOSTIC: pointed upper bound, not recall' \
   && ! grep -q '%' "$FIX/expected-table.md" "$FIX/expected-verdict.txt"; then
  ok "both pinned outputs open with the DIAGNOSTIC header and carry no % recall figure"
else
  bad "the DIAGNOSTIC header is missing or a % figure crept into the pinned outputs"
fi

home_hits="$(grep -rnIE '/home/|/Users/|/root/' "$FIX" 2>/dev/null || true)"
if [ -z "$home_hits" ]; then
  ok "fixtures/ladder/ carries no absolute home path"
else
  bad "absolute home path under fixtures/ladder/:"; printf '%s\n' "$home_hits" | sed "s|^$HERE/||" | head -5
fi

ids="$(grep -v '^#' "$CB/corpus.tsv" | cut -f1 | grep . | paste -sd'|' -)"
if [ -n "$ids" ]; then
  id_hits="$(grep -rnwiIE "$ids" "$FIX" "$LC" 2>/dev/null || true)"
  if [ -z "$id_hits" ]; then
    ok "fixtures/ladder/ + ladder-classify.py name no corpus.tsv contest ($(printf '%s\n' "$ids" | tr '|' '\n' | grep -c .) ids checked as words)"
  else
    bad "a corpus.tsv contest id appears in fixtures/ladder/ or ladder-classify.py:"; printf '%s\n' "$id_hits" | sed "s|^$HERE/||" | head -5
  fi
else
  bad "corpus.tsv yields no contest id — the contest-name guard checks nothing"
fi

if [ -x "$FIX/judge-stub.sh" ] && sh -n "$FIX/judge-stub.sh" \
   && ! grep -rnE '\\x[0-9A-Fa-f]{2}' "$FIX" > /dev/null 2>&1; then
  ok "the judge stub is executable and parses under sh -n; no \\xHH escape under fixtures/ladder/ (dash-safe CI)"
else
  bad "the judge stub is not executable / not sh-clean, or a \\xHH escape crept into fixtures/ladder/"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL (SKIP cleanly without python3).
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not installed — install python3 to run the ladder-classify.py self-test"
else
  note "running ladder-classify.py --self-test (behavioural) ..."
  st_out="$(python3 "$LC" --self-test 2>&1)"; st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "ladder-classify.py --self-test PASSED ($(printf '%s\n' "$st_out" | grep -c '\[OK\]') assertions: pinned table + verdict, precedence, four verdicts, hint-gate, scorer)"
  else
    bad "ladder-classify.py --self-test FAILED (exit $st_rc)"
    printf '%s\n' "$st_out" | grep -E '\[FAIL\]|ladder-classify.py:' | sed 's/^/         | /' | head -20
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #2311 classifier judges through score-match.py's own judge, reproduces the pinned per-row table"
  note "      and verdict (DIAGNOSTIC: pointed upper bound, not recall), and fails closed on a judge error."
  exit 0
fi
note "DEMO FAILED — a #2311 ladder-classifier assertion did not hold" >&2
exit 1
