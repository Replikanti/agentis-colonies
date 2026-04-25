#!/bin/bash
# tools/test-secret-resolver.sh: unit tests for the secret:// resolver (#321).
#
# Each backend (libsecret, keychain, pass) is tested by shimming the
# real command (`secret-tool`, `security`, `pass`) with a tiny script
# that exits 0 with a fixture token, or non-zero to exercise the
# missing-key / locked-vault paths. PATH is rewritten to point at the
# stub directory first so the resolver in tools/parse-toml-secret.py
# picks up the shim.
#
# This harness must run on stock macOS /bin/bash (3.2). Per the issue
# refinement: NO heredocs, NO associative arrays, NO ${var^^}/${var,,},
# NO mapfile/readarray, NO backslash-newline inside case-pattern labels.
# Every shim is created via `printf '%s\n'` lines, never `cat <<EOF`.
#
# Usage: ./tools/test-secret-resolver.sh
# Exit 0 if all tests pass, 1 otherwise.
#
# shellcheck shell=bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RESOLVER="$SCRIPT_DIR/parse-toml-secret.py"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: expected <$2>, got <$3>"; FAIL=$((FAIL + 1)); }

if [ ! -f "$RESOLVER" ]; then
    echo "[FAIL] resolver not found: $RESOLVER" >&2
    exit 1
fi

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# write_shim BIN_NAME STDOUT EXIT_CODE
# Creates an executable shim under $TMPDIR_TEST/bin/ that prints
# STDOUT (token) and exits with EXIT_CODE. Built via printf so no
# heredoc shape is involved (#321 bash 3.2 portability).
write_shim() {
    local name="$1"
    local out="$2"
    local rc="$3"
    local path="$TMPDIR_TEST/bin/$name"
    mkdir -p "$TMPDIR_TEST/bin"
    {
        printf '%s\n' '#!/bin/sh'
        # Print stdout via printf (no \n unless caller wants it). Use a
        # quoted heredoc-free literal: the shim itself is built without
        # heredocs in this harness, but the body of the shim can use
        # plain printf calls.
        printf 'printf %%s %s\n' "'$out'"
        printf 'exit %s\n' "$rc"
    } > "$path"
    chmod +x "$path"
}

# Each test runs the resolver via `--resolve <uri>` so we don't need a
# TOML fixture. PATH is overridden so only our shim is visible.
run_resolve() {
    local uri="$1"
    PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve "$uri" 2>"$TMPDIR_TEST/last.err"
}

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "$expected" "$actual"
    fi
}

assert_rc() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "rc=$expected" "rc=$actual"
    fi
}

# --- Test 1: plaintext passthrough (regression for legacy callers) ---
# An empty $TMPDIR_TEST/bin and a plain string must come back unchanged
# with exit 0 — no resolver dispatch, no backend probe.
mkdir -p "$TMPDIR_TEST/bin"
out="$(PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve 'glpat-plain-token-321')"
assert_eq "plaintext passthrough" "glpat-plain-token-321" "$out"

# --- Test 2: libsecret success ---
write_shim secret-tool "libsecret-resolved-token-321" 0
out="$(run_resolve 'secret://libsecret/agentis-colonies/forge-token')"
assert_eq "libsecret success" "libsecret-resolved-token-321" "$out"

# --- Test 3: libsecret key not found ---
write_shim secret-tool "" 1
set +e
PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve 'secret://libsecret/agentis-colonies/missing-key' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "libsecret key-not-found exits 4" "4" "$rc"

# --- Test 4: libsecret binary missing ---
# Resolve the python interpreter once, then point the spawned subprocess
# at an isolated PATH that contains nothing — no shim, no real
# secret-tool. The interpreter call is by absolute path so it doesn't
# need PATH to find itself.
PYTHON3_BIN="$(command -v python3)"
rm -f "$TMPDIR_TEST/bin/secret-tool"
ISOLATED_PATH="$TMPDIR_TEST/empty-bin"
mkdir -p "$ISOLATED_PATH"
set +e
PATH="$ISOLATED_PATH" "$PYTHON3_BIN" "$RESOLVER" --resolve 'secret://libsecret/svc/key' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "libsecret missing binary exits 3" "3" "$rc"

# --- Test 5: keychain (macOS) success ---
write_shim security "keychain-resolved-token-321" 0
out="$(run_resolve 'secret://keychain/agentis-colonies/github-token')"
assert_eq "keychain success" "keychain-resolved-token-321" "$out"

# --- Test 6: keychain key not found ---
write_shim security "" 44
set +e
PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve 'secret://keychain/svc/missing' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "keychain key-not-found exits 4" "4" "$rc"

# --- Test 7: keychain binary missing ---
rm -f "$TMPDIR_TEST/bin/security"
set +e
PATH="$ISOLATED_PATH" "$PYTHON3_BIN" "$RESOLVER" --resolve 'secret://keychain/svc/account' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "keychain missing binary exits 3" "3" "$rc"

# --- Test 8: pass success ---
write_shim pass "pass-resolved-token-321" 0
out="$(run_resolve 'secret://pass/forge/agentis/token')"
assert_eq "pass success" "pass-resolved-token-321" "$out"

# --- Test 9: pass key not found (exit 4) ---
write_shim pass "" 1
set +e
PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve 'secret://pass/forge/missing' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "pass missing entry exits 4" "4" "$rc"

# --- Test 10: pass binary missing ---
rm -f "$TMPDIR_TEST/bin/pass"
set +e
PATH="$ISOLATED_PATH" "$PYTHON3_BIN" "$RESOLVER" --resolve 'secret://pass/forge/token' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "pass missing binary exits 3" "3" "$rc"

# --- Test 11: env backend success ---
out="$(AGENTIS_TEST_TOKEN_RESOLVER=ghp_env_token python3 "$RESOLVER" --resolve 'secret://env/AGENTIS_TEST_TOKEN_RESOLVER')"
assert_eq "env success" "ghp_env_token" "$out"

# --- Test 12: env backend missing var ---
set +e
unset AGENTIS_TEST_TOKEN_MISSING || true
python3 "$RESOLVER" --resolve 'secret://env/AGENTIS_TEST_TOKEN_MISSING' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "env missing var exits 4" "4" "$rc"

# --- Test 13: unknown scheme ---
set +e
python3 "$RESOLVER" --resolve 'secret://aws-sm/agentis/token' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "unknown backend exits 6" "6" "$rc"

# --- Test 14: malformed URI (empty after scheme) ---
set +e
python3 "$RESOLVER" --resolve 'secret://' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "empty URI exits 6" "6" "$rc"

# --- Test 15: URL-decoded service segment ---
# `secret://libsecret/my%2Fservice/token-key` → service contains "/"
write_shim secret-tool "url-decoded-resolved-321" 0
out="$(run_resolve 'secret://libsecret/my%2Fservice/token-key')"
assert_eq "url-decoded segment resolves" "url-decoded-resolved-321" "$out"

# --- Test 16: backslash-newline injection guard ---
# `secret://libsecret/svc/key%5C%0Aevil` decodes to "key\\\nevil" — must reject.
set +e
PATH="$TMPDIR_TEST/bin:$PATH" python3 "$RESOLVER" --resolve 'secret://libsecret/svc/key%5C%0Aevil' >/dev/null 2>"$TMPDIR_TEST/err.out"
rc=$?
set -e
assert_rc "backslash+newline rejected with exit 6" "6" "$rc"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
