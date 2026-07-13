#!/bin/bash
# tools/test-reality-check-wave2.sh: source-asserts the #1453 Wave 2
# reality-check feedback loop as it rolls out across the remaining
# self-reporting agents (one milestone at a time — see the umbrella plan on
# issue #1453). Mirrors tools/test-reality-check-wave1.sh's check_agent helper.
#
# M1 (code-review, 5 agents): logic/security/style/test reviewers score the
# fate of the MR their findings were posted on (merged & head-changed => the
# findings were addressed; merged as-is / closed-unmerged => partial), and
# qa_reviewer scores whether its pass/block verdict held up against the MR's
# terminal state — crucially, a block that merged anyway is a FAILURE (the
# #1484 safety-override signal the auto-merge gate must learn from).
#
# Per agent this asserts (the Wave-1 shape):
#   1. record_<x>_verdict and evaluate_<x>_verdict fns exist
#   2. the single-slot memo key literal "<agent>:pending_verdict" is
#      written AND read via scoped_memo (per-repo, #316)
#   3. evaluate is invoked at the TOP of tick_for_repo (first lines,
#      before any early-return work)
#   4. the 24h ageout literal (86400) guards the evaluate
#   5. the evaluate learn() carries the agent's recommend() topic and
#      the "acted" tag (auto-promote acting bucket)
#   6. the ground-truth re-query uses the agreed mechanical primitive
#      (bounded merged/closed list scan via the native iid_in_list helper) —
#      never a prompt()
#   7. the expected number of stash call sites (definition + N calls)
# Plus the M1-specific safety assert:
#   - qa_reviewer maps `block & merged` to the failure signal (3)
#   - the outcome enum is "failure" across the five M1 agents (core rejects
#     "fail" at runtime)
#
# Usage: ./tools/test-reality-check-wave2.sh
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

CR="$FED/code-review/agents"

# The four line reviewers: stash at the two acting tiers that POST a findings
# note (autonomous real + review-gated draft), so 3 = definition + 2 calls.
# Ground truth: bounded merged/closed list scan via the native iid_in_list
# helper (merged parsed FIRST, --per-page 50).
check_agent "$CR/logic_reviewer.ag"    "logic_reviewer"    "logic"    "logic_review"    3 \
    "--state merged --per-page 50" "--state closed --per-page 50" "iid_in_list("
check_agent "$CR/security_reviewer.ag" "security_reviewer" "security" "security_review" 3 \
    "--state merged --per-page 50" "--state closed --per-page 50" "iid_in_list("
check_agent "$CR/style_reviewer.ag"    "style_reviewer"    "style"    "style_review"    3 \
    "--state merged --per-page 50" "--state closed --per-page 50" "iid_in_list("
check_agent "$CR/test_reviewer.ag"     "test_reviewer"     "test"     "test_review"     3 \
    "--state merged --per-page 50" "--state closed --per-page 50" "iid_in_list("

# qa_reviewer: blob is [ts, mr_iid, "pass|block"]; same bounded list scan.
check_agent "$CR/qa_reviewer.ag"       "qa_reviewer"       "qa"       "qa_review"       3 \
    "--state merged --per-page 50" "--state closed --per-page 50" "iid_in_list("

# M1 safety assert: qa_reviewer must score `block & merged` as the FAILURE
# signal (3) — the auto-merge-override case (#1484). Getting this backwards
# would reward a bypassed block as a success and defeat the whole point of
# putting the highest-value verdict in the loop.
QA_REGION="$(evaluate_region "$CR/qa_reviewer.ag" "evaluate_qa_verdict")"
if printf '%s' "$QA_REGION" | grep -qF 'if status == "block" { 3; }'; then
    pass "qa_reviewer: block & merged maps to the failure signal (3)"
else
    fail "qa_reviewer: block & merged does NOT map to failure (safety-override miss)"
fi

# Outcome enum: "fail" is not a valid learn() outcome (core enforces
# success/failure/partial/timeout/error). Swept across the five M1 agents so a
# reintroduced invalid literal fails the PR (the Wave-1 test sweeps the whole
# federation; this is the M1-local belt-and-braces).
ENUM_FAIL=0
for f in logic_reviewer security_reviewer style_reviewer test_reviewer qa_reviewer; do
    if grep -qE '"fail",|return "fail";' "$CR/$f.ag"; then
        fail "$f: invalid outcome literal \"fail\" survives"
        ENUM_FAIL=1
    fi
done
if [ "$ENUM_FAIL" -eq 0 ]; then
    pass "outcome enum: no invalid \"fail\" literal in the five M1 agents"
fi

# Live byte-identity of the native iid_in_list membership helper (the compare's
# load-bearing primitive): exact-line membership over a json_array_project
# projection, no false match across an iid boundary. Gated on the agentis
# binary (CI runners have none).
if command -v agentis >/dev/null 2>&1; then
    IID_TMP="$(mktemp -d)"
    trap 'rm -rf "$IID_TMP"' EXIT
    IID_HELPER='fn iid_in_list(raw: string, iid_str: string) -> bool {
    if len(iid_str) == 0 { return false; };
    let projected = json_array_project(raw, "", "iid");
    if len(projected) == 0 { return false; };
    return index_of("\n" + projected + "\n", "\n" + iid_str + "\n") >= 0;
}'
    run_iid() {
        local body="$1" sandbox
        sandbox="$(mktemp -d -p "$IID_TMP")"
        (
            cd "$sandbox"
            agentis init >/dev/null 2>&1
            {
                printf 'cb 4000;\n\n%s\n\n%s\n' "$IID_HELPER" "$body"
            } > probe.ag
            agentis go probe.ag 2>/dev/null | grep -v genesis | tail -n 1
        )
        rm -rf "$sandbox"
    }
    check_iid() {
        local label="$1" body="$2" want="$3" got
        got="$(run_iid "$body")"
        if [ "$got" = "$want" ]; then
            pass "$label"
        else
            fail "$label (want='$want' got='$got')"
        fi
    }
    LIST='[{\"iid\":5,\"state\":\"merged\"},{\"iid\":12,\"state\":\"merged\"}]'
    check_iid "iid_in_list: member present" \
        "print(to_string(iid_in_list(\"$LIST\", \"5\")));" "true"
    check_iid "iid_in_list: last member present" \
        "print(to_string(iid_in_list(\"$LIST\", \"12\")));" "true"
    # No cross-boundary false match: "2" must NOT match inside "12".
    check_iid "iid_in_list: no substring false-match (2 vs 12)" \
        "print(to_string(iid_in_list(\"$LIST\", \"2\")));" "false"
    check_iid "iid_in_list: absent member" \
        "print(to_string(iid_in_list(\"$LIST\", \"1\")));" "false"
    check_iid "iid_in_list: empty array -> false" \
        "print(to_string(iid_in_list(\"[]\", \"5\")));" "false"
    check_iid "iid_in_list: malformed JSON -> false" \
        "print(to_string(iid_in_list(\"not json\", \"5\")));" "false"
else
    echo "[SKIP] agentis binary not found — iid_in_list live membership checks skipped"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
