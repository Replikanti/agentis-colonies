#!/bin/sh
# dupes-stub.sh — the offline BUILDER judge backend for the #1840 GT-equivalence fixture. gt-dupes.sh sends
# one truth row per request in the `lead` slot (`id = R-<sev_id>`, signature in `exploit`) against the rows
# that come AFTER it, using the unchanged mech-judge.sh request/reply grammar; this stub answers with the
# canned verdicts a correct judge would give on fixtures/gt-dupes/truth.tsv. Deterministic, no LLM / network.
#
#   R-D-1 vs [D-2 D-3 D-4] -> MATCH D-2   (the same capped-deposit truncation, described differently)
#   R-D-2 vs [D-3 D-4]     -> NO-MATCH
#   R-D-3 vs [D-4]         -> NO-MATCH    (D-3/D-4 share settleEpoch but are different mechanisms — the
#                                          negative control: a shared name must never merge two rows)
# D-4 is never sent: the upper-triangle sweep has nothing after the last row.
#
# dash-safe: no arrays, no $'...', literal glyphs only.
set -u

req="$(cat)"

case "$req" in
  *'"id":"R-D-1"'*)
    echo "VERDICT|R-D-1|D-2|MATCH|93|same capped-deposit truncation and the same unreconciled remainder stranded in the router, described from the router side and from the pool side"
    ;;
  *'"id":"R-D-2"'*)
    echo "VERDICT|R-D-2|NONE|NO-MATCH|90|the remaining rows are epoch-settlement bugs with an unrelated root cause"
    ;;
  *'"id":"R-D-3"'*)
    echo "VERDICT|R-D-3|NONE|NO-MATCH|91|both rows live in settleEpoch but one is a stale settlement price and the other a skipped withdrawal queue"
    ;;
esac
exit 0
