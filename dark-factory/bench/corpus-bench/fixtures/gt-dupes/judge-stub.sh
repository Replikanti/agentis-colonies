#!/bin/sh
# judge-stub.sh — the offline SCORING judge backend for the #1840 GT-equivalence fixture. It stands in for the
# flat-cyborg-driven model in mech-judge.sh: it reads score-match.py's canonical request JSON on stdin and
# emits the canned `VERDICT|` lines a correct mechanism judge would produce on this fixture. Deterministic,
# no LLM / network.
#
# It reproduces the #1840 DEFECT exactly as recorded on a real judged run: the judge is asked for at most ONE
# MATCH per candidate, so a lead that describes a bug the ground truth accepted TWICE credits only the twin
# the model happened to name.
#   L0  src/Router.sol:joinAndDeposit  -> MATCH D-1 ONLY  (D-2 is the SAME bug, described differently and
#                                          found by far fewer watsons — it is the rare twin that gets lost)
#   L1  src/Vault.sol:settleEpoch      -> MATCH D-4       (name-COINCIDENT control: the lead shares
#                                          settleEpoch with D-3 but describes D-4's mechanism)
# An unknown lead gets NO canned decision — the stub stays silent rather than inventing one, which the scorer
# records as a JUDGE-ERROR.
#
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u

req="$(cat)"

case "$req" in
  *joinAndDeposit*)
    echo "VERDICT|L0|D-1|MATCH|94|same capped-deposit truncation and the same unrefunded remainder left in the shared router"
    ;;
  *settleEpoch*)
    echo "VERDICT|L1|D-4|MATCH|89|describes the zero-length-epoch queue skip, not the stale settlement price it shares a function name with"
    ;;
esac
exit 0
