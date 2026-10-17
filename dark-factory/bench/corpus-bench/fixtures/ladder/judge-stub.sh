#!/bin/sh
# judge-stub.sh — the offline judge backend for the #2311 ladder-classify.py self-test. It stands in for
# mech-judge.sh: it reads score-match.py's canonical request JSON on stdin and prints the `VERDICT|` line a correct
# mechanism judge would give on this fixture. Deterministic, no LLM / network. It keys on the lead text:
#   "pays out before burning"           -> MATCH  (an L1 hint that STATES the mechanism: the hint-gate LEAK)
#   "pays the exit before the share burn" -> MATCH  (the synthetic arm's breadth candidate)
#   "the exit is paid before the burn"  -> MATCH  (the synthetic arm's DISMISS line: the dismissed sub-label)
#   "sharesBackedByAssets violated"     -> MATCH  (the synthetic arm's STAGE 4.5 FINDING log)
#   anything else                       -> NO-MATCH
# LADDER_JUDGE_STUB_MODE=malformed prints prose with no verdict line (the fail-closed JUDGE-ERROR case).
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u
req="$(cat)"
if [ "${LADDER_JUDGE_STUB_MODE:-verdict}" = "malformed" ]; then
  echo "This hint reads close to the reported issue, but I will not commit to a structured decision."
  exit 0
fi
lid="$(printf '%s' "$req" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')"
sev="$(printf '%s' "$req" | sed -n 's/.*"sev_id":"\([^"]*\)".*/\1/p')"
case "$req" in
  *"pays out before burning"*|*"pays the exit before the share burn"*|*"the exit is paid before the burn"*|*"sharesBackedByAssets violated"*)
    echo "VERDICT|$lid|$sev|MATCH|90|stub: the same value-before-burn ordering and the same withdraw abuse" ;;
  *)
    echo "VERDICT|$lid|NONE|NO-MATCH|85|stub: a different root cause" ;;
esac
exit 0
