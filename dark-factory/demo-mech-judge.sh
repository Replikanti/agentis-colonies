#!/usr/bin/env bash
# demo-mech-judge.sh — proof of the #1829 SEMANTIC MECHANISM JUDGE scoring mode.
#
# The corpus bench decides "did the hunter find this ground-truth bug?" with score-match.py's location-first
# token matcher (#1697): a lead HITs a truth row when the lead's file basename AND function name both occur in
# that row's prose. That ruler is wrong in BOTH directions, which is what #1829 reports:
#   * NAME-DIVERGENT TRUE MATCH is missed — the hunter names the factory/getter that actually contains the
#     faulty code while the report's prose anchors elsewhere and never names that function.
#   * NAME-COINCIDENT FALSE MATCH is credited — a candidate shares a function name with a row while describing
#     a completely different mechanism.
# The fix is a semantic judge that decides ROOT CAUSE + MECHANISM identity instead of name co-occurrence. It is
# an OPT-IN mode of the same scorer (`--judge off|cache|cmd`, default `off`) so the frozen #1697 ruler is
# untouched, and in judge mode the judge is AUTHORITATIVE — there is no silent fallback to the token matcher,
# because a fallback would re-import exactly the two bugs above.
#
# This demo has TWO parts (both CI-safe: no forge, no LLM, no network — the judge runs against a recorded
# decision cache and an offline stub):
#   1) SOURCE-GUARD (always): mech-judge.sh judges through the flat-cyborg PTY wrapper and never through the
#      metered print-mode API; score-match.py defaults to --judge off; and the judge path never consults
#      lead_matches_row (no token fallback).
#   2) BEHAVIOURAL (when python3 is present): on ONE synthetic fixture, the token matcher's WRONG answer and
#      the judge's RIGHT answer are both pinned byte-exactly — 1/4 with the one hit on the wrong row vs 3/4
#      all-correct — and the fail-closed paths hold (a malformed judge reply fabricates no MATCH and raises
#      the JUDGE-ERROR count; a degraded judge aborts with exit 4; a --judge cache miss exits 4).
#
# Usage:  dark-factory/demo-mech-judge.sh
# Exit: 0 = all assertions hold (SKIPs cleanly when python3 is absent) ; 1 = a regression ; 3 = missing fixture.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
SCOREMATCH="$CB/score-match.py"
JUDGE="$CB/mech-judge.sh"
FIX="$CB/fixtures/mech-judge"
STUB="$FIX/judge-stub.sh"

FAILS=0
note() { echo "demo-mech-judge.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$SCOREMATCH" ] || { note "scorer not found: $SCOREMATCH" >&2; exit 3; }
[ -f "$JUDGE" ]      || { note "judge driver not found: $JUDGE" >&2; exit 3; }
for f in truth.tsv leads.json judge-stub.sh judge-decisions.jsonl expected-scorecard.token.txt expected-scorecard.judge.txt; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the judge wiring (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1829 mechanism-judge wiring ..."

if grep -q 'MECH_JUDGE_LLM_CMD' "$JUDGE" && grep -q 'flat-cyborg-claude.sh' "$JUDGE"; then
  ok "mech-judge.sh drives the flat-cyborg PTY wrapper (MECH_JUDGE_LLM_CMD indirection, flat-rate session)"
else
  bad "mech-judge.sh does not route its LLM path through the flat-cyborg wrapper"
fi

# Only NON-COMMENT lines count: the header legitimately explains why the metered print-mode API is not used.
if grep -vE '^[[:space:]]*#' "$JUDGE" | grep -qE 'claude[[:space:]]+-p'; then
  bad "mech-judge.sh shells out to the metered print-mode API instead of the flat-cyborg wrapper"
else
  ok "mech-judge.sh never invokes the metered print-mode API (subscription-billed judging only)"
fi

if grep -q 'judge_mode = "off"' "$SCOREMATCH"; then
  ok "score-match.py defaults to --judge off (the frozen #1697 token matcher stays the default ruler)"
else
  bad "score-match.py does not default --judge to off"
fi

# No token fallback in judge mode: lead_matches_row() must be defined once and called once, and that ONE call
# site must live in the `judge_mode == "off"` branch — never inside run_judge().
lmr_refs="$(grep -vE '^[[:space:]]*#' "$SCOREMATCH" | grep -c 'lead_matches_row(')"
judge_body="$(awk '/^def run_judge\(/{f=1} f && /^def [a-z_]+\(/ && !/^def run_judge\(/{f=0} f' "$SCOREMATCH")"
if [ "$lmr_refs" -eq 2 ] && ! printf '%s\n' "$judge_body" | grep -q 'lead_matches_row'; then
  ok "the judge path never consults lead_matches_row — no silent fallback to the token matcher"
else
  bad "lead_matches_row is reachable from the judge path (refs=$lmr_refs) — the judge must be authoritative"
fi

if grep -q 'JUDGE-ERROR' "$SCOREMATCH" && grep -q 'judge-max-error-rate' "$SCOREMATCH"; then
  ok "an unparseable reply is a JUDGE-ERROR and a degraded judge aborts above --judge-max-error-rate"
else
  bad "score-match.py is missing the JUDGE-ERROR / max-error-rate fail-closed path"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL — the acceptance regression, pinned byte-exactly on one fixture.
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not on PATH — install python3 to run the mechanism-judge scoring assertions"
else
  note "running the token-vs-judge scoring regression on fixtures/mech-judge/ ..."

  # (a) the DOCUMENTED DEFECT: the token matcher scores 1/4 and its single hit is on the WRONG row.
  TOK="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" 2>/dev/null)"
  if [ "$TOK" = "$(cat "$FIX/expected-scorecard.token.txt")" ]; then
    ok "(a) --judge off reproduces the pinned TOKEN scorecard (1/4, and the one HIT is the name-coincident FP)"
  else
    bad "(a) the token scorecard changed — the frozen #1697 matcher must stay byte-identical"
    diff <(printf '%s\n' "$TOK") "$FIX/expected-scorecard.token.txt" >&2 || true
  fi

  # (b) --judge cache: replaying the recorded decisions fixes BOTH directions (3/4, all correct).
  CACHED="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
              --judge cache --judge-cache "$FIX/judge-decisions.jsonl" 2>/dev/null)"
  if [ "$CACHED" = "$(cat "$FIX/expected-scorecard.judge.txt")" ]; then
    ok "(b) --judge cache reproduces the pinned JUDGE scorecard (3/4: the two name-divergent true matches are"
    echo "         credited and the name-coincident false match is rejected)"
  else
    bad "(b) the --judge cache scorecard DIFFERS from expected-scorecard.judge.txt"
    diff <(printf '%s\n' "$CACHED") "$FIX/expected-scorecard.judge.txt" >&2 || true
  fi

  # (c) --judge cmd over the offline stub must produce the SAME scorecard as the recorded replay: the recorded
  #     raw reply is authoritative, so a live-judged run is exactly reproducible offline.
  LIVE="$(python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" --judge cmd --judge-cmd "$STUB" 2>/dev/null)"
  if [ "$LIVE" = "$CACHED" ]; then
    ok "(c) --judge cmd (offline stub driver) and --judge cache agree byte-for-byte — a judged run replays"
  else
    bad "(c) --judge cmd and --judge cache disagree — a judged number would not be reproducible"
    diff <(printf '%s\n' "$LIVE") <(printf '%s\n' "$CACHED") >&2 || true
  fi

  # (d) a malformed judge reply fabricates NO match and is counted as a JUDGE-ERROR (never a silent NO-MATCH).
  MAL="$(MECH_JUDGE_STUB_MODE=malformed python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
           --judge cmd --judge-cmd "$STUB" --judge-max-error-rate 100 2>/dev/null)"
  if ! printf '%s\n' "$MAL" | grep -q 'HIT' && printf '%s\n' "$MAL" | grep -qE '^JUDGE	[0-9]+	[1-9][0-9]*$'; then
    ok "(d) an unparseable judge reply yields NO hit and a nonzero JUDGE error count (fail-closed)"
  else
    bad "(d) a malformed judge reply did not fail closed"
    printf '%s\n' "$MAL" | sed 's/^/         | /' | head -8
  fi

  # (e) a degraded judge must NOT publish a plausible-looking low recall: over the max error rate -> exit 4.
  MECH_JUDGE_STUB_MODE=malformed python3 "$SCOREMATCH" "$FIX/truth.tsv" "$FIX/leads.json" \
    --judge cmd --judge-cmd "$STUB" >/dev/null 2>&1 && deg_rc=0 || deg_rc=$?
  if [ "$deg_rc" -eq 4 ]; then
    ok "(e) a judge over --judge-max-error-rate aborts with exit 4 instead of reporting a degraded recall"
  else
    bad "(e) expected exit 4 from a degraded judge, got $deg_rc"
  fi

  # (f) --judge cache is deterministic BECAUSE a miss is fatal: it never silently falls back to anything.
  python3 "$SCOREMATCH" "$CB/fixtures/score/truth.tsv" "$CB/fixtures/score/verified_findings.json" \
    --judge cache --judge-cache "$FIX/judge-decisions.jsonl" >/dev/null 2>&1 && miss_rc=0 || miss_rc=$?
  if [ "$miss_rc" -eq 4 ]; then
    ok "(f) a --judge cache MISS exits 4 (a replay never invents a decision, and never falls back to tokens)"
  else
    bad "(f) expected exit 4 from a --judge cache miss, got $miss_rc"
  fi

  # (g) the driver's own contract self-test (mock round-trip, flat-cyborg-only path, no fabricated MATCH).
  "$JUDGE" --self-test >/dev/null 2>&1 && st_rc=0 || st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "(g) mech-judge.sh --self-test PASSED (driver contract: request -> VERDICT| lines, flat-cyborg only)"
  else
    bad "(g) mech-judge.sh --self-test FAILED (exit $st_rc)"
    "$JUDGE" --self-test 2>&1 | sed 's/^/         | /' | tail -10
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1829 semantic mechanism judge is wired as an OPT-IN score-match.py mode. --judge off keeps"
  note "      the frozen #1697 token matcher byte-identical; --judge cache/cmd replaces it with a root-cause +"
  note "      mechanism decision that credits the name-divergent true matches and rejects the name-coincident"
  note "      false match on the same fixture (1/4 wrong -> 3/4 right). The judge is AUTHORITATIVE — no token"
  note "      fallback — and fails CLOSED: an unparseable reply is a JUDGE-ERROR, a degraded judge or a cache"
  note "      miss exits 4, and every judging call goes through the flat-cyborg subscription wrapper."
  exit 0
fi
note "DEMO FAILED — a #1829 mechanism-judge assertion did not hold" >&2
exit 1
