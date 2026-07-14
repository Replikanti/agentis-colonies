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
#   3. Regression guard: score_priority_verdict_key() (native since #1638 P3
#      cluster B2 — was an embedded python3 match_cmd) builds its own flat
#      raw-JSON PRISET, which must ALSO still recognize the broad legacy scheme
#      (same failure mode as #2, but on the reality-check scoring path instead
#      of selection — a narrowed score-PRISET would mis-classify a legacy
#      priority label as "no priority-like label yet" -> signal 0 forever).
#   4. #1678 regression: the #1638 B2 rewrite above still walked the MATCHED
#      priority-label array (`pri`) with two per-element `.ag` closures
#      (member(sug_q, pri) / filter(pri, |m| m != sug_q)) — `pri`'s length is
#      bounded by the raw label count, not a small constant, so an issue whose
#      labels are ALL priority-like still overflowed cb_per_tick (observed
#      110-130 all-priority labels). Section 4 pins the static absence of both
#      closures; section 5 (agentis-gated) pins the four realistic signal
#      values AND reproduces the 150-all-priority-label pathology directly
#      under a tight `cb 400;` budget.
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

# -- (3) regression guard: score_priority_verdict_key()'s native PRISET stays
# broad. #1638 P3 cluster B2 replaced the embedded python match_cmd with a flat
# raw-JSON regex_find_all(PRISET, to_lower(labels)) — the SAME grammar
# canonical_priority_context builds. Assert the score-path PRISET literal still
# carries the three broad-scheme branches (priority* / p[0-9]+ / urgent) AND the
# `[ ]*` whitespace tolerance, so the reality-check scorer cannot silently
# narrow relative to is_pri (which would read a legacy P1 as "no priority label
# yet" and leave the verdict pending forever).
score_block="$(fn_body score_priority_verdict_key)"
if [ -z "$score_block" ]; then
    bad "score_priority_verdict_key() not found"
else
    # Strip // line comments first — the doc comment legitimately references the
    # retired `python3 -c` and must not trip the substrate-purity assertion.
    if printf '%s' "$score_block" | sed 's|//.*$||' | grep -Fq 'python3'; then
        bad "score_priority_verdict_key() still embeds python3 (substrate purity regression, #1587)"
    else
        ok "score_priority_verdict_key() is python-free (native raw-JSON PRISET compare, #1638 B2)"
    fi
    score_priset="$(printf '%s' "$score_block" | grep -F 'let PRISET =' || true)"
    if [ -z "$score_priset" ]; then
        bad "score_priority_verdict_key()'s PRISET raw-JSON literal not found"
    elif printf '%s' "$score_priset" | grep -Fq 'priority[^' \
         && printf '%s' "$score_priset" | grep -Fq 'p[0-9]+' \
         && printf '%s' "$score_priset" | grep -Fq 'urgent'; then
        ok "score_priority_verdict_key()'s PRISET still recognizes priority*, p<digits> and urgent (not narrowed vs is_pri)"
    else
        bad "score_priority_verdict_key()'s PRISET no longer covers priority*/p<digits>/urgent -- the scoring VERIFY silently narrowed: $score_priset"
    fi
    if [ -n "$score_priset" ] && printf '%s' "$score_priset" | grep -Fq '[ ]*'; then
        ok "score_priority_verdict_key()'s PRISET carries [ ]* whitespace tolerance (parity with is_pri's trim)"
    else
        bad "score_priority_verdict_key()'s PRISET dropped its [ ]* whitespace tolerance: $score_priset"
    fi
fi


# -- (4) #1678 regression: score_priority_verdict_key() must no longer walk
# the MATCHED-subset array `pri` with a per-element `.ag` closure. Strip //
# comments first: the doc comment above the fix legitimately quotes both
# retired closures (as history) and must not trip this static pin.
if [ -z "$score_block" ]; then
    bad "score_priority_verdict_key() not found (see section 3)"
else
    score_code="$(printf '%s' "$score_block" | sed 's|//.*$||')"
    if printf '%s' "$score_code" | grep -Fq 'member(sug_q, pri)'; then
        bad "score_priority_verdict_key() still walks pri via member(sug_q, pri) -- #1678 per-element closure regressed"
    else
        ok "score_priority_verdict_key() no longer calls member(sug_q, pri) (#1678 flat rewrite)"
    fi
    if printf '%s' "$score_code" | grep -Fq 'filter(pri,'; then
        bad "score_priority_verdict_key() still walks pri via filter(pri, ...) -- #1678 per-element closure regressed"
    else
        ok "score_priority_verdict_key() no longer calls filter(pri, ...) (#1678 flat rewrite)"
    fi
fi

# -- (5) #1678 live probe: pin the four realistic signal cases and reproduce
# the pathological 150-all-priority-label repro under a TIGHT cb budget.
# Embeds a byte-identical copy of the pri_count/ours/signal logic
# (parameterized on labels_lc, sug_q) -- the forge query and the pv-vocab
# extension are factored out since none of these cases need a custom pv
# token. Gated on the agentis binary (CI runners have none), same convention
# as tools/test-reality-check-wave1.sh's live probes.
if command -v agentis >/dev/null 2>&1; then
    PROBE_TMP="$(mktemp -d)"
    trap 'rm -rf "$PROBE_TMP"' EXIT
    PROBE_HELPER='fn score_signal(labels_lc: string, sug_q: string) -> int {
    let PRISET = "\"[ ]*(?:priority[^\"]*|(?:p[0-9]+|urgent)[ ]*)\"";
    let pri = regex_find_all(PRISET, labels_lc);
    let pri_count = len(pri);
    let ours = index_of(labels_lc, sug_q) >= 0;
    let signal = if pri_count == 0 {
        0;
    } else {
        if ours {
            if pri_count > 1 { 2; } else { 1; };
        } else {
            3;
        };
    };
    return signal;
}'
    run_probe() {
        local budget="$1" body="$2" sandbox
        sandbox="$(mktemp -d -p "$PROBE_TMP")"
        (
            cd "$sandbox"
            agentis init >/dev/null 2>&1
            {
                printf 'cb %s;\n\n%s\n\n%s\n' "$budget" "$PROBE_HELPER" "$body"
            } > probe.ag
            agentis go probe.ag 2>/dev/null | grep -v genesis | tail -n 1
        )
        rm -rf "$sandbox"
    }
    check_probe() {
        local label="$1" budget="$2" call="$3" want="$4" got
        got="$(run_probe "$budget" "print($call);")"
        if [ "$got" = "$want" ]; then
            ok "$label"
        else
            bad "$label (want='$want' got='$got')"
        fi
    }
    # Four realistic cases, all under the same tight cb 400 the pathological
    # repro below runs under.
    check_probe "score_signal: no priority label yet -> 0/keep" 400 \
        'score_signal("[\"bug\",\"docs\"]", "\"p1\"")' "0"
    check_probe "score_signal: our label is the only priority one -> 1/success" 400 \
        'score_signal("[\"bug\",\"p1\"]", "\"p1\"")' "1"
    check_probe "score_signal: ours + a different priority label -> 2/partial" 400 \
        'score_signal("[\"p1\",\"p2\"]", "\"p1\"")' "2"
    check_probe "score_signal: a different priority label, not ours -> 3/override" 400 \
        'score_signal("[\"p2\"]", "\"p1\"")' "3"

    # #1678 pathological repro: 150 distinct all-priority-matching labels
    # ("priority-0".."priority-149", all matching PRISET's `priority[^"]*`
    # branch). sug_q picks the first as ours. The old member(sug_q, pri) +
    # filter(pri, ...) walk paid ~70+ CB/element over all 150 matched entries
    # (>10000 CB) and overflowed cb_per_tick well before this point (observed
    # 110-130); the flat len()/index_of() rewrite stays a handful of native
    # calls regardless of pri's length. `cb 400;` is well under the enforced
    # cb_per_tick default of 2000, and far below what the old walk needed.
    labels150=""
    i=0
    while [ "$i" -lt 150 ]; do
        if [ "$i" -gt 0 ]; then
            labels150="${labels150},"
        fi
        labels150="${labels150}$(printf '\\"priority-%d\\"' "$i")"
        i=$((i + 1))
    done
    labels150="[${labels150}]"
    call_150="score_signal(\"$labels150\", \"\\\"priority-0\\\"\")"
    check_probe "score_signal: #1678 repro -- 150 all-priority labels under cb 400 -> 2 (flat, was overflow @110-130)" \
        400 "$call_150" "2"
    rm -rf "$PROBE_TMP"
else
    echo "[SKIP] agentis binary not found -- #1678 live score_signal probes skipped"
fi

echo
echo "prioritizer-vocab-fallback: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
