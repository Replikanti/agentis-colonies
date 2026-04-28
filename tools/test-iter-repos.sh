#!/bin/bash
# tools/test-iter-repos.sh: unit tests for the #316 M3a per-tick fan-out
# helper (tools/iter-repos.sh + iter-repos.py).
#
# Tests:
#   1. Empty env (no GITHUB_REPOS_JSON, no GITHUB_OWNER) -> empty stdout, exit 0.
#   2. Single-block fallback (legacy GITHUB_OWNER/REPO/URL/ME, no JSON) -> 1 line.
#   3. JSON array with 1 entry -> 1 TSV line in source order.
#   4. JSON array with 3 entries -> 3 TSV lines in source order.
#   5. Malformed GITHUB_REPOS_JSON (not JSON) -> empty stdout, exit 0,
#      stderr carries an error message (helper degrades gracefully so a
#      bad config doesn't crash every agent's tick).
#   6. Entry missing repo -> entry skipped, others emitted, exit 0.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-iter-repos.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ITER="$SCRIPT_DIR/iter-repos.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Run iter-repos.sh under a controlled environment.
# Args: $1 stdout dump path, $2 stderr dump path, then KEY=VALUE pairs.
run_iter() {
    local out="$1" err="$2"
    shift 2
    env -i PATH="/usr/bin:/bin" "$@" "$ITER" >"$out" 2>"$err"
}

# --- Test 1: empty env ----------------------------------------------------
OUT="$TMPDIR_TEST/t1.out"
ERR="$TMPDIR_TEST/t1.err"
rc=0
run_iter "$OUT" "$ERR" || rc=$?
if [ "$rc" = "0" ] && [ ! -s "$OUT" ]; then
    pass "test 1: empty env -> empty stdout, exit 0"
else
    fail "test 1: empty env -> empty stdout, exit 0" \
         "rc=$rc stdout='$(cat "$OUT")' stderr='$(cat "$ERR")'"
fi

# --- Test 2: single-block fallback --------------------------------------
# Byte-identity rule (plan §9): the legacy fallback path emits one TSV
# line with EMPTY owner / repo (the sentinel that disables --repo, repo:
# tag, and memo scoping in agents). url + me still travel through.
OUT="$TMPDIR_TEST/t2.out"
ERR="$TMPDIR_TEST/t2.err"
rc=0
run_iter "$OUT" "$ERR" \
    GITHUB_OWNER="legacy-owner" \
    GITHUB_REPO="legacy-repo" \
    GITHUB_URL="https://api.github.com" \
    GITHUB_ME="legacy-me" || rc=$?
expected_t2="		https://api.github.com	legacy-me"
if [ "$rc" = "0" ] && [ "$(cat "$OUT")" = "$expected_t2" ]; then
    pass "test 2: single-block fallback -> sentinel TSV line (empty owner/repo)"
else
    fail "test 2: single-block fallback -> sentinel TSV line (empty owner/repo)" \
         "rc=$rc got='$(cat "$OUT")' expected='$expected_t2'"
fi

# --- Test 3: JSON array with 1 entry ------------------------------------
# Single-entry GITHUB_REPOS_JSON also collapses to the sentinel line per
# the byte-identity rule — operators with one repo see no per-repo
# scoping until they declare a second [[forge.github]] entry.
OUT="$TMPDIR_TEST/t3.out"
ERR="$TMPDIR_TEST/t3.err"
rc=0
run_iter "$OUT" "$ERR" \
    GITHUB_REPOS_JSON='[{"owner":"alice","repo":"demo","token":"tok-1","url":"https://api.github.com","me":"alice"}]' || rc=$?
expected_t3="		https://api.github.com	alice"
if [ "$rc" = "0" ] && [ "$(cat "$OUT")" = "$expected_t3" ]; then
    pass "test 3: 1-entry JSON -> sentinel TSV line (collapses to single-block byte-identity)"
else
    fail "test 3: 1-entry JSON -> sentinel TSV line (collapses to single-block byte-identity)" \
         "rc=$rc got='$(cat "$OUT")' expected='$expected_t3'"
fi

# --- Test 4: JSON array with 3 entries (source order) -------------------
OUT="$TMPDIR_TEST/t4.out"
ERR="$TMPDIR_TEST/t4.err"
rc=0
run_iter "$OUT" "$ERR" \
    GITHUB_REPOS_JSON='[{"owner":"acme","repo":"frontend","token":"t1","url":"https://api.github.com","me":"alice"},{"owner":"acme","repo":"backend","token":"t2","url":"https://api.github.com","me":"bob"},{"owner":"acme","repo":"infra","token":"t3","url":"https://api.github.com","me":"carol"}]' || rc=$?
expected_t4="acme	frontend	https://api.github.com	alice
acme	backend	https://api.github.com	bob
acme	infra	https://api.github.com	carol"
if [ "$rc" = "0" ] && [ "$(cat "$OUT")" = "$expected_t4" ]; then
    pass "test 4: 3-entry JSON -> 3 TSV lines in source order"
else
    fail "test 4: 3-entry JSON -> 3 TSV lines in source order" \
         "rc=$rc got='$(cat "$OUT")' expected='$expected_t4'"
fi

# --- Test 5: malformed JSON ---------------------------------------------
OUT="$TMPDIR_TEST/t5.out"
ERR="$TMPDIR_TEST/t5.err"
rc=0
run_iter "$OUT" "$ERR" \
    GITHUB_REPOS_JSON='not-valid-json' || rc=$?
if [ "$rc" = "0" ] && [ ! -s "$OUT" ] && grep -q 'malformed' "$ERR"; then
    pass "test 5: malformed JSON -> empty stdout, exit 0, stderr error"
else
    fail "test 5: malformed JSON -> empty stdout, exit 0, stderr error" \
         "rc=$rc stdout='$(cat "$OUT")' stderr='$(cat "$ERR")'"
fi

# --- Test 6: entry missing repo (skipped, others emitted) ---------------
OUT="$TMPDIR_TEST/t6.out"
ERR="$TMPDIR_TEST/t6.err"
rc=0
run_iter "$OUT" "$ERR" \
    GITHUB_REPOS_JSON='[{"owner":"good","repo":"keep","token":"t1","url":"https://api.github.com","me":"alice"},{"owner":"missing","token":"t2"},{"owner":"good","repo":"also-keep","token":"t3","url":"https://api.github.com","me":"bob"}]' || rc=$?
expected_t6="good	keep	https://api.github.com	alice
good	also-keep	https://api.github.com	bob"
if [ "$rc" = "0" ] && [ "$(cat "$OUT")" = "$expected_t6" ] && grep -q 'missing owner or repo' "$ERR"; then
    pass "test 6: entry missing repo -> skipped, others emitted, stderr warns"
else
    fail "test 6: entry missing repo -> skipped, others emitted, stderr warns" \
         "rc=$rc stdout='$(cat "$OUT")' stderr='$(cat "$ERR")'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
