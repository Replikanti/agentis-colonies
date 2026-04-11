#!/bin/bash
# tools/test-check-exec-sh.sh: unit tests for tools/check-exec-sh.sh.
#
# Self-contained. Creates temporary .ag fixture files, runs the checker
# against them, asserts exit code + output pattern. Cleans up on exit.
#
# Usage: ./tools/test-check-exec-sh.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-exec-sh.sh"

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

# run_checker <fixture-path>
# Captures stdout+stderr in $out, exit code in $rc.
run_checker() {
    set +e
    out="$("$CHECKER" "$1" 2>&1)"
    rc=$?
    set -e
}

# --- Test 1: string-literal-only exec sh is always safe ---
f="$(write_fixture "literal-only" '
fn tick(reason: string) -> void {
    let raw = try { exec sh "./scripts/gitlab-api.sh members"; } catch e { "[]"; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "literal-only: exec sh \"literal\" not flagged"
else
    fail "literal-only" "rc=$rc out=$out"
fi

# --- Test 2: pure literal assignment (no concat) ---
f="$(write_fixture "pure-literal-assign" '
fn tick(reason: string) -> void {
    let mr_cmd = "./scripts/gitlab-api.sh merge-requests --state merged";
    let result = try { exec sh mr_cmd; } catch e { "[]"; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "pure-literal-assign: no concat, not flagged"
else
    fail "pure-literal-assign" "rc=$rc out=$out"
fi

# --- Test 3: safe concat with shell_escape + to_string ---
f="$(write_fixture "safe-concat" '
fn tick(reason: string) -> void {
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + to_string(action.issue_id) + " --add-labels " + shell_escape(action.labels);
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "safe-concat: shell_escape+to_string not flagged"
else
    fail "safe-concat" "rc=$rc out=$out"
fi

# --- Test 4: UNSAFE bare identifier concat ---
f="$(write_fixture "unsafe-bare-ident" '
fn tick(reason: string) -> void {
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + raw_title;
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNSAFE\]" && printf '%s' "$out" | grep -q "raw_title"; then
    pass "unsafe-bare-ident: flagged"
else
    fail "unsafe-bare-ident" "rc=$rc out=$out"
fi

# --- Test 5: UNSAFE field access concat ---
f="$(write_fixture "unsafe-field" '
fn tick(reason: string) -> void {
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + action.title;
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNSAFE\]" && printf '%s' "$out" | grep -q "action.title"; then
    pass "unsafe-field: flagged"
else
    fail "unsafe-field" "rc=$rc out=$out"
fi

# --- Test 6: UNSAFE bare string variable (LLM-produced) ---
f="$(write_fixture "unsafe-llm-string" '
fn tick(reason: string) -> void {
    let body = prompt("write a body", "");
    let post_cmd = "./scripts/gitlab-api.sh post-note 42 --body " + body;
    let result = try { exec sh post_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNSAFE\]"; then
    pass "unsafe-llm-string: flagged"
else
    fail "unsafe-llm-string" "rc=$rc out=$out"
fi

# --- Test 7: opt-out comment on same line suppresses finding ---
f="$(write_fixture "optout-same-line" '
fn tick(reason: string) -> void {
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + raw_title; // colony-lint: safe-exec-concat
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "optout-same-line: suppressed"
else
    fail "optout-same-line" "rc=$rc out=$out"
fi

# --- Test 8: opt-out comment on preceding line suppresses finding ---
f="$(write_fixture "optout-preceding" '
fn tick(reason: string) -> void {
    // colony-lint: safe-exec-concat
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + raw_title;
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "optout-preceding: suppressed"
else
    fail "optout-preceding" "rc=$rc out=$out"
fi

# --- Test 9: variable never passed to exec sh is never flagged ---
f="$(write_fixture "unused-var" '
fn tick(reason: string) -> void {
    let dangerous = "./scripts/gitlab-api.sh " + raw_title;
    print("built command:", dangerous);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "unused-var: let without exec sh not flagged"
else
    fail "unused-var" "rc=$rc out=$out"
fi

# --- Test 10: function-call assignment (indirection) is not followed ---
f="$(write_fixture "function-indirection" '
fn build() -> string {
    return "./scripts/gitlab-api.sh members";
}

fn tick(reason: string) -> void {
    let cmd = build();
    let result = try { exec sh cmd; } catch e { "[]"; };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "function-indirection: let cmd = fn() not flagged (no concat)"
else
    fail "function-indirection" "rc=$rc out=$out"
fi

# --- Test 11: mixed safe + unsafe segments flags only the unsafe one ---
f="$(write_fixture "mixed-segments" '
fn tick(reason: string) -> void {
    let update_cmd = "./scripts/gitlab-api.sh update-issue " + to_string(action.issue_id) + " --label " + action.label_name;
    let result = try { exec sh update_cmd; } catch e { ""; };
}
')"
run_checker "$f"
unsafe_count="$(printf '%s' "$out" | grep -c "\[UNSAFE\]" || true)"
if [ "$rc" -eq 1 ] && [ "$unsafe_count" -eq 1 ] && printf '%s' "$out" | grep -q "action.label_name"; then
    pass "mixed-segments: only unsafe segment flagged"
else
    fail "mixed-segments" "rc=$rc unsafe_count=$unsafe_count out=$out"
fi

# --- Test 12: regression — actual dev-apprenticeship codebase must pass ---
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run_checker "$REPO_ROOT/dev-apprenticeship"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "regression: current dev-apprenticeship codebase clean"
else
    fail "regression: current dev-apprenticeship codebase" "rc=$rc out=$out"
fi

# --- Test 13: directory with no .ag files ---
empty_dir="$TMPDIR_TEST/empty"
mkdir -p "$empty_dir"
run_checker "$empty_dir"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "empty-dir: no .ag files, clean"
else
    fail "empty-dir" "rc=$rc out=$out"
fi

# --- Test 14: nonexistent path exits 2 ---
run_checker "$TMPDIR_TEST/does-not-exist"
if [ "$rc" -eq 2 ]; then
    pass "nonexistent: exit code 2"
else
    fail "nonexistent" "rc=$rc out=$out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
