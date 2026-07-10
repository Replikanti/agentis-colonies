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
APPR_REGION="$(evaluate_region "$FED/code-review/agents/approval_decider.ag" "evaluate_approval_verdict")"
if printf '%s' "$APPR_REGION" | grep -q "ml is None" \
    && printf '%s' "$APPR_REGION" | grep -qF 'print(2 if m else (1 if c else 0))'; then
    pass "approval_decider: merged-parse guard + request_changes/merged=partial"
else
    fail "approval_decider: missing merged-parse guard or partial mapping"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
