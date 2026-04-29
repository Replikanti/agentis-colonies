#!/bin/bash
# tools/test-cross-repo-refs.sh: unit tests for #317 cross-repo reference
# detection (tools/cross-repo-grep.sh + cross-repo-grep.py).
#
# Tests:
#   1. Sibling defines symbol used in target diff -> ref detected, header
#      includes the sibling key, body shows path:line + context.
#   2. Empty CROSS_REPO_REPOS env (cross_repo=false equivalent) -> empty
#      stdout, exit 0.
#   3. Cap at CROSS_REPO_MAX_REFS=2 with 4 matches -> 2 blocks emitted
#      plus `[N more refs elided]` trailer.
#   4. Keyword filter: a diff line that introduces only `if`/`for`/`return`
#      symbols emits no refs (tokens are filtered out before the regex is
#      built, so even if the sibling defined them they would not match).
#   5. Three sibling repos declared, one of them is the active repo —
#      helper skips the active repo and matches in the other two.
#   6. Malformed CROSS_REPO_REPO_PATHS (length mismatch with
#      CROSS_REPO_REPOS) -> exit 2 with stderr message.
#   7. (optional) Performance: sibling repo with 500 dummy files -> helper
#      finishes within 5s wall-clock. Skipped on lean CI when the fixture
#      cannot be built (ulimit / git-not-on-path / etc.).
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-cross-repo-refs.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/cross-repo-grep.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1${2:+: $2}"; }

if ! command -v git >/dev/null 2>&1; then
    skip "git not on PATH"
    echo ""
    echo "Results: $PASS passed, $FAIL failed (skipped)"
    exit 0
fi

# Build a tracked git repo with arbitrary content. $1 is the repo path,
# remaining args are <relpath>=<inline-body> pairs (newline-separated body
# is encoded with literal `\n`). We use `git -c user.email=...` to keep
# the test self-contained on machines without a global git config.
make_repo() {
    repo="$1"
    shift
    mkdir -p "$repo"
    git -C "$repo" -c init.defaultBranch=main init -q
    git -C "$repo" config user.email "test@example.invalid"
    git -C "$repo" config user.name "test"
    while [ "$#" -gt 0 ]; do
        spec="$1"
        shift
        rel="${spec%%=*}"
        body="${spec#*=}"
        mkdir -p "$repo/$(dirname "$rel")"
        printf '%b' "$body" > "$repo/$rel"
    done
    git -C "$repo" add -A
    git -C "$repo" commit -q -m "init"
}

# Write a forge-api mr-changes-shaped JSON spool from a free-form `+`-prefix
# unified diff body. Keeps test fixtures readable.
write_diff_spool() {
    spool="$1"
    body="$2"
    python3 - "$spool" "$body" <<'PY'
import json, sys
spool, body = sys.argv[1], sys.argv[2]
lines = []
for ln in body.split("\n"):
    if not ln:
        continue
    if ln.startswith("+"):
        lines.append({"kind": "added", "text": ln[1:]})
    else:
        lines.append({"kind": "context", "text": ln})
data = [{"file": "src/caller.py", "hunks": [{"lines": lines}]}]
with open(spool, "w") as f:
    json.dump(data, f)
PY
}

# --- Test 1: sibling defines a symbol used in the target diff -----------
T1_DIR="$TMPDIR_TEST/t1"
mkdir -p "$T1_DIR"
make_repo "$T1_DIR/sibling" \
    'src/auth.py=def validate_token(ctx, tok):\n    if tok == "":\n        return None\n    return Claims(tok)\n'
T1_SPOOL="$T1_DIR/diff.json"
write_diff_spool "$T1_SPOOL" "+claims = validate_token(ctx, header_value)"
T1_OUT="$T1_DIR/out"
T1_ERR="$T1_DIR/err"
rc=0
DIFF_INPUT_FILE="$T1_SPOOL" \
CROSS_REPO_REPOS="acme/sibling" \
CROSS_REPO_REPO_PATHS="$T1_DIR/sibling" \
"$HELPER" >"$T1_OUT" 2>"$T1_ERR" || rc=$?
if [ "$rc" = "0" ] \
   && grep -q '^Cross-repo references' "$T1_OUT" \
   && grep -q '\[acme/sibling\] src/auth.py' "$T1_OUT" \
   && grep -q 'validate_token' "$T1_OUT"; then
    pass "test 1: sibling-defined symbol detected with file:line and body"
else
    fail "test 1: sibling-defined symbol detected with file:line and body" \
         "rc=$rc out='$(cat "$T1_OUT")' err='$(cat "$T1_ERR")'"
fi

# --- Test 2: cross_repo=false equivalent (empty allowlist) -------------
T2_OUT="$TMPDIR_TEST/t2.out"
T2_ERR="$TMPDIR_TEST/t2.err"
rc=0
DIFF_INPUT_FILE="$T1_SPOOL" \
CROSS_REPO_REPOS="" \
CROSS_REPO_REPO_PATHS="" \
"$HELPER" >"$T2_OUT" 2>"$T2_ERR" || rc=$?
if [ "$rc" = "0" ] && [ ! -s "$T2_OUT" ]; then
    pass "test 2: empty CROSS_REPO_REPOS -> empty stdout, exit 0"
else
    fail "test 2: empty CROSS_REPO_REPOS -> empty stdout, exit 0" \
         "rc=$rc out='$(cat "$T2_OUT")' err='$(cat "$T2_ERR")'"
fi

# --- Test 3: cap on emitted blocks -------------------------------------
T3_DIR="$TMPDIR_TEST/t3"
mkdir -p "$T3_DIR"
# Sibling has 4 distinct files each defining `lookup_widget` once; the
# diff calls `lookup_widget`. With CROSS_REPO_MAX_REFS=2 the helper must
# emit exactly 2 blocks plus a `[N more refs elided]` trailer.
make_repo "$T3_DIR/sibling" \
    'src/a.py=def lookup_widget(id):\n    return id\n' \
    'src/b.py=def lookup_widget(id):\n    return id\n' \
    'src/c.py=def lookup_widget(id):\n    return id\n' \
    'src/d.py=def lookup_widget(id):\n    return id\n'
T3_SPOOL="$T3_DIR/diff.json"
write_diff_spool "$T3_SPOOL" "+w = lookup_widget(42)"
T3_OUT="$T3_DIR/out"
T3_ERR="$T3_DIR/err"
rc=0
DIFF_INPUT_FILE="$T3_SPOOL" \
CROSS_REPO_REPOS="acme/sibling" \
CROSS_REPO_REPO_PATHS="$T3_DIR/sibling" \
CROSS_REPO_MAX_REFS=2 \
"$HELPER" >"$T3_OUT" 2>"$T3_ERR" || rc=$?
n_blocks=$(grep -c '^\[acme/sibling\]' "$T3_OUT" 2>/dev/null || true)
n_blocks="${n_blocks:-0}"
if [ "$rc" = "0" ] \
   && [ "$n_blocks" = "2" ] \
   && grep -q '\[2 more refs elided\]' "$T3_OUT"; then
    pass "test 3: cap honoured at 2 refs + 2-more-elided trailer"
else
    fail "test 3: cap honoured at 2 refs + 2-more-elided trailer" \
         "rc=$rc blocks=$n_blocks out='$(cat "$T3_OUT")'"
fi

# --- Test 4: keyword filter ---------------------------------------------
T4_DIR="$TMPDIR_TEST/t4"
mkdir -p "$T4_DIR"
make_repo "$T4_DIR/sibling" \
    'src/x.py=for x in items:\n    if x:\n        return x\n'
T4_SPOOL="$T4_DIR/diff.json"
# Diff body contains only keywords from the filter list — no symbols
# survive tokenisation, so no regex is built and no grep runs.
write_diff_spool "$T4_SPOOL" "+if x return for"
T4_OUT="$T4_DIR/out"
T4_ERR="$T4_DIR/err"
rc=0
DIFF_INPUT_FILE="$T4_SPOOL" \
CROSS_REPO_REPOS="acme/sibling" \
CROSS_REPO_REPO_PATHS="$T4_DIR/sibling" \
"$HELPER" >"$T4_OUT" 2>"$T4_ERR" || rc=$?
if [ "$rc" = "0" ] && [ ! -s "$T4_OUT" ]; then
    pass "test 4: keyword-only diff -> no refs (filter list elides if/for/return)"
else
    fail "test 4: keyword-only diff -> no refs (filter list elides if/for/return)" \
         "rc=$rc out='$(cat "$T4_OUT")' err='$(cat "$T4_ERR")'"
fi

# --- Test 5: active repo skipped, others matched -----------------------
T5_DIR="$TMPDIR_TEST/t5"
mkdir -p "$T5_DIR"
make_repo "$T5_DIR/repo-a" \
    'src/active.py=def validate_token(t):\n    return t\n'
make_repo "$T5_DIR/repo-b" \
    'src/lib.py=def validate_token(t):\n    return t\n'
make_repo "$T5_DIR/repo-c" \
    'src/util.py=def validate_token(t):\n    return t\n'
T5_SPOOL="$T5_DIR/diff.json"
write_diff_spool "$T5_SPOOL" "+v = validate_token(header)"
T5_OUT="$T5_DIR/out"
T5_ERR="$T5_DIR/err"
rc=0
DIFF_INPUT_FILE="$T5_SPOOL" \
CROSS_REPO_REPOS="acme/repo-a, acme/repo-b, acme/repo-c" \
CROSS_REPO_REPO_PATHS="$T5_DIR/repo-a, $T5_DIR/repo-b, $T5_DIR/repo-c" \
CROSS_REPO_ACTIVE="acme/repo-a" \
"$HELPER" >"$T5_OUT" 2>"$T5_ERR" || rc=$?
hit_b=$(grep -c '^\[acme/repo-b\]' "$T5_OUT" 2>/dev/null || true)
hit_c=$(grep -c '^\[acme/repo-c\]' "$T5_OUT" 2>/dev/null || true)
hit_a=$(grep -c '^\[acme/repo-a\]' "$T5_OUT" 2>/dev/null || true)
hit_b="${hit_b:-0}"; hit_c="${hit_c:-0}"; hit_a="${hit_a:-0}"
if [ "$rc" = "0" ] \
   && [ "$hit_b" -ge "1" ] \
   && [ "$hit_c" -ge "1" ] \
   && [ "$hit_a" = "0" ]; then
    pass "test 5: active repo filtered out, siblings matched (b=$hit_b c=$hit_c a=$hit_a)"
else
    fail "test 5: active repo filtered out, siblings matched" \
         "rc=$rc a=$hit_a b=$hit_b c=$hit_c out='$(cat "$T5_OUT")'"
fi

# --- Test 6: malformed CROSS_REPO_REPO_PATHS (length mismatch) ----------
T6_OUT="$TMPDIR_TEST/t6.out"
T6_ERR="$TMPDIR_TEST/t6.err"
rc=0
DIFF_INPUT_FILE="$T1_SPOOL" \
CROSS_REPO_REPOS="acme/repo-a, acme/repo-b" \
CROSS_REPO_REPO_PATHS="$T1_DIR/sibling" \
"$HELPER" >"$T6_OUT" 2>"$T6_ERR" || rc=$?
if [ "$rc" = "2" ] \
   && [ ! -s "$T6_OUT" ] \
   && grep -q 'length' "$T6_ERR"; then
    pass "test 6: length mismatch -> exit 2 + stderr message"
else
    fail "test 6: length mismatch -> exit 2 + stderr message" \
         "rc=$rc out='$(cat "$T6_OUT")' err='$(cat "$T6_ERR")'"
fi

# --- Test 7 (optional): performance on a 500-file sibling repo ---------
# Lean CI may not have the disk budget to build 500 commits; we build a
# single commit with 500 files instead, which is the same regex-cost
# proxy. Skipped on the cheapest CI tiers via the BUILD_LARGE guard.
if [ "${TEST_CROSS_REPO_PERF:-1}" = "1" ]; then
    T7_DIR="$TMPDIR_TEST/t7"
    mkdir -p "$T7_DIR/sibling"
    git -C "$T7_DIR/sibling" -c init.defaultBranch=main init -q
    git -C "$T7_DIR/sibling" config user.email "test@example.invalid"
    git -C "$T7_DIR/sibling" config user.name "test"
    i=0
    while [ "$i" -lt 500 ]; do
        printf 'def filler_%d(x):\n    return x\n' "$i" \
            > "$T7_DIR/sibling/file_$i.py"
        i=$((i + 1))
    done
    # Plant validate_token in exactly one of the 500 files so the
    # context-grep returns a single block.
    printf 'def validate_token(t):\n    return t\n' \
        > "$T7_DIR/sibling/file_42.py"
    git -C "$T7_DIR/sibling" add -A >/dev/null
    git -C "$T7_DIR/sibling" commit -q -m "init"
    T7_SPOOL="$T7_DIR/diff.json"
    write_diff_spool "$T7_SPOOL" "+v = validate_token(header)"
    T7_OUT="$T7_DIR/out"
    start_s="$(date +%s)"
    rc=0
    DIFF_INPUT_FILE="$T7_SPOOL" \
    CROSS_REPO_REPOS="acme/sibling" \
    CROSS_REPO_REPO_PATHS="$T7_DIR/sibling" \
    "$HELPER" >"$T7_OUT" 2>/dev/null || rc=$?
    end_s="$(date +%s)"
    elapsed=$((end_s - start_s))
    if [ "$rc" = "0" ] && [ "$elapsed" -le 5 ] && grep -q 'validate_token' "$T7_OUT"; then
        pass "test 7: 500-file sibling repo finishes in ${elapsed}s (<=5s budget)"
    else
        fail "test 7: 500-file sibling repo within 5s budget" \
             "rc=$rc elapsed=${elapsed}s"
    fi
else
    skip "test 7: performance (TEST_CROSS_REPO_PERF=0)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
