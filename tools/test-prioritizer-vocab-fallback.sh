#!/usr/bin/env bash
# test-prioritizer-vocab-fallback.sh -- #1474 structural regression test
#
# Verifies the split between prioritizer's SUGGESTION vocabulary and its
# DETECTION heuristic in triage/agents/prioritizer.ag:
#
#   1. effective_priority_vocab()'s hardcoded fallback literal is EXACTLY
#      the four scoped labels, with no P1/P2/P3/P4/urgent substrings.
#   2. Regression guard: the native is_pri() DETECTION heuristic (and BOTH
#      regexes canonical_priority_context() builds from it -- PRILINE for
#      selection and PRISET for the #1638 CB-fix raw-JSON VERIFY) still recognize
#      the broad legacy scheme (`priority*` prefix + `p[0-9]+` pattern + "urgent"
#      literal). Narrowing the suggestion vocabulary must never accidentally
#      narrow detection too, and the flat PRISET VERIFY must never silently narrow
#      relative to is_pri, or already-labeled legacy issues would look
#      "unprioritized" again and prioritizer would re-fire forever.
#   3. Regression guard: score_priority_verdict_key()'s match_cmd also
#      still recognizes the broad legacy scheme (same failure mode as #2,
#      but on the reality-check scoring path instead of selection).
#
# Grep/awk-based (dash-safe), mirroring tools/test-labeler-autonomous-verdict.sh.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PRIORITIZER="$REPO_ROOT/dev-apprenticeship/triage/agents/prioritizer.ag"

pass=0
fail=0

ok()  { echo "  ok — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

echo "[prioritizer.ag]"

if [ ! -f "$PRIORITIZER" ]; then
    bad "missing file: $PRIORITIZER"
    echo
    echo "prioritizer-vocab-fallback: $pass passed, $fail failed"
    exit 1
fi

# Extracts the body of a `fn <name>(` ... up to (but excluding) the next
# top-level `^fn ` line. Using two distinct patterns for start/end avoids
# the awk range-pattern trap where a single line matching both collapses
# the range to just that line.
fn_body() {
    fn_name="$1"
    start="$(grep -n "^fn ${fn_name}(" "$PRIORITIZER" | head -1 | cut -d: -f1 || true)"
    if [ -z "$start" ]; then
        return 1
    fi
    end="$(awk -v s="$start" 'NR>s && /^fn [a-zA-Z_]+\(/ {print NR; exit}' "$PRIORITIZER")"
    if [ -z "$end" ]; then
        end="$(wc -l < "$PRIORITIZER")"
    else
        end=$((end - 1))
    fi
    sed -n "${start},${end}p" "$PRIORITIZER"
}

# -- (1) suggestion-vocab fallback is exactly the 4 scoped labels -----------
fallback_line="$(fn_body effective_priority_vocab | grep -F 'return "priority::' || true)"
if [ -z "$fallback_line" ]; then
    bad "effective_priority_vocab() hardcoded fallback return not found"
else
    if printf '%s' "$fallback_line" | grep -Fq 'return "priority::critical, priority::high, priority::medium, priority::low";'; then
        ok "effective_priority_vocab() fallback == exactly the 4 scoped priority::* labels"
    else
        bad "effective_priority_vocab() fallback literal does not match the expected scoped-only string: $fallback_line"
    fi

    # No P1/P2/P3/P4/urgent substrings anywhere in the fallback line.
    leaked=0
    for tok in P1 P2 P3 P4 urgent; do
        if printf '%s' "$fallback_line" | grep -q "$tok"; then
            leaked=1
            bad "fallback literal still contains legacy token: $tok"
        fi
    done
    if [ "$leaked" -eq 0 ]; then
        ok "no legacy P1/P2/P3/P4/urgent substrings in the fallback literal"
    fi
fi

# -- (2) regression guard: the DETECTION grammar stays broad -----------------
# #1638 P3 cluster A made canonical_priority_context native: detection now lives
# in the top-level fn is_pri() (member / ^p<digits>$ / urgent) plus the PRILINE
# regex (selection) canonical_priority_context() builds from it. Assert the broad
# legacy scheme (p<digits> + urgent) survives on BOTH — narrowing it would make
# already-labeled legacy issues look "unprioritized" and re-fire forever.
ispri_block="$(fn_body is_pri || true)"
ctx_block="$(fn_body canonical_priority_context)"
if [ -z "$ispri_block" ]; then
    bad "canonical_priority_context()'s is_pri() detection function not found"
elif printf '%s' "$ispri_block" | grep -Fq 'p[0-9]+' && printf '%s' "$ispri_block" | grep -Fq 'urgent' \
     && printf '%s' "$ctx_block" | grep -Fq 'p[0-9]+' && printf '%s' "$ctx_block" | grep -Fq 'urgent'; then
    ok "is_pri() + PRILINE still recognize p<digits> and urgent (detection unchanged)"
else
    bad "is_pri()/PRILINE no longer recognizes both p<digits> and urgent -- detection was accidentally narrowed"
fi

# -- (2b) #1638 CB fix: the flat raw-JSON VERIFY regex (PRISET) must mirror
# is_pri's grammar and not silently narrow it. Extract the PRISET literal and
# assert it still carries the three broad-scheme branches: `priority` (startswith),
# `p[0-9]+` (fullmatch), and `urgent`. If PRISET ever drops one, a legacy label
# would pass the VERIFY and the chosen issue would emit as "unprioritized".
priset_line="$(printf '%s' "$ctx_block" | grep -F 'let PRISET =' || true)"
if [ -z "$priset_line" ]; then
    bad "canonical_priority_context()'s PRISET raw-JSON VERIFY literal not found"
elif printf '%s' "$priset_line" | grep -Fq 'priority[^' \
     && printf '%s' "$priset_line" | grep -Fq 'p[0-9]+' \
     && printf '%s' "$priset_line" | grep -Fq 'urgent'; then
    ok "PRISET still recognizes priority*, p<digits> and urgent (raw-JSON VERIFY not narrowed vs is_pri)"
else
    bad "PRISET no longer covers priority*/p<digits>/urgent -- the flat VERIFY silently narrowed relative to is_pri: $priset_line"
fi

# -- (2c) #1638 QA: PRISET must keep is_pri's to_lower(trim(l)) whitespace
# tolerance -- a `[ ]*` run after the opening quote and on the p<digits>/urgent/pv
# arms, so a space-padded priority label ("  P1  ") is still detected. Dropping the
# `[ ]*` re-introduces the QA byte-identity regression (padded priority leaks into
# nonpri instead of returning "").
if [ -n "$priset_line" ] && printf '%s' "$priset_line" | grep -Fq '[ ]*'; then
    ok "PRISET carries [ ]* whitespace tolerance (restores is_pri's trim for padded labels)"
else
    bad "PRISET dropped its [ ]* whitespace tolerance -- padded priority labels ('  P1  ') would leak past the VERIFY: $priset_line"
fi

# -- (3) regression guard: score_priority_verdict_key() match_cmd stays broad
score_block="$(fn_body score_priority_verdict_key)"
if [ -z "$score_block" ]; then
    bad "score_priority_verdict_key() not found"
else
    if printf '%s' "$score_block" | grep -Fq 'p\\d+' && printf '%s' "$score_block" | grep -Fq 'urgent'; then
        ok "score_priority_verdict_key()'s match_cmd still recognizes p\\d+ and urgent (detection unchanged)"
    else
        bad "score_priority_verdict_key()'s match_cmd no longer recognizes both p\\d+ and urgent -- detection was accidentally narrowed"
    fi
fi

echo
echo "prioritizer-vocab-fallback: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
