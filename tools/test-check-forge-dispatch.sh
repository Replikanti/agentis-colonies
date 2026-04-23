#!/bin/bash
# tools/test-check-forge-dispatch.sh: unit tests for tools/check-forge-dispatch.sh.
#
# Self-contained. Builds temporary colony-shaped trees and asserts exit
# code + output. Cleans up on exit.
#
# Usage: ./tools/test-check-forge-dispatch.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKER="$SCRIPT_DIR/check-forge-dispatch.sh"

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

# make_colony <fed> <colony> <ships_github>
# Builds a fake colony under $TMPDIR_TEST. If ships_github=1, drops a
# github-api.sh alongside gitlab-api.sh — that turns the check on.
make_colony() {
    local fed="$1"
    local colony="$2"
    local ships_github="$3"
    local root="$TMPDIR_TEST/$fed/$colony"
    mkdir -p "$root/scripts" "$root/agents" "$root/config"
    touch "$root/scripts/gitlab-api.sh"
    touch "$root/scripts/forge-api.sh"
    if [ "$ships_github" = "1" ]; then
        touch "$root/scripts/github-api.sh"
    fi
    printf '%s' "$root"
}

run_checker() {
    set +e
    out="$("$CHECKER" "$TMPDIR_TEST" 2>&1)"
    rc=$?
    set -e
}

# --- Test 1: migrated colony with forge-api.sh call is clean ---
root="$(make_colony fed1 triage 1)"
cat > "$root/agents/good.ag" <<'AG'
fn tick(rec: string) -> void {
    let cmd = "$COLONY_DIR/scripts/forge-api.sh issues --view labeler";
    let raw = try { exec sh cmd; } catch e { "[]"; };
}
AG
run_checker
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "migrated-colony-clean: forge-api.sh call not flagged"
else
    fail "migrated-colony-clean" "rc=$rc out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

# --- Test 2: migrated colony with hardcoded gitlab-api.sh fails ---
root="$(make_colony fed1 triage 1)"
cat > "$root/agents/bad.ag" <<'AG'
fn tick(rec: string) -> void {
    let cmd = "$COLONY_DIR/scripts/gitlab-api.sh issues --view labeler";
    let raw = try { exec sh cmd; } catch e { "[]"; };
}
AG
run_checker
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "scripts/gitlab-api.sh"; then
    pass "migrated-colony-bad-gitlab: hardcoded gitlab-api.sh flagged"
else
    fail "migrated-colony-bad-gitlab" "rc=$rc out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

# --- Test 3: migrated colony with hardcoded github-api.sh fails too ---
root="$(make_colony fed1 triage 1)"
cat > "$root/agents/bad.ag" <<'AG'
fn tick(rec: string) -> void {
    let cmd = "$COLONY_DIR/scripts/github-api.sh issues --view labeler";
    let raw = try { exec sh cmd; } catch e { "[]"; };
}
AG
run_checker
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "scripts/github-api.sh"; then
    pass "migrated-colony-bad-github: hardcoded github-api.sh flagged"
else
    fail "migrated-colony-bad-github" "rc=$rc out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

# --- Test 4: unmigrated colony (no github-api.sh) is exempt ---
# Other colonies (planning/implementation/release/code-review) still have
# direct gitlab-api.sh calls until their per-colony PR lands. Don't flag.
root="$(make_colony fed1 planning 0)"
cat > "$root/agents/legacy.ag" <<'AG'
fn tick(rec: string) -> void {
    let cmd = "$COLONY_DIR/scripts/gitlab-api.sh issues";
    let raw = try { exec sh cmd; } catch e { "[]"; };
}
AG
run_checker
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "unmigrated-colony-exempt: no github-api.sh, direct calls allowed"
else
    fail "unmigrated-colony-exempt" "rc=$rc out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

# --- Test 5: comments don't count ---
root="$(make_colony fed1 triage 1)"
cat > "$root/agents/commented.ag" <<'AG'
// Historically this called scripts/gitlab-api.sh directly; see #256 PR 2.
fn tick(rec: string) -> void {
    let cmd = "$COLONY_DIR/scripts/forge-api.sh issues";  // ex-scripts/gitlab-api.sh
    let raw = try { exec sh cmd; } catch e { "[]"; };
}
AG
run_checker
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
    pass "comment-only: references inside // comments not flagged"
else
    fail "comment-only" "rc=$rc out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

# --- Test 6: multiple findings in one file print all lines ---
root="$(make_colony fed1 triage 1)"
cat > "$root/agents/bad.ag" <<'AG'
fn fetch() -> string {
    let cmd1 = "$COLONY_DIR/scripts/gitlab-api.sh issues --view router";
    let cmd2 = "$COLONY_DIR/scripts/gitlab-api.sh members";
    return try { exec sh cmd1; } catch e { "[]"; };
}
AG
run_checker
hits=$(printf '%s' "$out" | grep -c "scripts/gitlab-api.sh" || true)
if [ "$rc" -eq 1 ] && [ "$hits" -ge 2 ]; then
    pass "multi-findings: all offending lines reported"
else
    fail "multi-findings" "rc=$rc hits=$hits out=$out"
fi
rm -rf "${TMPDIR_TEST:?}"/*

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
