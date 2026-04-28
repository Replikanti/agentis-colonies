#!/bin/bash
# tools/test-forge-api-multi-repo.sh: unit tests for the #316 M3a
# `forge-api.sh --repo` dispatch path.
#
# Tests (per plan §8 + §9):
#   1.  --repo strip from argv before exec'ing the backend wrapper
#   2.  --repo + multi env -> token / url / me resolved from JSON
#   3.  --repo + multi env -> right entry by (owner, repo) tuple
#   4.  --repo + multi env -> lookup miss exits 2
#   5.  --repo absent + multi env -> no override (back-compat env values stay)
#   6.  --repo absent + no GITHUB_REPOS_JSON -> byte-identical to pre-M3
#       (the legacy GITHUB_OWNER/REPO/TOKEN/URL/ME stay)
#   7.  gitlab backend silent strip (--repo dropped from argv, no resolution)
#   8.  malformed GITHUB_REPOS_JSON exits 2 on the resolution path
#   9.  missing forge-resolve-repo.py exits 2 with helpful error
#   10. --repo without value exits 2
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-forge-api-multi-repo.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_FORGE_API="$REPO_ROOT/dev-apprenticeship/triage/scripts/forge-api.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Build a fake repo tree so $SCRIPT_DIR/../../.. resolves to a tools/
# directory containing our forge-resolve-repo.py. Layout:
#   $TMPDIR_TEST/<rooted>/
#     dev-apprenticeship/triage/scripts/  -> forge-api.sh + stubs
#     tools/                              -> forge-resolve-repo.py
ROOT="$TMPDIR_TEST/repo"
SCRIPTS_DIR="$ROOT/dev-apprenticeship/triage/scripts"
TOOLS_DIR="$ROOT/tools"
mkdir -p "$SCRIPTS_DIR" "$TOOLS_DIR"
cp "$SOURCE_FORGE_API" "$SCRIPTS_DIR/forge-api.sh"
cp "$REPO_ROOT/tools/forge-resolve-repo.py" "$TOOLS_DIR/"
chmod +x "$SCRIPTS_DIR/forge-api.sh" "$TOOLS_DIR/forge-resolve-repo.py"

# Stub backend wrapper: dump argv (one per line, with a sentinel header
# so the test can assert exact arity) followed by the resolved GITHUB_*
# env. Test 7 needs a gitlab stub too.
cat > "$SCRIPTS_DIR/github-api.sh" <<'SHIM'
#!/bin/bash
echo "BACKEND=github"
echo "ARGC=$#"
i=1
for a in "$@"; do
    echo "ARG[$i]=$a"
    i=$((i + 1))
done
echo "OWNER=${GITHUB_OWNER:-}"
echo "REPO=${GITHUB_REPO:-}"
echo "TOKEN=${GITHUB_TOKEN:-}"
echo "URL=${GITHUB_URL:-}"
echo "ME=${GITHUB_ME:-}"
SHIM
chmod +x "$SCRIPTS_DIR/github-api.sh"

cat > "$SCRIPTS_DIR/gitlab-api.sh" <<'SHIM'
#!/bin/bash
echo "BACKEND=gitlab"
echo "ARGC=$#"
i=1
for a in "$@"; do
    echo "ARG[$i]=$a"
    i=$((i + 1))
done
SHIM
chmod +x "$SCRIPTS_DIR/gitlab-api.sh"

FORGE_API="$SCRIPTS_DIR/forge-api.sh"

# Run forge-api.sh in a clean env. $1=stdout dump, $2=stderr dump, then
# KEY=VALUE pairs, then `--`, then forge-api.sh argv.
run_dispatch() {
    local out="$1" err="$2"
    shift 2
    local env_pairs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
        env_pairs+=("$1")
        shift
    done
    if [ "${1:-}" = "--" ]; then
        shift
    fi
    env -i PATH="/usr/bin:/bin" "${env_pairs[@]}" "$FORGE_API" "$@" >"$out" 2>"$err"
}

# Read a key=value line from a backend stub dump.
dump_get() {
    grep -E "^${2}=" "$1" 2>/dev/null | head -1 | cut -d= -f2-
}

# --- Test 1: --repo strip from argv -------------------------------------
# When --repo IS present and the resolution succeeds, the backend wrapper
# must NOT see --repo in its argv.
OUT="$TMPDIR_TEST/t1.out"
ERR="$TMPDIR_TEST/t1.err"
rc=0
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"acme","repo":"backend","token":"tok-be","url":"https://api.github.com","me":"bob"}]' \
    GITHUB_OWNER=initial GITHUB_REPO=initial GITHUB_TOKEN=initial \
    -- --repo acme/backend issues --view router || rc=$?
argc=$(dump_get "$OUT" ARGC)
arg1=$(dump_get "$OUT" 'ARG\[1\]')
arg2=$(dump_get "$OUT" 'ARG\[2\]')
arg3=$(dump_get "$OUT" 'ARG\[3\]')
if [ "$rc" = "0" ] && [ "$argc" = "3" ] && [ "$arg1" = "issues" ] \
    && [ "$arg2" = "--view" ] && [ "$arg3" = "router" ]; then
    pass "test 1: --repo stripped from argv before exec'ing backend wrapper"
else
    fail "test 1: --repo stripped from argv before exec'ing backend wrapper" \
         "rc=$rc argc=$argc arg1='$arg1' arg2='$arg2' arg3='$arg3'"
fi

# --- Test 2 + 3: token/url/me + right-entry-by-tuple --------------------
# Two-entry JSON with a back-compat-export entry [0] that is intentionally
# different from the resolved entry. After resolution the env carries the
# entry-[1] values, not entry [0] back-compat values.
OUT="$TMPDIR_TEST/t2.out"
ERR="$TMPDIR_TEST/t2.err"
rc=0
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"acme","repo":"frontend","token":"tok-fe","url":"https://api.github.com","me":"alice"},{"owner":"acme","repo":"backend","token":"tok-be","url":"https://api.example.com","me":"bob"}]' \
    GITHUB_OWNER=acme GITHUB_REPO=frontend GITHUB_TOKEN=tok-fe \
    GITHUB_URL=https://api.github.com GITHUB_ME=alice \
    -- --repo acme/backend issues || rc=$?
got_owner=$(dump_get "$OUT" OWNER)
got_repo=$(dump_get "$OUT" REPO)
got_token=$(dump_get "$OUT" TOKEN)
got_url=$(dump_get "$OUT" URL)
got_me=$(dump_get "$OUT" ME)
if [ "$rc" = "0" ] && [ "$got_owner" = "acme" ] && [ "$got_repo" = "backend" ] \
    && [ "$got_token" = "tok-be" ] && [ "$got_url" = "https://api.example.com" ] \
    && [ "$got_me" = "bob" ]; then
    pass "test 2+3: token/url/me resolved from the matching JSON entry"
else
    fail "test 2+3: token/url/me resolved from the matching JSON entry" \
         "rc=$rc owner='$got_owner' repo='$got_repo' token='$got_token' url='$got_url' me='$got_me'"
fi

# --- Test 4: lookup miss exits 2 ----------------------------------------
OUT="$TMPDIR_TEST/t4.out"
ERR="$TMPDIR_TEST/t4.err"
set +e
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"acme","repo":"frontend","token":"tok-fe","url":"https://api.github.com","me":"alice"}]' \
    GITHUB_OWNER=x GITHUB_REPO=x GITHUB_TOKEN=x \
    -- --repo acme/missing issues
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q 'not in GITHUB_REPOS_JSON' "$ERR"; then
    pass "test 4: lookup miss exits 2 with clear error"
else
    fail "test 4: lookup miss exits 2 with clear error" \
         "rc=$rc stderr='$(cat "$ERR")'"
fi

# --- Test 5: --repo absent + multi env -> no override -------------------
# Without --repo, the dispatcher must NOT touch GITHUB_*; the back-compat
# entry [0] env exported by start-colony.sh stays as-is.
OUT="$TMPDIR_TEST/t5.out"
ERR="$TMPDIR_TEST/t5.err"
rc=0
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"acme","repo":"frontend","token":"tok-fe","url":"https://api.github.com","me":"alice"},{"owner":"acme","repo":"backend","token":"tok-be","url":"https://api.example.com","me":"bob"}]' \
    GITHUB_OWNER=acme GITHUB_REPO=frontend GITHUB_TOKEN=tok-fe \
    GITHUB_URL=https://api.github.com GITHUB_ME=alice \
    -- issues || rc=$?
got_owner=$(dump_get "$OUT" OWNER)
got_repo=$(dump_get "$OUT" REPO)
got_token=$(dump_get "$OUT" TOKEN)
if [ "$rc" = "0" ] && [ "$got_owner" = "acme" ] && [ "$got_repo" = "frontend" ] \
    && [ "$got_token" = "tok-fe" ]; then
    pass "test 5: --repo absent + multi env -> no override (entry [0] stays)"
else
    fail "test 5: --repo absent + multi env -> no override (entry [0] stays)" \
         "rc=$rc owner='$got_owner' repo='$got_repo' token='$got_token'"
fi

# --- Test 6: --repo absent + no GITHUB_REPOS_JSON -> byte-identical -----
# Pre-M3 single-block path: legacy env, no JSON, no --repo. Backend
# wrapper sees the same env and the same argv as before M3.
OUT="$TMPDIR_TEST/t6.out"
ERR="$TMPDIR_TEST/t6.err"
rc=0
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_OWNER=legacy-owner GITHUB_REPO=legacy-repo GITHUB_TOKEN=legacy-token \
    GITHUB_URL=https://api.github.com GITHUB_ME=legacy-me \
    -- issues --view router || rc=$?
got_owner=$(dump_get "$OUT" OWNER)
got_repo=$(dump_get "$OUT" REPO)
got_token=$(dump_get "$OUT" TOKEN)
got_url=$(dump_get "$OUT" URL)
got_me=$(dump_get "$OUT" ME)
argc=$(dump_get "$OUT" ARGC)
if [ "$rc" = "0" ] && [ "$got_owner" = "legacy-owner" ] && [ "$got_repo" = "legacy-repo" ] \
    && [ "$got_token" = "legacy-token" ] && [ "$got_url" = "https://api.github.com" ] \
    && [ "$got_me" = "legacy-me" ] && [ "$argc" = "3" ]; then
    pass "test 6: --repo absent + no JSON -> byte-identical to pre-M3"
else
    fail "test 6: --repo absent + no JSON -> byte-identical to pre-M3" \
         "rc=$rc owner='$got_owner' repo='$got_repo' token='$got_token' argc='$argc'"
fi

# --- Test 7: gitlab backend silent strip --------------------------------
# When FORGE_TYPE=gitlab, --repo is silently stripped (the dispatcher's
# scan happens before the case "$FORGE_TYPE", but the resolution branch
# is gated on FORGE_TYPE=github). gitlab-api.sh sees argv without --repo.
OUT="$TMPDIR_TEST/t7.out"
ERR="$TMPDIR_TEST/t7.err"
rc=0
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=gitlab \
    GITLAB_TOKEN=glpat-x GITLAB_PROJECT=acme%2Fdemo \
    -- --repo acme/whatever issues || rc=$?
backend=$(dump_get "$OUT" BACKEND)
argc=$(dump_get "$OUT" ARGC)
arg1=$(dump_get "$OUT" 'ARG\[1\]')
if [ "$rc" = "0" ] && [ "$backend" = "gitlab" ] && [ "$argc" = "1" ] \
    && [ "$arg1" = "issues" ]; then
    pass "test 7: gitlab backend silently strips --repo from argv"
else
    fail "test 7: gitlab backend silently strips --repo from argv" \
         "rc=$rc backend='$backend' argc='$argc' arg1='$arg1' stderr='$(cat "$ERR")'"
fi

# --- Test 8: malformed GITHUB_REPOS_JSON on resolution path -------------
# When --repo is present and the JSON is malformed, the python helper
# exits 2 and the dispatcher propagates exit 2.
OUT="$TMPDIR_TEST/t8.out"
ERR="$TMPDIR_TEST/t8.err"
set +e
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='not-valid-json' \
    GITHUB_OWNER=x GITHUB_REPO=x GITHUB_TOKEN=x \
    -- --repo a/b issues
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q 'not in GITHUB_REPOS_JSON\|malformed' "$ERR"; then
    pass "test 8: malformed JSON on --repo path exits 2"
else
    fail "test 8: malformed JSON on --repo path exits 2" \
         "rc=$rc stderr='$(cat "$ERR")'"
fi

# --- Test 9: missing forge-resolve-repo.py ------------------------------
# Hide the helper, run the dispatcher with --repo, expect exit 2 and a
# clear "helper missing" error.
mv "$TOOLS_DIR/forge-resolve-repo.py" "$TOOLS_DIR/.hidden-resolve-repo.py"
OUT="$TMPDIR_TEST/t9.out"
ERR="$TMPDIR_TEST/t9.err"
set +e
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"a","repo":"b","token":"t1","url":"https://api.github.com","me":"alice"}]' \
    GITHUB_OWNER=x GITHUB_REPO=x GITHUB_TOKEN=x \
    -- --repo a/b issues
rc=$?
set -e
mv "$TOOLS_DIR/.hidden-resolve-repo.py" "$TOOLS_DIR/forge-resolve-repo.py"
if [ "$rc" = "2" ] && grep -q 'helper missing' "$ERR"; then
    pass "test 9: missing forge-resolve-repo.py exits 2 with clear error"
else
    fail "test 9: missing forge-resolve-repo.py exits 2 with clear error" \
         "rc=$rc stderr='$(cat "$ERR")'"
fi

# --- Test 10: --repo without value --------------------------------------
OUT="$TMPDIR_TEST/t10.out"
ERR="$TMPDIR_TEST/t10.err"
set +e
run_dispatch "$OUT" "$ERR" \
    FORGE_TYPE=github \
    GITHUB_REPOS_JSON='[{"owner":"a","repo":"b","token":"t1"}]' \
    GITHUB_OWNER=x GITHUB_REPO=x GITHUB_TOKEN=x \
    -- --repo
rc=$?
set -e
if [ "$rc" = "2" ] && grep -q 'requires owner/repo arg' "$ERR"; then
    pass "test 10: --repo without value exits 2 with clear error"
else
    fail "test 10: --repo without value exits 2 with clear error" \
         "rc=$rc stderr='$(cat "$ERR")'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
