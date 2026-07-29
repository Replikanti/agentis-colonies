#!/bin/sh
# judge-stub.sh — the offline judge backend for the #1841 LOCATION-vs-GATE fixture. It stands in for the
# flat-cyborg-driven model in mech-judge.sh: it reads score-match.py's canonical request JSON on stdin and
# emits the canned `VERDICT|` lines a correct mechanism judge produces on this fixture. Deterministic, no LLM
# and no network.
#
# It reproduces the #1841 DEFECT exactly as recorded on a real judged run: the decision rule says divergent
# file/function names are NOT disqualifying, and the judge obeys that in the DECISION — but not in the
# CONFIDENCE, which it hedges into the 60s purely because the lead is anchored somewhere the ground-truth
# prose never names. At the old 70-point gate that hedge became a scored MISS.
#   L0  src/history/VaultV2.sol:queueDeposit -> MATCH G-1 at 64. The lead is anchored on the SUPERSEDED COPY
#                                          of the contract while G-1's prose anchors on the live one; the
#                                          root cause and the mechanism are the same, and the judge says so
#                                          in its reason while still hedging the number.
#   L1  src/Vault.sol:settleEpoch          -> NO-MATCH at 90. The #1829 guard, and the opposite direction:
#                                          the lead names G-3's EXACT file and function but describes a
#                                          different mechanism (missing caller/timestamp restriction, not the
#                                          stale settlement price). No gate value can credit it, because it
#                                          is excluded by the DECISION, not by the confidence.
#   L2  src/Vault.sol:redeem               -> MATCH G-2 at 91. Plain control: matching location, no hedge.
# An unknown lead gets NO canned decision — the stub stays silent rather than inventing one, which the scorer
# records as a JUDGE-ERROR.
#
# Keyed on the full `<file>:<function>:<line>` lead location, which is unique to the lead: a truth-row
# signature can repeat a file or a function name, never the line-anchored location.
#
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u

req="$(cat)"

case "$req" in
  *"src/history/VaultV2.sol:queueDeposit:88"*)
    echo "VERDICT|L0|G-1|MATCH|64|same hardcoded index-0 request slot and the same overwritten-deposit loss; the candidate is anchored on the superseded copy of the contract, which does not change the root cause"
    ;;
  *"src/Vault.sol:settleEpoch:140"*)
    echo "VERDICT|L1|NONE|NO-MATCH|90|shares the settleEpoch location with G-3 but describes a missing caller/timestamp restriction, not the stale cached settlement price"
    ;;
  *"src/Vault.sol:redeem:210"*)
    echo "VERDICT|L2|G-2|MATCH|91|same burn-before-supply-snapshot ordering and the same rounding paid out of the remaining holders"
    ;;
esac
exit 0
