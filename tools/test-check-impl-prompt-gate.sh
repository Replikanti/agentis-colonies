#!/bin/bash
# tools/test-check-impl-prompt-gate.sh: unit tests for tools/check-impl-prompt-gate.sh.
#
# Self-contained. Creates temporary .ag fixture files, runs the checker
# against them, asserts exit code + output pattern. Cleans up on exit.
#
# Usage: ./tools/test-check-impl-prompt-gate.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-impl-prompt-gate.sh"

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

# --- Test 1: prompt gated by recall_latest in same fn ---
f="$(write_fixture "gated-via-recall" '
fn tick(reason: string) -> void {
    let ts = recall_latest("agent:last_check");
    let classification = prompt("classify", "x") -> string;
    print(classification);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "gated-via-recall: prompt after recall_latest not flagged"
else
    fail "gated-via-recall" "rc=$rc out=$out"
fi

# --- Test 2: prompt gated by call to a gate fn ---
f="$(write_fixture "gated-via-fn" '
fn should_act() -> bool {
    let last = recall_latest("agent:last_check");
    return len(last) > 0;
}

fn tick(reason: string) -> void {
    if should_act() {
        let classification = prompt("classify", "x") -> string;
        print(classification);
    };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "gated-via-fn: prompt after gate-fn call not flagged"
else
    fail "gated-via-fn" "rc=$rc out=$out"
fi

# --- Test 3: bare prompt with no gate is flagged ---
f="$(write_fixture "ungated-bare" '
fn tick(reason: string) -> void {
    let classification = prompt("classify", "x") -> string;
    print(classification);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNGATED\]" && printf '%s' "$out" | grep -q "tick"; then
    pass "ungated-bare: flagged"
else
    fail "ungated-bare" "rc=$rc out=$out"
fi

# --- Test 4: suppression comment on same line ---
f="$(write_fixture "suppressed-same-line" '
fn tick(reason: string) -> void {
    let classification = prompt("classify", "x") -> string; // colony-lint: impl-prompt-gate-ok
    print(classification);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "suppressed-same-line: not flagged"
else
    fail "suppressed-same-line" "rc=$rc out=$out"
fi

# --- Test 5: suppression comment on preceding line ---
f="$(write_fixture "suppressed-preceding" '
fn tick(reason: string) -> void {
    // colony-lint: impl-prompt-gate-ok
    let classification = prompt("classify", "x") -> string;
    print(classification);
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "suppressed-preceding: not flagged"
else
    fail "suppressed-preceding" "rc=$rc out=$out"
fi

# --- Test 6: non-gate fn (no recall_latest in body) does not launder a prompt ---
f="$(write_fixture "fake-gate-fn" '
fn not_a_gate() -> string {
    return "hello";
}

fn tick(reason: string) -> void {
    let x = not_a_gate();
    let classification = prompt("classify", "x") -> string;
    print(classification);
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNGATED\]"; then
    pass "fake-gate-fn: prompt after call to non-gate fn still flagged"
else
    fail "fake-gate-fn" "rc=$rc out=$out"
fi

# --- Test 7: recall_latest in a sibling fn does not count ---
f="$(write_fixture "recall-in-other-fn" '
fn get_confidence() -> float {
    let raw = recall_latest("agent:confidence");
    return parse_float(raw);
}

fn tick(reason: string) -> void {
    let classification = prompt("classify", "x") -> string;
    print(classification);
}
')"
run_checker "$f"
# get_confidence IS a gate fn (it reads recall_latest), but tick() does
# not call it before the prompt, so the prompt must still be flagged.
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNGATED\]"; then
    pass "recall-in-other-fn: uncalled gate-fn does not count"
else
    fail "recall-in-other-fn" "rc=$rc out=$out"
fi

# --- Test 8: multiple prompts in one fn, all after a gate, all clean ---
f="$(write_fixture "multi-prompt-after-gate" '
fn should_act(iid: string) -> bool {
    let last = recall_latest("agent:last_iid");
    return last != iid;
}

fn tick(reason: string) -> void {
    if should_act("42") {
        let a = prompt("first", "x") -> string;
        let b = prompt("second", a) -> string;
        let c = prompt("third", b) -> string;
        print(a, b, c);
    };
}
')"
run_checker "$f"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "multi-prompt-after-gate: all cleared by a single preceding gate call"
else
    fail "multi-prompt-after-gate" "rc=$rc out=$out"
fi

# --- Test 9: fn boundary resets gate state ---
f="$(write_fixture "boundary-reset" '
fn one() -> void {
    let ts = recall_latest("agent:a");
    let x = prompt("ok here", ts) -> string;
}

fn two() -> void {
    let y = prompt("but not here", "x") -> string;
}
')"
run_checker "$f"
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNGATED\]" && printf '%s' "$out" | grep -q "two"; then
    pass "boundary-reset: prompt in second fn flagged, first fn clean"
else
    fail "boundary-reset" "rc=$rc out=$out"
fi

# --- Test 10: regression — current dev-apprenticeship/implementation/agents must pass ---
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
run_checker "$REPO_ROOT/dev-apprenticeship"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "regression: current implementation/agents clean"
else
    fail "regression: current implementation/agents" "rc=$rc out=$out"
fi

# --- Test 11: directory with no implementation/agents is clean ---
empty_dir="$TMPDIR_TEST/empty-fed"
mkdir -p "$empty_dir/other-colony/agents"
cat > "$empty_dir/other-colony/agents/x.ag" <<'AGEOF'
fn tick(reason: string) -> void {
    let y = prompt("x", "y") -> string;
}
AGEOF
run_checker "$empty_dir"
# This file is NOT under */implementation/agents/*, so it must not be scanned.
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "non-implementation-path: not scanned"
else
    fail "non-implementation-path" "rc=$rc out=$out"
fi

# --- Test 12: nonexistent path exits 2 ---
run_checker "$TMPDIR_TEST/does-not-exist"
if [ "$rc" -eq 2 ]; then
    pass "nonexistent: exit code 2"
else
    fail "nonexistent" "rc=$rc out=$out"
fi

# --- Test 13: prompt gated via nested gate fn (gate-fn calls another gate-fn) ---
# We do not do transitive analysis; a gate-fn is defined strictly as a fn
# that contains `recall_latest(` in its own body. Verify this is NOT
# laundered through a wrapper.
f="$(write_fixture "transitive-gate" '
fn inner() -> string {
    let x = recall_latest("agent:a");
    return x;
}

fn wrapper() -> string {
    return inner();
}

fn tick(reason: string) -> void {
    let x = wrapper();
    let y = prompt("q", x) -> string;
}
')"
run_checker "$f"
# `wrapper` is NOT a gate fn (its body has no recall_latest) — by design,
# this must fail so that authors are forced to make the memo read visible.
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "\[UNGATED\]"; then
    pass "transitive-gate: wrapper call does NOT launder (by design)"
else
    fail "transitive-gate" "rc=$rc out=$out"
fi

# --- Test 14: prompt on gate line + multi-line prompt body ---
f="$(write_fixture "multiline-prompt" '
fn tick(reason: string) -> void {
    let ts = recall_latest("agent:last_check");
    let result = prompt(
        "long prompt here",
        ts
    ) -> string;
    print(result);
}
')"
run_checker "$f"
# The `prompt(` token is on its own line. Gate was set above. Must pass.
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "multiline-prompt: gate on earlier line covers multi-line prompt()"
else
    fail "multiline-prompt" "rc=$rc out=$out"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
