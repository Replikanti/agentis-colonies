#!/usr/bin/env bash
# test-labeler-priority-vocab.sh -- #1474 structural regression test
#
# Verifies the deterministic priority-label filter in triage/labeler.ag:
#
#   1. fn strip_priority_like_labels() is defined.
#   2. It is called exactly once, immediately after the
#      `prompt(...) -> LabelAction` call, binding a `filtered_labels` local.
#   3. Below that call, there are zero remaining bare `action.labels` reads
#      in code (excluding `action.issue_id`/`.reasoning`/`.author`/
#      `.confidence` field reads and the documented
#      `emit("triage:label_suggestion", action)` exception sites, which
#      still pass the raw pre-filter struct — #1474's plan explicitly
#      accepts that residual since `.ag` has no struct-literal
#      reconstruction syntax and the event has no internal listener).
#   4. The prompt() instruction literal contains a priority-exclusion
#      clause.
#
# Grep/awk-based (dash-safe) rather than a live LLM+GitHub round-trip,
# mirroring tools/test-labeler-autonomous-verdict.sh's convention.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LABELER="$REPO_ROOT/dev-apprenticeship/triage/agents/labeler.ag"

pass=0
fail=0

ok()  { echo "  ok — $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL — $1"; fail=$((fail + 1)); }

echo "[labeler.ag]"

if [ ! -f "$LABELER" ]; then
    bad "missing file: $LABELER"
    echo
    echo "labeler-priority-vocab: $pass passed, $fail failed"
    exit 1
fi

# -- (1) filter fn defined ----------------------------------------------------
if grep -Eq "^fn strip_priority_like_labels\(" "$LABELER"; then
    ok "fn strip_priority_like_labels() defined"
else
    bad "fn strip_priority_like_labels() missing"
fi

# -- locate the prompt() -> LabelAction call ---------------------------------
prompt_line="$(grep -n ') -> LabelAction;' "$LABELER" | head -1 | cut -d: -f1 || true)"
if [ -z "$prompt_line" ]; then
    bad "prompt(...) -> LabelAction call not found — cannot verify filter wiring"
else
    ok "prompt(...) -> LabelAction call found (line $prompt_line)"

    # -- (2) filter called right after prompt(), binding filtered_labels ----
    filter_call_line="$(awk -v p="$prompt_line" 'NR>p && /let filtered_labels = strip_priority_like_labels\(action\.labels\);/ {print NR; exit}' "$LABELER")"
    if [ -n "$filter_call_line" ] && [ "$((filter_call_line - prompt_line))" -le 10 ]; then
        ok "strip_priority_like_labels(action.labels) called right after prompt() (line $filter_call_line)"
    else
        bad "strip_priority_like_labels(action.labels) not called immediately after prompt() — found at line ${filter_call_line:-<none>}"
    fi

    # -- (3) zero remaining bare action.labels reads below the filter call --
    # Exclude action.issue_id/.reasoning/.author/.confidence (different
    # fields), the documented emit("triage:label_suggestion", action)
    # exception sites (those pass the whole struct, not `.labels`), and
    # prose comment lines (leading `//` after whitespace).
    stray="$(awk -v p="$prompt_line" 'NR>p' "$LABELER" | grep -F 'action.labels' | grep -v 'emit("triage:label_suggestion", action)' | grep -Ev '^[[:space:]]*//' || true)"
    # The filter-definition line itself (`let filtered_labels =
    # strip_priority_like_labels(action.labels);`) is the one legitimate
    # read left; exclude it explicitly before counting strays.
    stray_count="$(printf '%s\n' "$stray" | grep -v 'strip_priority_like_labels(action\.labels)' | grep -c 'action\.labels' || true)"
    if [ "$stray_count" -eq 0 ]; then
        ok "zero remaining bare action.labels reads below prompt() (excluding the filter-definition line and emit() exceptions)"
    else
        bad "$stray_count stray action.labels read(s) below prompt() were not replaced with filtered_labels:"
        printf '%s\n' "$stray" | grep -v 'strip_priority_like_labels(action\.labels)' | sed 's/^/    /'
    fi

    # filtered_labels must actually be USED downstream (not just defined).
    use_count="$(awk -v p="$prompt_line" 'NR>p' "$LABELER" | grep -c 'filtered_labels' || true)"
    # 1 use is the definition itself; need at least one more.
    if [ "$use_count" -gt 1 ]; then
        ok "filtered_labels is read downstream ($use_count occurrences after prompt())"
    else
        bad "filtered_labels is defined but never read downstream"
    fi

    # -- (4) prompt() instruction literal excludes priority suggestions -----
    instr_line="$(sed -n "$((prompt_line - 3)),${prompt_line}p" "$LABELER")"
    if printf '%s' "$instr_line" | grep -qi 'priority' && printf '%s' "$instr_line" | grep -qi 'urgent'; then
        ok "prompt() instruction literal contains a priority-exclusion clause"
    else
        bad "prompt() instruction literal does not mention priority/urgent exclusion"
    fi
fi

echo
echo "labeler-priority-vocab: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
