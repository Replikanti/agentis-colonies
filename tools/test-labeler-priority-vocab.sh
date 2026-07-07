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
#   5. The crystallized-RULE REPLAY path (fire_label_rule() ->
#      apply_label_rule_hit()) also runs the filter, not just the direct
#      prompt() path -- a pre-existing contaminated rule (baked-in bare
#      P1/urgent) would otherwise keep replaying it forever since
#      crystallized rules are never re-filtered once minted:
#        a. fire_label_rule() calls strip_priority_like_labels() and binds
#           the result to `rule_labels`.
#        b. apply_label_rule_hit()'s single call site passes the filtered
#           `rule_labels`, not the pre-filter `rule_labels_raw`.
#        c. zero bare `rule_labels_raw` reads reach any write/verdict use
#           in fire_label_rule() -- the only three legitimate occurrences
#           are its own `let` definition, the post-normalize emptiness
#           check, and the filter call itself.
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

# -- (5) rule-REPLAY path also runs the filter -------------------------------
frl_start="$(grep -n '^fn fire_label_rule(' "$LABELER" | head -1 | cut -d: -f1 || true)"
if [ -z "$frl_start" ]; then
    bad "fn fire_label_rule() not found — cannot verify replay-path filter wiring"
else
    frl_end="$(awk -v s="$frl_start" 'NR>s && /^fn [a-zA-Z_]+\(/ {print NR; exit}' "$LABELER")"
    if [ -z "$frl_end" ]; then
        frl_end="$(wc -l < "$LABELER")"
    else
        frl_end=$((frl_end - 1))
    fi
    frl_body="$(sed -n "${frl_start},${frl_end}p" "$LABELER")"

    # -- (5a) filter called, bound to rule_labels ----------------------------
    if printf '%s\n' "$frl_body" | grep -Fq 'let rule_labels = strip_priority_like_labels(rule_labels_raw);'; then
        ok "fire_label_rule() calls strip_priority_like_labels(rule_labels_raw) -> rule_labels"
    else
        bad "fire_label_rule() does not call strip_priority_like_labels() on the rule-derived labels"
    fi

    # -- (5b) apply_label_rule_hit()'s sole call site passes filtered rule_labels
    ahr_call="$(printf '%s\n' "$frl_body" | grep -F 'apply_label_rule_hit(' || true)"
    if [ -n "$ahr_call" ]; then
        if printf '%s' "$ahr_call" | grep -Eq ', rule_labels,' ; then
            ok "apply_label_rule_hit() call site passes filtered rule_labels"
        else
            bad "apply_label_rule_hit() call site does not pass filtered rule_labels: $ahr_call"
        fi
        if printf '%s' "$ahr_call" | grep -Fq 'rule_labels_raw'; then
            bad "apply_label_rule_hit() call site passes the UNFILTERED rule_labels_raw"
        else
            ok "apply_label_rule_hit() call site does not leak unfiltered rule_labels_raw"
        fi
    else
        bad "apply_label_rule_hit( call not found inside fire_label_rule()"
    fi

    # -- (5c) zero stray rule_labels_raw reads beyond the three legitimate
    # occurrences: the `let rule_labels_raw = ...` definition, the
    # post-normalize emptiness check, and the strip_priority_like_labels()
    # filter call itself. Any 4th occurrence would mean the unfiltered raw
    # value leaked into a write/verdict use.
    raw_count="$(printf '%s\n' "$frl_body" | grep -c 'rule_labels_raw' || true)"
    if [ "$raw_count" -eq 3 ]; then
        ok "rule_labels_raw read exactly 3 times (definition + emptiness check + filter call) — no unfiltered leak"
    else
        bad "rule_labels_raw read $raw_count time(s) inside fire_label_rule() — expected exactly 3 (definition + emptiness check + filter call)"
    fi

    # Fail-closed: empty-after-filter must return "" (skip firing) rather
    # than proceeding to write/verdict-record an empty label set.
    empty_guard="$(printf '%s\n' "$frl_body" | awk '/let rule_labels = strip_priority_like_labels/{f=1} f && /^\s*return ""/{print; exit}')"
    if [ -n "$empty_guard" ]; then
        ok "empty-after-filter guard returns \"\" (skips firing this tick) — fail-closed"
    else
        bad "no return \"\" guard found after the rule_labels filter — empty-after-filter may still fire with a blank label set"
    fi
fi

echo
echo "labeler-priority-vocab: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
