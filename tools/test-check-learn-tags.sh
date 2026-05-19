#!/bin/bash
# tools/test-check-learn-tags.sh: unit tests for tools/check-learn-tags.sh.
#
# Self-contained. Creates temporary .ag fixture files, runs the checker
# against them, asserts exit code + output pattern. Cleans up on exit.
#
# Usage: ./tools/test-check-learn-tags.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-learn-tags.sh"

if [ ! -x "$CHECKER" ]; then
    echo "[FAIL] checker not found or not executable: $CHECKER"
    exit 1
fi

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

# write_fixture <name> <content>
# Returns: path to the fixture file via stdout.
write_fixture() {
    local name="$1"
    local content="$2"
    local path="$TMPDIR_TEST/$name.ag"
    printf '%s' "$content" > "$path"
    printf '%s' "$path"
}

# run_checker <fixture-path> [strict]
# Captures combined stdout+stderr in $out, exit code in $rc.
run_checker() {
    set +e
    if [ "${2:-0}" = "1" ]; then
        out="$(COLONY_LINT_STRICT_LEARN_TAGS=1 "$CHECKER" "$1" 2>&1)"
    else
        out="$("$CHECKER" "$1" 2>&1)"
    fi
    rc=$?
    set -e
}

# --- Test 1: positive snapshot — current hunter.ag must pass clean ---
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run_checker "$REPO_ROOT/tribes-bench/tribe-alpha/agents/hunter.ag"
if [ "$rc" -eq 0 ]; then
    pass "snapshot tribe-alpha hunter.ag passes (0 violations, exit 0)"
else
    fail "snapshot tribe-alpha hunter.ag" "rc=$rc out=$out"
fi

# Loop over all 5 tribes too — same expectation.
all_tribes_ok=1
for trb in alpha beta gamma delta epsilon; do
    run_checker "$REPO_ROOT/tribes-bench/tribe-$trb/agents/hunter.ag"
    if [ "$rc" -ne 0 ]; then
        all_tribes_ok=0
        echo "  tribe-$trb: rc=$rc out=$out"
    fi
done
if [ "$all_tribes_ok" = "1" ]; then
    pass "snapshot all 5 tribes (alpha/beta/gamma/delta/epsilon) pass clean"
else
    fail "snapshot all 5 tribes" "at least one tribe failed (see above)"
fi

# --- Test 2: violation A — extraneous parametric tag ---
f="$(write_fixture "violation-fake-reward" '
fn tick() -> void {
    learn("hunt", "line 1", "x", "success", ["acted", "tribes-bench", "tribe-alpha", "fake-reward=999"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && [ -n "$out" ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=hunt outcome=success unexpected tag fake-reward=999"); then
    pass "violation-A: hunt/success rejects fake-reward=999 with exit 2"
else
    fail "violation-A" "rc=$rc out=$out"
fi

# --- Test 3: violation B — replicated tag under hunt/success ---
f="$(write_fixture "violation-replicated" '
fn tick() -> void {
    learn("hunt", "k", "v", "success", ["acted", "replicated", "tribes-bench"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=hunt outcome=success unexpected tag replicated"); then
    pass "violation-B: hunt/success rejects replicated tag with exit 2"
else
    fail "violation-B" "rc=$rc out=$out"
fi

# --- Test 4: unknown (topic, outcome) pair ---
f="$(write_fixture "unknown-pair" '
fn tick() -> void {
    learn("promote_self", "k", "v", "success", ["tribes-bench"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: unknown (topic=promote_self, outcome=success)"); then
    pass "unknown-pair: promote_self/success rejected with exit 2"
else
    fail "unknown-pair" "rc=$rc out=$out"
fi

# --- Test 5: variable-bound tag list — WARN default, FAIL under strict ---
f="$(write_fixture "variable-tag-list" '
fn tick() -> void {
    let dyn_tags = ["acted", "tribes-bench"];
    learn("hunt", "k", "v", "success", dyn_tags);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && (printf '%s' "$out" | grep -q "WARN: non-literal tag list"); then
    pass "variable-tag-list (default): WARN, exit 0"
else
    fail "variable-tag-list default" "rc=$rc out=$out"
fi

run_checker "$f" 1
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: non-literal tag list"); then
    pass "variable-tag-list (strict): VIOLATION, exit 2"
else
    fail "variable-tag-list strict" "rc=$rc out=$out"
fi

# --- Test 6: known parametric tag — reward=<int> accepted ---
f="$(write_fixture "ok-parametric-reward" '
fn tick() -> void {
    learn("hunt", "k", "v", "success", ["acted", "tribes-bench", _tribe_name, "reward=" + to_string(actual_reward)]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-parametric-reward: reward=<int> accepted, exit 0, no warn"
else
    fail "ok-parametric-reward" "rc=$rc out=$out"
fi

# --- Test 7: known parametric tag — buyer:<tn> accepted ---
f="$(write_fixture "ok-parametric-buyer" '
fn tick() -> void {
    learn("market", topic, "", "cache_hit", ["tribes-bench", "buyer:" + _tribe_name, "topic_kind:finding"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-parametric-buyer: buyer:<tn> + topic_kind:finding accepted, exit 0"
else
    fail "ok-parametric-buyer" "rc=$rc out=$out"
fi

# --- Test 8: tribe-name placeholder — _tribe_name accepted where <tn> allowed ---
f="$(write_fixture "ok-tribe-name" '
fn tick() -> void {
    learn("self_death", _tribe_name, "age=1", "failure", ["died", "self-aged", "tribes-bench", _tribe_name]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-tribe-name: _tribe_name accepted in self_death/failure, exit 0"
else
    fail "ok-tribe-name" "rc=$rc out=$out"
fi

# --- Test 9: suppression marker on same line silences the violation ---
f="$(write_fixture "suppressed-same-line" '
fn tick() -> void {
    learn("hunt", "k", "v", "success", ["acted", "tribes-bench", "fake-reward=999"]); // colony-lint: learn-tags-ok
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "suppressed-same-line: marker on the learn() line silences finding"
else
    fail "suppressed-same-line" "rc=$rc out=$out"
fi

# --- Test 10: suppression marker on preceding line silences ---
f="$(write_fixture "suppressed-prev-line" '
fn tick() -> void {
    // colony-lint: learn-tags-ok
    learn("hunt", "k", "v", "success", ["acted", "tribes-bench", "fake-reward=999"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "suppressed-prev-line: marker on prev line silences finding"
else
    fail "suppressed-prev-line" "rc=$rc out=$out"
fi

# --- Test 11: usage error — scan root does not exist ---
set +e
out="$("$CHECKER" /nonexistent/path/that/does/not/exist 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 3 ]; then
    pass "usage-error: missing scan root returns exit 3"
else
    fail "usage-error" "rc=$rc out=$out"
fi

# --- Test 12: replicate/failure accepts all 3 failure modes ---
f="$(write_fixture "ok-replicate-failures" '
fn tick() -> void {
    learn("replicate", "n=1", "cost=2", "failure", ["replicate-skip", "tribes-bench", _tribe_name]);
    learn("replicate", "n=1", "cost=2", "failure", ["replicate-error", "tribes-bench", _tribe_name]);
    learn("replicate", "n=1", "cost=2", "failure", ["replicate-nak", "tribes-bench", _tribe_name]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-replicate-failures: all 3 failure-modes accepted"
else
    fail "ok-replicate-failures" "rc=$rc out=$out"
fi

# --- Test 13: tribe-name placeholder NOT allowed for hunt/failure (no <tn>) ---
f="$(write_fixture "violation-tribe-name-where-disallowed" '
fn tick() -> void {
    learn("hunt", "k", "v", "failure", ["false-positive", "tribes-bench", _tribe_name]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=hunt outcome=failure unexpected tag _tribe_name"); then
    pass "violation-tribe-name-disallowed: hunt/failure does not allow _tribe_name"
else
    fail "violation-tribe-name-disallowed" "rc=$rc out=$out"
fi

# --- Test 14: inline marker on prev line does NOT bleed to next learn() (#510) ---
f="$(write_fixture "inline-marker-no-bleed" '
fn tick(rec: string) -> void {
    learn("hunt", "x", "y", "success", ["acted", "tribes-bench", "fake1"]); // colony-lint: learn-tags-ok
    learn("hunt", "x", "y", "success", ["acted", "tribes-bench", "fake2"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=hunt outcome=success unexpected tag fake2"); then
    pass "inline-marker-no-bleed: inline marker silences own line only, next-line violation still reported (#510)"
else
    fail "inline-marker-no-bleed" "rc=$rc out=$out"
fi

# --- #634 follow-up: synthetic fixtures for research-fed schema additions ---
# The 0.1.0+ research-foundry schemas (math-foundry + claim-auditor +
# preprint-foundry) were previously exercised only via the in-tree .ag
# files. Tests 15-22 add per-pair synthetic fixtures so future schema
# regressions land via tight unit tests rather than the CI-on-real-file
# path.

# --- Test 15: math-foundry explore:partial accepts the propose-tier tag set ---
f="$(write_fixture "ok-explore-partial" '
fn tick() -> void {
    learn("explore", "k", "v", "partial", ["acted", "review-gated", "emitted", "observed", "math-foundry"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-explore-partial: math-foundry explore/partial tag set accepted"
else
    fail "ok-explore-partial" "rc=$rc out=$out"
fi

# --- Test 16: math-foundry settle:success accepts verdict:<bareword> parametric ---
f="$(write_fixture "ok-settle-success-verdict" '
fn tick() -> void {
    learn("settle", "k", "v", "success", ["acted", "math-foundry", _colony_name, "verdict:" + verdict_raw]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-settle-success-verdict: math-foundry settle/success accepts verdict:<bareword>"
else
    fail "ok-settle-success-verdict" "rc=$rc out=$out"
fi

# --- Test 17: math-foundry verify:failure rejects unknown tag ---
f="$(write_fixture "violation-verify-failure-bad" '
fn tick() -> void {
    learn("verify", "k", "v", "failure", ["acted", "math-foundry", "bogus-tag"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=verify outcome=failure unexpected tag bogus-tag"); then
    pass "violation-verify-failure-bad: math-foundry verify/failure rejects bogus-tag"
else
    fail "violation-verify-failure-bad" "rc=$rc out=$out"
fi

# --- Test 18: claim-auditor arxiv-search:partial accepts propose tag set ---
f="$(write_fixture "ok-arxiv-search-partial" '
fn tick() -> void {
    learn("arxiv-search", "k", "v", "partial", ["acted", "review-gated", "observed", "claim-auditor"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-arxiv-search-partial: claim-auditor arxiv-search/partial tag set accepted"
else
    fail "ok-arxiv-search-partial" "rc=$rc out=$out"
fi

# --- Test 19: claim-auditor audit:success accepts propose-tier emit ---
f="$(write_fixture "ok-audit-success" '
fn tick() -> void {
    learn("audit", "k", "v", "success", ["acted", "review-gated", "emitted", "observed", "claim-auditor"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-audit-success: claim-auditor audit/success tag set accepted"
else
    fail "ok-audit-success" "rc=$rc out=$out"
fi

# --- Test 20: claim-auditor scholar-search:success rejects tribes-bench tag ---
f="$(write_fixture "violation-scholar-search-wrong-fed" '
fn tick() -> void {
    learn("scholar-search", "k", "v", "success", ["acted", "tribes-bench"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=scholar-search outcome=success unexpected tag tribes-bench"); then
    pass "violation-scholar-search-wrong-fed: claim-auditor scholar-search/success rejects tribes-bench tag"
else
    fail "violation-scholar-search-wrong-fed" "rc=$rc out=$out"
fi

# --- Test 21: preprint-foundry submit:success accepts hitl-gated literal ---
f="$(write_fixture "ok-submit-hitl-gated" '
fn tick() -> void {
    learn("submit", "k", "v", "success", ["acted", "review-gated", "emitted", "observed", "preprint-foundry", "hitl-gated"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-submit-hitl-gated: preprint-foundry submit/success accepts hitl-gated literal"
else
    fail "ok-submit-hitl-gated" "rc=$rc out=$out"
fi

# --- Test 22: preprint-foundry edit:partial rejects hitl-gated where disallowed ---
f="$(write_fixture "violation-edit-partial-hitl-gated" '
fn tick() -> void {
    learn("edit", "k", "v", "partial", ["acted", "preprint-foundry", "hitl-gated"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 2 ] && (printf '%s' "$out" | grep -q "VIOLATION: topic=edit outcome=partial unexpected tag hitl-gated"); then
    pass "violation-edit-partial-hitl-gated: preprint-foundry edit/partial rejects hitl-gated (only submit allows it)"
else
    fail "violation-edit-partial-hitl-gated" "rc=$rc out=$out"
fi

# --- Test 23: math-foundry replicate:success accepts math-foundry + <cn> ---
f="$(write_fixture "ok-replicate-success-math-foundry" '
fn tick() -> void {
    learn("replicate", "n=1", "cost=2", "success", ["replicated", "math-foundry", _colony_name]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "ok-replicate-success-math-foundry: replicate/success accepts math-foundry + _colony_name (<cn>)"
else
    fail "ok-replicate-success-math-foundry" "rc=$rc out=$out"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
