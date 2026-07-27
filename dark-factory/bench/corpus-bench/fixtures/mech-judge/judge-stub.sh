#!/bin/sh
# judge-stub.sh — the ONE offline judge backend for the #1829 mechanism-judge fixture. It stands in for the
# flat-cyborg-driven model in mech-judge.sh: it reads score-match.py's canonical request JSON on stdin and
# emits the canned `VERDICT|` lines a correct mechanism judge would produce on this fixture. Deterministic,
# no LLM / network.
#
# It keys on the LEAD LOCATION substring, and the canned decisions encode exactly the two failure modes the
# token matcher gets wrong (documented in the corpus-bench README's mechanism-judge section):
#   L0  src/StrategyFactory.sol:newStrategy    -> MATCH S-1  (name-DIVERGENT true match: the GT prose anchors
#                                                 on Strategy.sol and never names the factory or newStrategy)
#   L1  src/Strategy.sol:estimatedTotalAssets  -> MATCH S-2  (same: the GT prose never names the getter)
#   L2  src/Leverager.sol:checkPoolActivity    -> MATCH S-4  (name-COINCIDENT false match rejected: the lead
#                                                 shares checkPoolActivity with S-3 but describes S-4's overflow)
# An unknown lead gets NO canned decision — the stub stays silent rather than inventing one, which the scorer
# records as a JUDGE-ERROR.
#
# MECH_JUDGE_STUB_MODE=malformed emits an unparseable prose reply instead, for the fail-closed assertion
# (a garbled judge must never become a MATCH, and must never be read as a silent NO-MATCH).
#
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u

req="$(cat)"

if [ "${MECH_JUDGE_STUB_MODE:-verdict}" = "malformed" ]; then
  echo "Looking at this candidate, it does seem related to the first ground-truth row,"
  echo "but I am not confident enough to commit to a structured decision right now."
  exit 0
fi

case "$req" in
  *StrategyFactory.sol*)
    echo "VERDICT|L0|S-1|MATCH|92|same first-depositor share-price inflation and the same donate-then-round-to-zero abuse, located in the factory the report never names"
    ;;
  *estimatedTotalAssets*)
    echo "VERDICT|L1|S-2|MATCH|88|same stale-reported-total root cause and the same deposit-before-the-loss-is-booked theft, read off the getter the report never names"
    ;;
  *checkPoolActivity*)
    echo "VERDICT|L2|S-4|MATCH|85|describes the uint16 tick-range narrowing overflow, not the activity-window misconfiguration it shares a function name with"
    ;;
esac
exit 0
