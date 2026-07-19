#!/usr/bin/env bash
# demo-generation-recall.sh — proof of the #1730 GENERATION-recall harness.
#
# The corpus bench (run-corpus-bench.sh) scores the pipeline's POST-CONFIRMATION verified findings against
# ground truth, and the #1713 A/B measures the deep-hunt recall delta ON vs OFF — but neither isolates the
# GENERATION step: of the GT bugs the pipeline never submitted, how many did it actually NAME (a breadth
# candidate or a generated invariant) but then fail to CONFIRM? #1730 adds generation-recall.sh, which scores
# the GENERATOR's hypotheses against GT by projecting the two generation artifacts a run already stages — the
# breadth hunter's pre-refute candidates and the deep-hunt lens's `INVARIANT|<file:fn>|<verdict>` targets
# (verdict IGNORED) — through a thin adapter (hypotheses-to-leads.py) into the lead shape the FROZEN
# score-match.py consumes. Generation-recall > verified-recall exposes the #1716 expressiveness gap: a CLEAN
# invariant that NAMED a real bug is a generation HIT the fuzzer dropped.
#
# This demo has TWO parts (both CI-safe; no forge/LLM, forge is not even needed — the harness scores existing
# artifacts, unlike the forge-gated invariant demos):
#   1) SOURCE-GUARD (always): the harness references the reused extract-gt.sh + score-match.py + the adapter;
#      the adapter DISCARDS the fuzzer verdict; the generation-minus-verified DELTA path is wired; and both
#      the harness and this demo SKIP cleanly (exit 0) when python3 is absent.
#   2) BEHAVIOURAL (when python3 is present): run generation-recall.sh --self-test and assert exit 0 + that
#      generation-recall exceeds verified-recall on the fixture (the delta the harness exists to measure).
#
# Usage:  dark-factory/demo-generation-recall.sh
# Exit: 0 = all assertions hold (SKIPs cleanly when python3 is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
HARNESS="$CB/generation-recall.sh"
ADAPTER="$CB/hypotheses-to-leads.py"
FIX="$CB/fixtures/generation-recall"

FAILS=0
note() { echo "demo-generation-recall.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$HARNESS" ] || { note "harness not found: $HARNESS" >&2; exit 3; }
[ -f "$ADAPTER" ] || { note "adapter not found: $ADAPTER" >&2; exit 3; }
for f in discovery-results.merged.json invariant-targets.txt truth.tsv verified_findings.json expected-leads.json expected-scorecard.txt; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD — the harness/adapter wiring (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1730 harness + adapter wiring ..."

if grep -q 'extract-gt.sh' "$HARNESS" && grep -q 'score-match.py' "$HARNESS" && grep -q 'hypotheses-to-leads.py' "$HARNESS"; then
  ok "generation-recall.sh reuses extract-gt.sh's truth.tsv + the frozen score-match.py + the hypotheses-to-leads.py adapter"
else
  bad "generation-recall.sh does not reference the reused extract-gt.sh / score-match.py / adapter"
fi

if grep -qiE 'verdict (is )?(ignored|discarded)' "$ADAPTER"; then
  ok "hypotheses-to-leads.py DISCARDS the fuzzer verdict (a CLEAN invariant that NAMES a bug still counts)"
else
  bad "hypotheses-to-leads.py does not document discarding the fuzzer verdict"
fi

if grep -q 'generation-minus-verified' "$HARNESS" || grep -qi 'generation.*verified.*DELTA' "$HARNESS"; then
  ok "generation-recall.sh wires the generation-minus-verified DELTA (the #1716 expressiveness gap)"
else
  bad "generation-recall.sh missing the generation-minus-verified delta path"
fi

if grep -q '\[SKIP\] python3 not installed' "$HARNESS"; then
  ok "generation-recall.sh SKIPs cleanly (exit 0) when python3 is absent (CI-safe)"
else
  bad "generation-recall.sh missing the SKIP-without-python3 path"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL — run the self-test (SKIP cleanly without python3, exactly like the harness).
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not on PATH — install python3 to run the generation-recall self-test"
else
  note "running generation-recall.sh --self-test (behavioural) ..."
  st_out="$("$HARNESS" --self-test 2>&1)"; st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "generation-recall.sh --self-test PASSED (exit 0)"
  else
    bad "generation-recall.sh --self-test FAILED (exit $st_rc)"
    printf '%s\n' "$st_out" | sed 's/^/         | /' | tail -20
  fi
  # The delta the harness exists to measure: generation-recall > verified-recall on the fixture.
  if printf '%s\n' "$st_out" | grep -q 'generation-recall (.*) > verified-recall'; then
    ok "generation-recall exceeds verified-recall on the fixture (the CLEAN-invariant-named-but-dropped delta)"
  else
    bad "the self-test did not assert generation-recall > verified-recall"
    printf '%s\n' "$st_out" | sed 's/^/         | /' | tail -20
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1730 generation-recall harness is wired — it reuses the UNCHANGED extract-gt.sh + score-match.py"
  note "      through the hypotheses-to-leads.py adapter, DISCARDS the fuzzer verdict when projecting invariant"
  note "      targets, and reports the generation-minus-verified DELTA; the self-test proves generation-recall"
  note "      exceeds verified-recall on the fixture, and both harness + demo SKIP cleanly without python3."
  exit 0
fi
note "DEMO FAILED — a #1730 generation-recall assertion did not hold" >&2
exit 1
