#!/usr/bin/env bash
# test-prioritizer-vocab-fallback.sh -- #1474 structural regression test
#
# Verifies the split between prioritizer's SUGGESTION vocabulary and its
# DETECTION heuristic in triage/agents/prioritizer.ag:
#
#   1. effective_priority_vocab()'s hardcoded fallback literal is EXACTLY
#      the four scoped labels, with no P1/P2/P3/P4/urgent substrings.
#   2. Regression guard: the is_pri() DETECTION heuristic inside
#      canonical_priority_context() still recognizes the broad legacy
#      scheme (`p\d+` pattern + "urgent" literal) -- narrowing the
#      suggestion vocabulary must never accidentally narrow detection too,
#      or already-labeled legacy issues would look "unprioritized" again
#      and prioritizer would re-fire on them forever.
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

# -- (2) regression guard: is_pri() detection stays broad --------------------
ctx_block="$(fn_body canonical_priority_context)"
if printf '%s' "$ctx_block" | grep -Fq 'is_pri(l)'; then
    if printf '%s' "$ctx_block" | grep -Fq 'p\\d+' && printf '%s' "$ctx_block" | grep -Fq 'urgent'; then
        ok "canonical_priority_context()'s is_pri() still recognizes p\\d+ and urgent (detection unchanged)"
    else
        bad "canonical_priority_context()'s is_pri() no longer recognizes both p\\d+ and urgent -- detection was accidentally narrowed"
    fi
else
    bad "canonical_priority_context()'s is_pri() detection function not found"
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
