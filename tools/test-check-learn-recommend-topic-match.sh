#!/bin/bash
# tools/test-check-learn-recommend-topic-match.sh: unit tests for
# tools/check-learn-recommend-topic-match.sh.
#
# Self-contained. Creates temporary .ag fixture files, runs the
# checker against them, asserts exit code + output pattern. Cleans up
# on exit.
#
# Coverage:
#   * single-line learn() / recommend() shape (pre-#635 contract).
#   * multi-line learn(\n  "<topic>", ...) shape used by four
#     dev-apprenticeship planning agents (#635 fix).
#   * multi-line recommend() shape.
#   * mismatched topics under both shapes (subset-violation path).
#
# Usage: ./tools/test-check-learn-recommend-topic-match.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-learn-recommend-topic-match.sh"

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

write_fixture() {
    local name="$1"
    local content="$2"
    local path="$TMPDIR_TEST/$name.ag"
    printf '%s' "$content" > "$path"
    printf '%s' "$path"
}

run_checker() {
    set +e
    out="$("$CHECKER" "$1" 2>&1)"
    rc=$?
    set -e
}

# --- Test 1: single-line matching topics -> exit 0 ---
f="$(write_fixture "single-line-match" '
fn tick() -> void {
    let rec = recommend("review_plan", ["completeness"]);
    learn("review_plan", "k", "v", "success", ["acted", "planning"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "single-line-match: recommend + learn on same topic, exit 0"
else
    fail "single-line-match" "rc=$rc out=$out"
fi

# --- Test 2: single-line mismatched topics -> violation ---
f="$(write_fixture "single-line-mismatch" '
fn tick() -> void {
    let rec = recommend("topic_a", []);
    learn("topic_b", "k", "v", "success", ["acted"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "VIOLATION: recommend(\"topic_a\", ...)"); then
    pass "single-line-mismatch: topic_a recommended but only topic_b learned"
else
    fail "single-line-mismatch" "rc=$rc out=$out"
fi

# --- Test 3: multi-line learn() with matching recommend -> exit 0 (#635) ---
f="$(write_fixture "multi-line-learn-match" '
fn tick() -> void {
    let rec = recommend("review_plan", ["completeness"]);
    learn(
        "review_plan",
        "issue 42",
        "posted",
        "success",
        ["acted", "planning"]
    );
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "multi-line-learn-match: parser handles multi-line learn() (#635)"
else
    fail "multi-line-learn-match" "rc=$rc out=$out"
fi

# --- Test 4: multi-line learn() with mismatched recommend -> violation (#635) ---
f="$(write_fixture "multi-line-learn-mismatch" '
fn tick() -> void {
    let rec = recommend("review_plan", ["completeness"]);
    learn(
        "different_topic",
        "issue 42",
        "posted",
        "success",
        ["acted", "planning"]
    );
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "VIOLATION: recommend(\"review_plan\", ...)"); then
    pass "multi-line-learn-mismatch: multi-line learn() with non-matching topic surfaces violation (#635)"
else
    fail "multi-line-learn-mismatch" "rc=$rc out=$out"
fi

# --- Test 5: multi-line recommend() + multi-line learn() matching -> exit 0 (#635) ---
f="$(write_fixture "multi-line-both-match" '
fn tick() -> void {
    let rec = recommend(
        "review_plan",
        ["completeness"]
    );
    learn(
        "review_plan",
        "issue 42",
        "posted",
        "success",
        ["acted", "planning"]
    );
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "multi-line-both-match: multi-line recommend() + learn() with same topic, exit 0 (#635)"
else
    fail "multi-line-both-match" "rc=$rc out=$out"
fi

# --- Test 6: recommend without any learn -> violation ---
f="$(write_fixture "recommend-no-learn" '
fn tick() -> void {
    recommend("topic_a", []);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "VIOLATION: recommend(\"topic_a\", ...)"); then
    pass "recommend-no-learn: bare recommend() without any learn() surfaces violation"
else
    fail "recommend-no-learn" "rc=$rc out=$out"
fi

# --- Test 7: file with no recommend / learn -> exit 0 ---
f="$(write_fixture "no-calls" '
fn tick() -> void {
    let x = 1;
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "no-calls: vacuously clean"
else
    fail "no-calls" "rc=$rc out=$out"
fi

# --- Test 8: dynamic / variable-driven topic on learn() is silently skipped ---
# `learn(topic_var, ...)` should not pollute the learn_topics set; the
# matching `recommend("foo", ...)` should therefore violate.
f="$(write_fixture "dynamic-learn-topic" '
fn tick() -> void {
    let rec = recommend("foo", []);
    learn(topic_var, "k", "v", "success", ["acted"]);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "VIOLATION: recommend(\"foo\", ...)"); then
    pass "dynamic-learn-topic: variable-driven learn() topic does not satisfy recommend(\"foo\")"
else
    fail "dynamic-learn-topic" "rc=$rc out=$out"
fi

# --- Test 9: real dev-apprenticeship plan_reviewer.ag passes clean (#635) ---
# The 4 planning agents use multi-line learn() shapes; verify all 4
# now pass the lint post-#635 with the parser extension.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
all_clean=1
for ag in \
    "$REPO_ROOT/dev-apprenticeship/planning/agents/plan_reviewer.ag" \
    "$REPO_ROOT/dev-apprenticeship/planning/agents/risk_assessor.ag" \
    "$REPO_ROOT/dev-apprenticeship/planning/agents/scope_estimator.ag" \
    "$REPO_ROOT/dev-apprenticeship/planning/agents/task_decomposer.ag"; do
    if [ ! -f "$ag" ]; then
        all_clean=0
        echo "  missing fixture: $ag"
        continue
    fi
    run_checker "$ag"
    if [ "$rc" -ne 0 ]; then
        all_clean=0
        echo "  $ag: rc=$rc out=$out"
    fi
done
if [ "$all_clean" = "1" ]; then
    pass "dev-apprenticeship planning agents (4) pass lint with multi-line learn() shape (#635)"
else
    fail "dev-apprenticeship planning agents" "at least one agent failed (see above)"
fi

# --- Test 10: usage error -- scan root does not exist ---
set +e
out="$("$CHECKER" /nonexistent/path/that/does/not/exist 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 2 ]; then
    pass "usage-error: missing scan root returns exit 2"
else
    fail "usage-error" "rc=$rc out=$out"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
