#!/bin/bash
# tools/test-no-duplicate-learn.sh: unit tests for tools/check-no-duplicate-learn.sh.
#
# Self-contained. Creates temporary .ag fixture files, runs the checker
# against them, asserts exit code + output pattern. Cleans up on exit.
#
# Usage: ./tools/test-no-duplicate-learn.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-no-duplicate-learn.sh"

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

# --- Test 1: positive snapshot — repo root must pass clean ---
# Post-#636 fix, all research-foundry helpers must gate their
# emitted learn() on `if my_tier == "propose"`.
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run_checker "$REPO_ROOT"
if [ "$rc" -eq 0 ]; then
    pass "snapshot repo root passes (0 violations, exit 0)"
else
    fail "snapshot repo root" "rc=$rc out=$out"
fi

# --- Test 2: violation — unconditional emitted learn() in _publish_<role> ---
f="$(write_fixture "violation-unconditional" '
fn _publish_foo(
    final_write: bool,
    self_pid: string,
    tick_idx: int
) -> void {
    let _ = final_write;
    memo_write("foo:" + self_pid, "ok");
    learn("foo", "tick " + to_string(tick_idx), "x", "success", ["emitted", "math-foundry"]);
}

fn tick(rec: string) -> void {
    let _ = rec;
    _publish_foo(true, "p", 0);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "_publish_foo unconditional emitted learn"); then
    pass "violation: _publish_foo with unconditional emitted learn() rejected"
else
    fail "violation-unconditional" "rc=$rc out=$out"
fi

# --- Test 3: clean — emitted learn() gated on `if my_tier == "propose"` ---
f="$(write_fixture "clean-gated" '
fn _publish_foo(
    final_write: bool,
    self_pid: string,
    tick_idx: int,
    my_tier: string
) -> void {
    let _ = final_write;
    memo_write("foo:" + self_pid, "ok");
    if my_tier == "propose" {
        learn("foo", "tick " + to_string(tick_idx), "x", "success", ["emitted", "math-foundry"]);
    };
}

fn tick(rec: string) -> void {
    let _ = rec;
    let my_tier = tier("foo");
    _publish_foo(true, "p", 0, my_tier);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ]; then
    pass "clean: emitted learn() gated on propose passes"
else
    fail "clean-gated" "rc=$rc out=$out"
fi

# --- Test 4: violation — _submitter_<phase> helper with unconditional emitted ---
f="$(write_fixture "violation-submitter-phase" '
fn _submitter_draft_phase(
    self_pid: string,
    tick_idx: int
) -> void {
    memo_write("submitter:" + self_pid, "drafted");
    learn("submit", "tick " + to_string(tick_idx) + " DRAFTED", "x", "success", ["emitted", "preprint-foundry"]);
}

fn tick(rec: string) -> void {
    let _ = rec;
    _submitter_draft_phase("p", 0);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && (printf '%s' "$out" | grep -q "_submitter_draft_phase unconditional emitted learn"); then
    pass "violation: _submitter_draft_phase with unconditional emitted learn() rejected"
else
    fail "violation-submitter-phase" "rc=$rc out=$out"
fi

# --- Test 5: _publish_prompt_body_and_wrap_variant helper is skipped ---
# This helper is a name-collision with the `fn _publish_<role>` pattern
# but never calls learn(). Must not be flagged.
f="$(write_fixture "skip-wrap-variant" '
fn _publish_prompt_body_and_wrap_variant(self_pid: string, variant_tag: string) -> string {
    let _ = self_pid;
    let _ = variant_tag;
    return "ok";
}

fn tick(rec: string) -> void {
    let _ = rec;
    let _ = _publish_prompt_body_and_wrap_variant("p", "v");
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ]; then
    pass "skip: _publish_prompt_body_and_wrap_variant is not flagged"
else
    fail "skip-wrap-variant" "rc=$rc out=$out"
fi

# --- Test 6: learn() without "emitted" tag is not flagged ---
f="$(write_fixture "clean-non-emitted" '
fn _publish_foo(self_pid: string, tick_idx: int) -> void {
    memo_write("foo:" + self_pid, "ok");
    learn("foo", "tick " + to_string(tick_idx), "x", "success", ["replicated", "math-foundry"]);
}

fn tick(rec: string) -> void {
    let _ = rec;
    _publish_foo("p", 0);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ]; then
    pass "clean: learn() with replicated tag (not emitted) passes"
else
    fail "clean-non-emitted" "rc=$rc out=$out"
fi

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
