#!/bin/bash
# tools/test-reality-check-wave1.sh: source-asserts the #1453 Wave 1
# reality-check feedback loop in the four agents closest to terminal
# actions: code-review/approval_decider, release/ship_decider,
# implementation/code_writer, planning/plan_reviewer.
#
# The pattern under test is doc/feedback-loop.md's 4-step idiom (stash
# verdict memo -> re-query the forge -> mechanical compare -> learn()
# with the honest outcome + "acted" tag), copied from the triage pilot
# (labeler/router/prioritizer). Without it, every acting row lands in
# the experience store as self-reported success and auto-promote's
# reject_rate_acting brake is structurally unreachable.
#
# Per agent this asserts:
#   1. record_<x>_verdict and evaluate_<x>_verdict fns exist
#   2. the single-slot memo key literal "<agent>:pending_verdict" is
#      written AND read via scoped_memo (per-repo, #316)
#   3. evaluate is invoked at the TOP of tick_for_repo (within the
#      first lines, before any early-return work) — otherwise a busy
#      tick starves the reality check forever
#   4. the 24h ageout literal (86400) guards the evaluate
#   5. the evaluate learn() carries the agent's recommend() topic and
#      the "acted" tag (auto-promote acting bucket)
#   6. the ground-truth re-query uses the agreed mechanical primitive
#      (see per-agent markers below) — never a prompt()
#   7. the expected number of stash call sites (definition + N calls)
# Plus the QA-sweep hardening (#1453 follow-up findings):
#   - outcome enum is "failure" (core rejects "fail" at runtime) — asserted
#     across the four Wave 1 agents AND the triage pilot
#   - plan_reviewer soaks 30 min before scoring its own promotion write
#   - approval_decider/code_writer refuse to score from an unparseable
#     merged list (GitHub closed-superset hazard)
#   - ship_decider uses a sanitized tag-name SET baseline (GitHub /tags is
#     unordered), a __QUERY_FAILED__ sentinel, and a silent unscored ageout
#   - auto-promote counts outcome=="failure" as a reject (the enabler that
#     lets these honest rows move reject_rate_acting)
#
# Usage: ./tools/test-reality-check-wave1.sh
# Exit code 0 if all assertions pass, 1 otherwise.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FED="$REPO_ROOT/dev-apprenticeship"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# evaluate_region <file> <fn-name>: print the body of `fn <fn-name>`
# (from the definition line to the first column-0 closing brace).
evaluate_region() {
    awk -v fn="$2" '
        $0 ~ "^fn " fn "\\(" { p = 1 }
        p { print }
        p && /^}$/ { p = 0 }
    ' "$1"
}

# tick_head <file>: first 8 lines of fn tick_for_repo — the "top of
# tick" window the evaluate call must land in.
tick_head() {
    awk '/^fn tick_for_repo\(/{p=1} p{print; n++} n>=8{exit}' "$1"
}

# check_agent <file> <agent> <short> <topic> <stash-count> <query-marker...>
check_agent() {
    local file="$1" agent="$2" short="$3" topic="$4" stash_count="$5"
    shift 5
    local record_fn="record_${short}_verdict"
    local evaluate_fn="evaluate_${short}_verdict"
    local key="${agent}:pending_verdict"

    if grep -Eq "^fn ${record_fn}\(" "$file" && grep -Eq "^fn ${evaluate_fn}\(" "$file"; then
        pass "$agent: $record_fn + $evaluate_fn defined"
    else
        fail "$agent: missing $record_fn / $evaluate_fn definition"
    fi

    local key_count
    key_count="$(grep -c "scoped_memo(owner, repo, \"$key\")" "$file" || true)"
    if [ "$key_count" -ge 2 ]; then
        pass "$agent: \"$key\" written and read via scoped_memo ($key_count sites)"
    else
        fail "$agent: expected >=2 scoped_memo(\"$key\") sites, found $key_count"
    fi

    if tick_head "$file" | grep -q "${evaluate_fn}(owner, repo)"; then
        pass "$agent: $evaluate_fn invoked at the top of tick_for_repo"
    else
        fail "$agent: $evaluate_fn not in the first lines of tick_for_repo"
    fi

    local region
    region="$(evaluate_region "$file" "$evaluate_fn")"
    if printf '%s' "$region" | grep -q "86400"; then
        pass "$agent: 24h ageout literal (86400) in $evaluate_fn"
    else
        fail "$agent: no 86400 ageout in $evaluate_fn"
    fi

    if printf '%s' "$region" | grep -q "\"$topic\"" \
        && printf '%s' "$region" | grep -q "\"acted\""; then
        pass "$agent: evaluate learn() carries topic \"$topic\" + \"acted\" tag"
    else
        fail "$agent: evaluate learn() missing topic \"$topic\" or \"acted\" tag"
    fi

    # Strip // line comments first — a comment MENTIONING prompt() must
    # not trip the mechanical-compare assertion.
    if printf '%s' "$region" | sed 's|//.*$||' | grep -q "prompt("; then
        fail "$agent: $evaluate_fn calls prompt() — compare must be mechanical"
    else
        pass "$agent: $evaluate_fn is prompt()-free (mechanical compare)"
    fi

    local marker
    for marker in "$@"; do
        if printf '%s' "$region" | grep -qF -- "$marker"; then
            pass "$agent: ground-truth re-query uses '$marker'"
        else
            fail "$agent: '$marker' not found in $evaluate_fn"
        fi
    done

    local rec_count
    rec_count="$(grep -c "${record_fn}(" "$file" || true)"
    if [ "$rec_count" -eq "$stash_count" ]; then
        pass "$agent: $record_fn has $((stash_count - 1)) stash call site(s) (+definition)"
    else
        fail "$agent: expected $stash_count ${record_fn}( occurrences (def + calls), found $rec_count"
    fi
}

# ----- approval_decider: suggested approve/request_changes vs MR fate -----
check_agent \
    "$FED/code-review/agents/approval_decider.ag" \
    "approval_decider" "approval" "approval_decision" 5 \
    "--state merged --per-page 50" "--state closed --per-page 50"

# ----- ship_decider: baseline tag at "ship" verdict vs actually-cut tag -----
check_agent \
    "$FED/release/agents/ship_decider.ag" \
    "ship_decider" "ship" "ship_decide" 3 \
    "tag_set_csv(" "__QUERY_FAILED__"

# Success-only signal: the ageout must drop UNSCORED (a partial row would
# carry a positive delta and reward ignored ship calls).
SHIP_REGION="$(evaluate_region "$FED/release/agents/ship_decider.ag" "evaluate_ship_verdict")"
if printf '%s' "$SHIP_REGION" | grep -q "aged out without a release" \
    && ! printf '%s' "$SHIP_REGION" | grep -q "signal_to_outcome(2)"; then
    pass "ship_decider: ageout drops unscored (success-only signal)"
else
    fail "ship_decider: ageout must drop without scoring"
fi

# ----- code_writer: fate of the fix/issue-<iid> branch -----
check_agent \
    "$FED/implementation/agents/code_writer.ag" \
    "code_writer" "code" "code_write" 2 \
    "raw_list_has_branch(" "--state merged" "--state closed" "--state opened"

# ----- plan_reviewer: impl trigger label survival vs needs-planning re-add -----
check_agent \
    "$FED/planning/agents/plan_reviewer.ag" \
    "plan_reviewer" "plan" "review_plan" 2 \
    "forge-api.sh issue "

# ----- QA-sweep hardening assertions -----

# Outcome enum: "fail" is not a valid learn() outcome (core enforces
# success/failure/partial/timeout/error); a single surviving literal
# would runtime-error on the first negative signal and starve the tick
# for up to 24h. Swept across EVERY dev-apprenticeship agent (not just the
# Wave-1 set) so the guard catches the whole bug class — a #1453 adversarial
# review found the invalid literal surviving in two sibling planning agents
# (risk_assessor, task_decomposer) that the original narrow sweep missed.
ENUM_FAIL=0
for f in "$FED"/*/agents/*.ag; do
    # Match the learn()-outcome forms — a bare `"fail",` positional arg or a
    # helper `return "fail";` — but NOT a job-status compare like `== "fail"`
    # (a legitimate poll-token comparison, e.g. code_writer's VERIFY gate).
    if grep -qE '"fail",|return "fail";' "$f"; then
        fail "$(basename "$f"): invalid outcome literal \"fail\" survives"
        ENUM_FAIL=1
    fi
done
if [ "$ENUM_FAIL" -eq 0 ]; then
    pass "outcome enum: no invalid \"fail\" literal in ANY dev-apprenticeship agent"
fi

# plan_reviewer: 30 min soak before scoring its own promotion write.
PLAN_REGION="$(evaluate_region "$FED/planning/agents/plan_reviewer.ag" "evaluate_plan_verdict")"
if printf '%s' "$PLAN_REGION" | grep -q "soak_s = 1800"; then
    pass "plan_reviewer: 30 min soak gate before scoring"
else
    fail "plan_reviewer: soak gate missing — instant self-success"
fi

# approval_decider: merged list must parse before anything is scored.
# #1638 P3 cluster B: the python `ml is None -> print(0)` guard and the
# `print(2 if m else (1 if c else 0))` request_changes mapping are now the
# native leading-`[`/trailing-`]` array guard + the request_changes signal
# ternary (both-ends check added post-QA #1674: a leading-`[`-only guard let a
# truncated MERGED payload through to a real, wrong score).
APPR_REGION="$(evaluate_region "$FED/code-review/agents/approval_decider.ag" "evaluate_approval_verdict")"
if printf '%s' "$APPR_REGION" | grep -qF 'index_of(merged_trimmed, "[") != 0' \
    && printf '%s' "$APPR_REGION" | grep -qF 'substring(merged_trimmed, len(merged_trimmed) - 1, len(merged_trimmed)) != "]"' \
    && printf '%s' "$APPR_REGION" | grep -qF 'if m { 2; } else { if c { 1; } else { 0; }; };'; then
    pass "approval_decider: merged-parse guard (both ends) + request_changes/merged=partial"
else
    fail "approval_decider: missing merged-parse guard (leading+trailing bracket) or partial mapping"
fi

# code_writer: unparseable merged/opened lists leave the verdict pending.
CW_REGION="$(evaluate_region "$FED/implementation/agents/code_writer.ag" "evaluate_code_verdict")"
if [ "$(printf '%s' "$CW_REGION" | grep -cF 'index_of(merged_raw, "[") != 0')" -eq 1 ] \
    && [ "$(printf '%s' "$CW_REGION" | grep -cF 'index_of(opened_raw, "[") != 0')" -eq 1 ]; then
    pass "code_writer: merged+opened parse guards present"
else
    fail "code_writer: list parse guards missing"
fi

# Stash placement (line order): plan_reviewer stashes inside the
# promotion-success arm; ship stashes ride the decision=="ship" gates.
PLAN_FILE="$FED/planning/agents/plan_reviewer.ag"
PROMOTE_LINE="$(grep -n "if len(promote_result) > 0 {" "$PLAN_FILE" | head -1 | cut -d: -f1)"
PLAN_STASH_LINE="$(grep -n "record_plan_verdict(owner, repo, draft.issue_id" "$PLAN_FILE" | head -1 | cut -d: -f1)"
if [ -n "$PROMOTE_LINE" ] && [ -n "$PLAN_STASH_LINE" ] && [ "$PLAN_STASH_LINE" -gt "$PROMOTE_LINE" ]; then
    pass "plan_reviewer: stash call sits after the promotion-success guard"
else
    fail "plan_reviewer: stash/promotion ordering broken (stash=$PLAN_STASH_LINE promote=$PROMOTE_LINE)"
fi

# auto-promote: outcome=="failure" counts as a reject — without this the
# honest rows can never move reject_rate_acting (the point of #1453).
if grep -q "in ('reject', 'failure')" "$REPO_ROOT/tools/auto-promote-decisions.py"; then
    pass "auto-promote: outcome failure counts toward reject_rate_acting"
else
    fail "auto-promote: reject predicate does not count failure outcomes"
fi

# ----- ship_decider tag_set_csv: FLAT-cost native rewrite (#1638 P3 cluster C, QA #1640) -----
# The tag-set baseline feeds the reality-check compare, so its build must stay
# native (no embedded python), preserve the #1453 Wave 1 prefix filter, AND be
# FLAT cost — the first native draft's per-element map(sanitize)+filter(prefix)
# `.ag` walk (~75 CB/tag) overflowed ship_decider's tick budget on a growing
# tag set (#1640). The fix routes all per-element work through flat builtins.
SHIP_FILE="$FED/release/agents/ship_decider.ag"
TAGSET_REGION="$(evaluate_region "$SHIP_FILE" "tag_set_csv")"
if printf '%s' "$TAGSET_REGION" | sed 's|//.*$||' | grep -q "python3"; then
    fail "ship_decider: tag_set_csv still embeds python3 (substrate purity regression)"
else
    pass "ship_decider: tag_set_csv is python-free (native set-op pipeline)"
fi
# Flat-cost guard: NO per-element map/filter `.ag` walk over the tag array — the
# projection + prefix filter must be single flat builtin calls (#1640).
if printf '%s' "$TAGSET_REGION" | sed 's|//.*$||' | grep -qE 'map\(|filter\('; then
    fail "ship_decider: tag_set_csv has a per-element map/filter walk (CB regression #1640)"
else
    pass "ship_decider: tag_set_csv is per-element-walk-free (flat cost, #1640)"
fi
if printf '%s' "$TAGSET_REGION" | grep -qF 'json_array_project(raw, "", "name")' \
    && printf '%s' "$TAGSET_REGION" | grep -qF '(?m)^dev-apprenticeship-v' \
    && printf '%s' "$TAGSET_REGION" | grep -qF "sort_unique_strings(names)"; then
    pass "ship_decider: tag_set_csv keeps flat projection + prefix filter + sorted set"
else
    fail "ship_decider: tag_set_csv missing json_array_project / prefix regex / sort_unique_strings"
fi
if grep -qE "^fn sanitize_tag_blob\(" "$SHIP_FILE"; then
    pass "ship_decider: sanitize_tag_blob helper defined"
else
    fail "ship_decider: sanitize_tag_blob helper missing"
fi

# Live byte-identity: the flat pipeline (project -> whole-blob sanitize (strip
# ,/\"/\\) -> multiline-anchored dev-apprenticeship-v prefix filter -> sorted
# unique set) must be value-identical to the retired python
# `sorted({sanitize(name) ... if n.startswith(...)})`. Embeds a byte-identical
# copy of the native pipeline parameterized on a raw tags JSON string (the forge
# call is factored out). Expected values are the python reference outputs. Gated
# on the agentis binary (CI runners have none).
if command -v agentis >/dev/null 2>&1; then
    TAGSET_TMP="$(mktemp -d)"
    trap 'rm -rf "$TAGSET_TMP"' EXIT
    TAGSET_HELPER='fn sanitize_tag_blob(blob: string) -> string {
    return reduce(regex_find_all("[^,\"\\\\]+", blob), |acc: string, part: string| -> string {
        return acc + part;
    }, "");
}
fn tag_set_from_raw(raw: string) -> string {
    let blob = json_array_project(raw, "", "name");
    let sanitized = sanitize_tag_blob(blob);
    let names = regex_find_all("(?m)^dev-apprenticeship-v.*", sanitized);
    return reduce(sort_unique_strings(names), |acc: string, t: string| -> string {
        if len(acc) > 0 { return acc + "," + t; };
        return t;
    }, "");
}'
    run_tagset() {
        local body="$1" sandbox
        sandbox="$(mktemp -d -p "$TAGSET_TMP")"
        (
            cd "$sandbox"
            agentis init >/dev/null 2>&1
            {
                printf 'cb 8000;\n\n%s\n\n%s\n' "$TAGSET_HELPER" "$body"
            } > probe.ag
            agentis go probe.ag 2>/dev/null | grep -v genesis | tail -n 1
        )
        rm -rf "$sandbox"
    }
    check_tagset() {
        local label="$1" raw="$2" want="$3" got
        got="$(run_tagset "print(tag_set_from_raw(\"$raw\"));")"
        if [ "$got" = "$want" ]; then
            pass "$label"
        else
            fail "$label (want='$want' got='$got')"
        fi
    }
    # prefix filter drops federation-dashboard-v + human tags; dedup + sort.
    check_tagset "ship_decider tag_set: prefix filter + sorted set" \
        '[{\"name\":\"dev-apprenticeship-v2.10.1\"},{\"name\":\"federation-dashboard-v1.0.0\"},{\"name\":\"dev-apprenticeship-v2.9.0\"},{\"name\":\"random-human-tag\"}]' \
        "dev-apprenticeship-v2.10.1,dev-apprenticeship-v2.9.0"
    # sanitize strips comma, double-quote, backslash from a name.
    check_tagset "ship_decider tag_set: sanitize ,/\"/\\ in tag name" \
        '[{\"name\":\"dev-apprenticeship-v9,0\\\"x\\\\y\"}]' \
        "dev-apprenticeship-v90xy"
    # no matching prefix -> empty set (repo with only foreign/human tags).
    check_tagset "ship_decider tag_set: no matching prefix -> empty" \
        '[{\"name\":\"federation-dashboard-v2.0\"},{\"name\":\"human\"}]' \
        ""
    # empty tags array -> empty set (legitimate no-tags baseline).
    check_tagset "ship_decider tag_set: empty array -> empty" '[]' ""
    # multiline ^ anchor: a mid-line prefix (not at line start) must NOT match,
    # == python startswith. `xdev-apprenticeship-v1.0` -> excluded.
    check_tagset "ship_decider tag_set: mid-line prefix not matched (startswith parity)" \
        '[{\"name\":\"xdev-apprenticeship-v1.0\"}]' \
        ""
    # non-semver prefix tags are KEPT (python startswith has no digit rule);
    # confirms sorted-set on the full sanitized name, not a version-char regex.
    check_tagset "ship_decider tag_set: non-digit prefix tags kept + sorted" \
        '[{\"name\":\"dev-apprenticeship-vB\"},{\"name\":\"dev-apprenticeship-vA\"}]' \
        "dev-apprenticeship-vA,dev-apprenticeship-vB"
    # sanitize-before-filter: a comma inside the name is stripped FIRST, which
    # can make a non-prefixed name become prefixed, exactly like python.
    check_tagset "ship_decider tag_set: sanitize-before-filter order (python parity)" \
        '[{\"name\":\"dev-apprenticeship,-v1\"}]' \
        "dev-apprenticeship-v1"
else
    echo "[SKIP] agentis binary not found — tag_set_csv live byte-identity checks skipped"
fi

# ----- Cluster B1 comparators: live signal byte-identity (#1638 P3) -----
# The 5 mechanical small-set verdict scorers were migrated from an embedded
# `python3 -c` set-comparison to native `.ag` (json_get_raw ->
# json_array_to_strings for the array leaf json_get returns Void for; member/
# subset/intersect via filter+len). The honest-outcome signal each one feeds
# learn() is the value-identity anchor — a wrong compare corrupts auto-promote's
# reject_rate_acting. Each probe embeds a byte-identical copy of the migrated
# signal logic (the forge query factored out, raw JSON passed in) and pins the
# exact signal per suggested/actual combo to the retired python's output. Gated
# on the agentis binary (CI runners have none).
if command -v agentis >/dev/null 2>&1; then
    CMP_TMP="$(mktemp -d)"
    COMPARE_HELPERS='fn member(x: string, xs: list<string>) -> bool {
    return len(filter(xs, |y: string| -> bool { return y == x; })) > 0;
}
fn subset(sug: list<string>, act: list<string>) -> bool {
    return len(filter(sug, |s: string| -> bool { return !member(s, act); })) == 0;
}
fn intersect(sug: list<string>, act: list<string>) -> bool {
    return len(filter(sug, |s: string| -> bool { return member(s, act); })) > 0;
}
fn void_to_empty(s: string) -> string {
    if s == "void" { return ""; };
    return s;
}
fn nth_field(s: string, sep: string, n: int) -> string {
    if n < 0 { return ""; };
    if len(s) == 0 { return ""; };
    let p = index_of(s, sep);
    if n == 0 {
        if p < 0 { return s; };
        return substring(s, 0, p);
    };
    if p < 0 { return ""; };
    return nth_field(substring(s, p + len(sep), len(s)), sep, n - 1);
}
fn sug_list(suggested: string) -> list<string> {
    return filter(map(regex_split(",", suggested), |t: string| -> string {
        return trim(t);
    }), |t: string| -> bool {
        return len(t) > 0;
    });
}
fn label_propose_signal(suggested: string, cur_raw: string) -> int {
    let act = json_array_to_strings(json_get_raw(cur_raw, "labels"));
    let sug = sug_list(suggested);
    let s = if len(act) == 0 {
        0;
    } else {
        if len(sug) > 0 {
            if subset(sug, act) { 1; } else { if intersect(sug, act) { 2; } else { 3; }; };
        } else {
            if intersect(sug, act) { 2; } else { 3; };
        };
    };
    return s;
}
fn label_auto_signal(suggested: string, cur_raw: string) -> int {
    let act = json_array_to_strings(json_get_raw(cur_raw, "labels"));
    let sug = sug_list(suggested);
    let s = if len(sug) > 0 {
        if subset(sug, act) { 1; } else { if intersect(sug, act) { 2; } else { 3; }; };
    } else {
        if intersect(sug, act) { 2; } else { 3; };
    };
    return s;
}
fn route_signal(suggested: string, cur_raw: string) -> int {
    let sug = trim(suggested);
    let ns = filter(map(json_array_object_field_values(json_get_raw(cur_raw, "assignees"), "username"), |u: string| -> string {
        return trim(u);
    }), |u: string| -> bool {
        return len(u) > 0;
    });
    let a1 = void_to_empty(to_string(json_get(cur_raw, "assignee.username")));
    let s = if len(ns) == 0 {
        if len(a1) == 0 { 0; } else { if a1 == sug { 1; } else { 3; }; };
    } else {
        if member(sug, ns) { 1; } else { if len(a1) > 0 { if a1 == sug { 1; } else { 3; }; } else { 3; }; };
    };
    return s;
}
fn approval_signal(action: string, merged_raw: string, closed_raw: string, iid_str: string) -> int {
    let merged_trimmed = trim(merged_raw);
    if index_of(merged_trimmed, "[") != 0 { return 0; };
    if substring(merged_trimmed, len(merged_trimmed) - 1, len(merged_trimmed)) != "]" { return 0; };
    let m = member(iid_str, json_array_object_field_values(merged_raw, "iid"));
    let c = member(iid_str, json_array_object_field_values(closed_raw, "iid"));
    let s = if action == "approve" {
        if m { 1; } else { if c { 3; } else { 0; }; };
    } else {
        if action == "request_changes" { if m { 2; } else { if c { 1; } else { 0; }; }; } else { 0; };
    };
    return s;
}
fn plan_signal(labels_csv: string, cur_raw: string) -> int {
    let impl = trim(nth_field(labels_csv, ",", 0));
    let plan = trim(nth_field(labels_csv, ",", 1));
    let act = json_array_to_strings(json_get_raw(cur_raw, "labels"));
    let s = if len(impl) > 0 {
        if member(impl, act) { 1; } else { if len(plan) > 0 { if member(plan, act) { 3; } else { 2; }; } else { 2; }; };
    } else {
        if len(plan) > 0 { if member(plan, act) { 3; } else { 2; }; } else { 2; };
    };
    return s;
}'
    run_compare() {
        local body="$1" sandbox
        sandbox="$(mktemp -d -p "$CMP_TMP")"
        (
            cd "$sandbox"
            agentis init >/dev/null 2>&1
            {
                printf 'cb 8000;\n\n%s\n\n%s\n' "$COMPARE_HELPERS" "$body"
            } > probe.ag
            agentis go probe.ag 2>/dev/null | grep -v genesis | tail -n 1
        )
        rm -rf "$sandbox"
    }
    check_signal() {
        local label="$1" call="$2" want="$3" got
        got="$(run_compare "print($call);")"
        if [ "$got" = "$want" ]; then
            pass "$label"
        else
            fail "$label (want='$want' got='$got')"
        fi
    }
    # labeler propose (evaluate_label_verdict): empty act -> 0 (leave pending),
    # full subset -> 1, partial -> 2, disjoint -> 3; missing-key AND [] both 0.
    check_signal "labeler propose: no labels yet ([]) -> 0/pending" \
        'label_propose_signal("bug,ci", "{\"labels\":[]}")' "0"
    check_signal "labeler propose: missing labels key -> 0/pending" \
        'label_propose_signal("bug,ci", "{\"title\":\"x\"}")' "0"
    check_signal "labeler propose: full subset -> 1/success" \
        'label_propose_signal("bug,ci", "{\"labels\":[\"bug\",\"ci\",\"docs\"]}")' "1"
    check_signal "labeler propose: partial overlap -> 2/partial" \
        'label_propose_signal("bug,x", "{\"labels\":[\"bug\",\"ci\",\"docs\"]}")' "2"
    check_signal "labeler propose: disjoint -> 3/failure" \
        'label_propose_signal("x,y", "{\"labels\":[\"bug\",\"ci\",\"docs\"]}")' "3"
    # labeler autonomous (score_one_autonomous): same but empty act -> 3 (no
    # signal-0 branch — an empty act is a full reversal).
    check_signal "labeler autonomous: empty act -> 3/failure (no pending)" \
        'label_auto_signal("bug,ci", "{\"labels\":[]}")' "3"
    check_signal "labeler autonomous: full subset -> 1/success" \
        'label_auto_signal("bug,ci", "{\"labels\":[\"bug\",\"ci\"]}")' "1"
    check_signal "labeler autonomous: partial erosion -> 2/partial" \
        'label_auto_signal("bug,x", "{\"labels\":[\"bug\"]}")' "2"
    check_signal "labeler autonomous: full reversal -> 3/failure" \
        'label_auto_signal("x,y", "{\"labels\":[\"bug\"]}")' "3"
    # router (score_route_verdict_key): unassigned -> 0, suggested among
    # assignees -> 1, reassigned away -> 3, singular-assignee fallback -> 1.
    check_signal "router: still unassigned -> 0/keep" \
        'route_signal("alice", "{\"assignees\":[]}")' "0"
    check_signal "router: suggested among assignees -> 1/success" \
        'route_signal("alice", "{\"assignees\":[{\"username\":\"alice\"},{\"username\":\"bob\"}]}")' "1"
    check_signal "router: reassigned away -> 3/failure" \
        'route_signal("alice", "{\"assignees\":[{\"username\":\"bob\"}]}")' "3"
    check_signal "router: singular assignee fallback match -> 1/success" \
        'route_signal("carol", "{\"assignee\":{\"username\":\"carol\"}}")' "1"
    check_signal "router: assignees ∪ singular set membership -> 1/success" \
        'route_signal("alice", "{\"assignees\":[{\"username\":\"bob\"}],\"assignee\":{\"username\":\"alice\"}}")' "1"
    # approval_decider (evaluate_approval_verdict): merged wins the tie; the
    # MERGED list must parse as an array (leading `[` AND trailing `]`) or
    # nothing is scored.
    check_signal "approval_decider: approve + merged -> 1/success" \
        'approval_signal("approve", "[{\"iid\":41}]", "[]", "41")' "1"
    check_signal "approval_decider: approve + closed-only -> 3/failure" \
        'approval_signal("approve", "[]", "[{\"iid\":41}]", "41")' "3"
    check_signal "approval_decider: approve + neither -> 0/no-score" \
        'approval_signal("approve", "[]", "[]", "41")' "0"
    check_signal "approval_decider: request_changes + merged -> 2/partial" \
        'approval_signal("request_changes", "[{\"iid\":41}]", "[]", "41")' "2"
    check_signal "approval_decider: request_changes + closed -> 1/success" \
        'approval_signal("request_changes", "[]", "[{\"iid\":41}]", "41")' "1"
    check_signal "approval_decider: unparseable MERGED (empty string) -> 0/no-score (closed-superset guard)" \
        'approval_signal("approve", "", "[{\"iid\":41}]", "41")' "0"
    # QA #1674: a leading-`[`-only guard let a truncated MERGED payload (a
    # forge read cut off mid-response, e.g. by a network timeout) through to
    # json_array_object_field_values, which degrades gracefully on the
    # malformed tail rather than throwing -- `m` silently resolved false and
    # the tick fell through to a REAL WRONG score off the closed list, exactly
    # the closed-superset-of-merged hazard this guard exists to prevent.
    # Python's strict json.loads would reject all four of these as unparseable
    # -> signal forced 0; the both-ends bracket check must too.
    check_signal "approval_decider: truncated MERGED (array unclosed) -> 0/no-score" \
        'approval_signal("approve", "[{\"iid\":41}", "[{\"iid\":41}]", "41")' "0"
    check_signal "approval_decider: truncated MERGED (mid-key cutoff) -> 0/no-score" \
        'approval_signal("approve", "[{\"ii", "[{\"iid\":41}]", "41")' "0"
    check_signal "approval_decider: MERGED with trailing garbage after valid array -> 0/no-score" \
        'approval_signal("approve", "[{\"iid\":41}]xyz", "[{\"iid\":41}]", "41")' "0"
    check_signal "approval_decider: truncated MERGED on request_changes path -> 0/no-score" \
        'approval_signal("request_changes", "[{\"iid\":41", "[{\"iid\":41}]", "41")' "0"
    # plan_reviewer (evaluate_plan_verdict): impl label present -> 1, plan label
    # re-added -> 3, neither -> 2 (single-field CSV -> plan="").
    check_signal "plan_reviewer: impl label present -> 1/success" \
        'plan_signal("impl-label,plan-label", "{\"labels\":[\"impl-label\"]}")' "1"
    check_signal "plan_reviewer: plan label re-added -> 3/failure" \
        'plan_signal("impl-label,plan-label", "{\"labels\":[\"plan-label\"]}")' "3"
    check_signal "plan_reviewer: neither label present -> 2/partial" \
        'plan_signal("impl-label,plan-label", "{\"labels\":[\"other\"]}")' "2"
    check_signal "plan_reviewer: single-field CSV (no plan slot) -> 1/success" \
        'plan_signal("impl-label", "{\"labels\":[\"impl-label\"]}")' "1"
    rm -rf "$CMP_TMP"
else
    echo "[SKIP] agentis binary not found — cluster B1 comparator signal checks skipped"
fi

# ----- Cluster B2 comparators: flat CB-safe rewrites (#1638 P3, allowlist 2->0) --
# The final 2 verdict scorers overflowed cb_per_tick with a naive per-element
# walk and so were split out of B1: prioritizer's `score_priority_verdict_key`
# ran is_pri (~283 CB) per label (462 @2, 1892 @12, OVERFLOW @16 — the #1640
# class), and ship_decider's `evaluate_ship_verdict` computed set(CUR)-set(BASE)
# as an O(|cur|x|base|) nested walk over the full, monotonically growing dev-app
# tag history (6749 CB already at 26 tags). Both were rewritten flat — prioritizer
# via ONE regex_find_all(PRISET) over the raw label array, ship_decider via a
# free `cur == baseline` early-exit + a union-length set-difference. Two
# properties are pinned: (a) VALUE-IDENTITY of each signal vs the retired python,
# and (b) a CB REGRESSION guard — the rewrite completes under `cb 2000;` (the
# enforced cb_per_tick) at label/tag counts the naive walk overflowed at. Gated
# on the agentis binary (CI runners have none).
if command -v agentis >/dev/null 2>&1; then
    B2_TMP="$(mktemp -d)"
    B2_HELPERS='fn member(x: string, xs: list<string>) -> bool {
    return len(filter(xs, |y: string| -> bool { return y == x; })) > 0;
}
fn str_replace_all(hay: string, needle: string, rep: string) -> string {
    let p = index_of(hay, needle);
    if p < 0 { return hay; };
    return substring(hay, 0, p) + rep + str_replace_all(substring(hay, p + len(needle), len(hay)), needle, rep);
}
fn regex_escape(s: string) -> string {
    let a = str_replace_all(s, "\\", "\\\\");
    let b = str_replace_all(a, ".", "\\.");
    let c = str_replace_all(b, "+", "\\+");
    let d = str_replace_all(c, "*", "\\*");
    let e = str_replace_all(d, "?", "\\?");
    let f = str_replace_all(e, "(", "\\(");
    let g = str_replace_all(f, ")", "\\)");
    let h = str_replace_all(g, "[", "\\[");
    let i = str_replace_all(h, "]", "\\]");
    let j = str_replace_all(i, "{", "\\{");
    let k = str_replace_all(j, "}", "\\}");
    let l = str_replace_all(k, "^", "\\^");
    let m = str_replace_all(l, "$", "\\$");
    return str_replace_all(m, "|", "\\|");
}
fn pvalt(pv_toks: list<string>) -> string {
    let extra = filter(pv_toks, |t: string| -> bool {
        if index_of(t, "priority") == 0 { return false; };
        if regex_match("^p[0-9]+$", t) { return false; };
        if t == "urgent" { return false; };
        return true;
    });
    return reduce(extra, |acc: string, t: string| -> string {
        return acc + "|" + regex_escape(t);
    }, "");
}
fn priority_signal(suggested: string, cur_raw: string, vocab: string) -> int {
    let pv_toks = filter(map(regex_split(",", to_lower(vocab)), |t: string| -> string {
        return trim(t);
    }), |t: string| -> bool {
        return len(t) > 0;
    });
    let pva = pvalt(pv_toks);
    let labels_lc = to_lower(try { json_get_raw(cur_raw, "labels"); } catch e { ""; });
    let PRISET = "\"[ ]*(?:priority[^\"]*|(?:p[0-9]+|urgent" + pva + ")[ ]*)\"";
    let pri = regex_find_all(PRISET, labels_lc);
    let sug_q = "\"" + to_lower(trim(suggested)) + "\"";
    let ours = member(sug_q, pri);
    let others = filter(pri, |m: string| -> bool {
        return m != sug_q;
    });
    let signal = if len(pri) == 0 {
        0;
    } else {
        if ours {
            if len(others) == 0 { 1; } else { 2; };
        } else {
            3;
        };
    };
    return signal;
}
fn ship_diff_signal(baseline: string, cur: string) -> int {
    if cur == baseline { return 0; };
    let base_u = sort_unique_strings(filter(regex_split(",", baseline), |x: string| -> bool {
        return len(x) > 0;
    }));
    let union = sort_unique_strings(filter(regex_split(",", baseline + "," + cur), |x: string| -> bool {
        return len(x) > 0;
    }));
    if len(union) > len(base_u) { return 1; };
    return 0;
}'
    run_b2() {
        local budget="$1" body="$2" sandbox
        sandbox="$(mktemp -d -p "$B2_TMP")"
        (
            cd "$sandbox"
            agentis init >/dev/null 2>&1
            {
                printf 'cb %s;\n\n%s\n\n%s\n' "$budget" "$B2_HELPERS" "$body"
            } > probe.ag
            agentis go probe.ag 2>/dev/null | grep -v genesis | tail -n 1
        )
        rm -rf "$sandbox"
    }
    check_b2() {
        local label="$1" call="$2" want="$3" got
        got="$(run_b2 8000 "print($call);")"
        if [ "$got" = "$want" ]; then
            pass "$label"
        else
            fail "$label (want='$want' got='$got')"
        fi
    }
    # -- prioritizer (score_priority_verdict_key) value-identity: 0 no pri-label,
    # 1 ours-only, 2 ours+other-pri, 3 other-pri-only; case-insensitive P1/p1;
    # legacy urgent + custom-pv token; malformed/missing raw -> 0/pending.
    DEFPV="priority::low,priority::medium,priority::high,priority::critical"
    check_b2 "prioritizer: no priority-like label yet -> 0/keep" \
        "priority_signal(\"P1\", \"{\\\"labels\\\":[\\\"bug\\\",\\\"docs\\\"]}\", \"$DEFPV\")" "0"
    check_b2 "prioritizer: our label is the only priority one -> 1/success" \
        "priority_signal(\"P1\", \"{\\\"labels\\\":[\\\"bug\\\",\\\"p1\\\"]}\", \"$DEFPV\")" "1"
    check_b2 "prioritizer: ours + a different priority label -> 2/partial" \
        'priority_signal("P1", "{\"labels\":[\"p1\",\"p2\"]}", "priority::low")' "2"
    check_b2 "prioritizer: a different priority label, not ours -> 3/override" \
        'priority_signal("P1", "{\"labels\":[\"p2\"]}", "priority::low")' "3"
    check_b2 "prioritizer: case-insensitive Priority::High match -> 1/success" \
        'priority_signal("Priority::High", "{\"labels\":[\"Priority::High\"]}", "priority::high")' "1"
    check_b2 "prioritizer: legacy urgent ours-only -> 1/success" \
        'priority_signal("urgent", "{\"labels\":[\"urgent\"]}", "priority::low")' "1"
    check_b2 "prioritizer: custom-pv token blocker ours-only -> 1/success" \
        'priority_signal("blocker", "{\"labels\":[\"blocker\"]}", "blocker,priority::high")' "1"
    check_b2 "prioritizer: custom-pv exact-not-prefix (highway vs high) not priority -> 0" \
        'priority_signal("P1", "{\"labels\":[\"highway\"]}", "high")' "0"
    check_b2 "prioritizer: malformed cur_raw -> 0/keep (python try/except parity)" \
        'priority_signal("P1", "not json at all", "priority::low")' "0"
    check_b2 "prioritizer: empty labels array -> 0/keep" \
        'priority_signal("P1", "{\"labels\":[]}", "priority::low")' "0"
    check_b2 "prioritizer: missing labels key -> 0/keep" \
        'priority_signal("P1", "{\"title\":\"x\"}", "priority::low")' "0"
    # -- ship_decider (evaluate_ship_verdict) value-identity: new tag beyond
    # baseline -> 1/success, unchanged -> 0, both-empty -> 0, first-ever tag -> 1,
    # tag removed (cur subset of base) -> 0, reordered-same-set -> 0.
    check_b2 "ship_decider: new tag beyond baseline -> 1/success" \
        'ship_diff_signal("dev-apprenticeship-v1.0.0", "dev-apprenticeship-v1.0.0,dev-apprenticeship-v1.1.0")' "1"
    check_b2 "ship_decider: tag set unchanged -> 0/pending" \
        'ship_diff_signal("dev-apprenticeship-v1.0.0", "dev-apprenticeship-v1.0.0")' "0"
    check_b2 "ship_decider: both empty (no tags either side) -> 0/pending" \
        'ship_diff_signal("", "")' "0"
    check_b2 "ship_decider: first-ever tag over empty baseline -> 1/success" \
        'ship_diff_signal("", "dev-apprenticeship-v1.0.0")' "1"
    check_b2 "ship_decider: a tag removed (cur subset of baseline) -> 0/pending" \
        'ship_diff_signal("a,b", "a")' "0"
    check_b2 "ship_decider: reordered same set -> 0/pending (union-length parity)" \
        'ship_diff_signal("a,b", "b,a")' "0"

    # -- CB regression guard (the whole reason B2 is split from B1). Run the SAME
    # signal fns under `cb 2000;` (the enforced cb_per_tick) at label/tag counts
    # where the naive per-element walk overflowed, and assert both a correct
    # result AND completion (an overflow prints nothing / an error -> mismatch).
    check_b2_cb() {
        local label="$1" call="$2" want="$3" got
        got="$(run_b2 2000 "print($call);")"
        if [ "$got" = "$want" ]; then
            pass "$label"
        else
            fail "$label (cb 2000 overflow or wrong result: want='$want' got='$got')"
        fi
    }
    # prioritizer: 20 labels (19 non-priority + p1) — naive is_pri-per-label
    # overflowed past ~12; the flat PRISET stays ~349 CB. Expect 1 (ours only).
    PRI20='{\"labels\":[\"l0\",\"l1\",\"l2\",\"l3\",\"l4\",\"l5\",\"l6\",\"l7\",\"l8\",\"l9\",\"l10\",\"l11\",\"l12\",\"l13\",\"l14\",\"l15\",\"l16\",\"l17\",\"l18\",\"p1\"]}'
    check_b2_cb "prioritizer: 20 labels under cb 2000 -> 1 (flat, was #1640 overflow)" \
        "priority_signal(\"P1\", \"$PRI20\", \"$DEFPV\")" "1"
    # ship_decider: baseline 20 tags, cur = same 20 + 1 new — naive set-difference
    # was 6749 CB @26 tags; the union-length test stays ~1.5k CB. Expect 1.
    SHIP_BASE=""; SHIP_CUR=""
    for i in $(seq 0 19); do
        t="dev-apprenticeship-v1.$i.0"
        if [ -z "$SHIP_BASE" ]; then SHIP_BASE="$t"; else SHIP_BASE="$SHIP_BASE,$t"; fi
    done
    SHIP_CUR="$SHIP_BASE,dev-apprenticeship-v1.20.0"
    check_b2_cb "ship_decider: 21-tag diff under cb 2000 -> 1 (flat, was 6749 CB @26 tags)" \
        "ship_diff_signal(\"$SHIP_BASE\", \"$SHIP_CUR\")" "1"
    # ship_decider: the dominant no-release path (cur == baseline) at 20 tags must
    # early-exit for free — 0, no union split at all.
    check_b2_cb "ship_decider: 20-tag no-change under cb 2000 -> 0 (free early-exit)" \
        "ship_diff_signal(\"$SHIP_BASE\", \"$SHIP_BASE\")" "0"
    rm -rf "$B2_TMP"
else
    echo "[SKIP] agentis binary not found — cluster B2 comparator + CB-sweep checks skipped"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
