#!/bin/bash
# tools/test-check-changelog.sh: unit tests for tools/check-changelog.sh (#218).
#
# Validates:
#   Test 1: no PR context (GITHUB_BASE_REF unset) -> exits 0 silently
#   Test 2: dev-apprenticeship/ touched without CHANGELOG -> exits 0, prints [WARN]
#   Test 3: dev-apprenticeship/VERSION bumped without CHANGELOG -> exits 1 (hard fail)
#   Test 4: dev-apprenticeship/ touched WITH CHANGELOG -> exits 0, no warning
#   Test 5: non-dev-app-only change (e.g. tools/) -> exits 0, no warning
#   Test 6: VERSION bumped AND CHANGELOG updated -> exits 0
#
# Uses a fresh temp git repo so the assertions are independent of the live
# repo state.
#
# Usage: ./tools/test-check-changelog.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_CHECK="$SCRIPT_DIR/check-changelog.sh"

if [ ! -x "$REAL_CHECK" ]; then
    echo "[FAIL] tools/check-changelog.sh missing or not executable"
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Build a mini-repo that looks enough like agentis-colonies for the check
# to have something to diff. The fake origin remote is a bare clone so
# fetch/compare operations behave like a real PR checkout.
FAKE_REPO="$TMPDIR_TEST/repo"
FAKE_REMOTE="$TMPDIR_TEST/remote.git"

git init --quiet --bare "$FAKE_REMOTE"
git init --quiet "$FAKE_REPO"
cd "$FAKE_REPO"
git -c user.email=t@t -c user.name=t commit --quiet --allow-empty -m init
mkdir -p dev-apprenticeship tools
echo "0.0.1" > dev-apprenticeship/VERSION
cat > dev-apprenticeship/CHANGELOG.md <<'EOF'
# Changelog
## [Unreleased]
EOF
echo "hello" > dev-apprenticeship/README.md
echo "tool" > tools/x.sh
cp "$REAL_CHECK" tools/check-changelog.sh
chmod +x tools/check-changelog.sh
git add .
git -c user.email=t@t -c user.name=t commit --quiet -m "seed"
git remote add origin "$FAKE_REMOTE"
git push --quiet origin main 2>/dev/null || git push --quiet origin master 2>/dev/null || git push --quiet origin HEAD:refs/heads/main

# Determine the default branch name (git init default differs by version).
BASE_BRANCH="$(git -C "$FAKE_REMOTE" symbolic-ref --short HEAD 2>/dev/null || echo main)"

# Helper: create a feature branch off of BASE_BRANCH with a mutation applied,
# then run check-changelog with GITHUB_BASE_REF set. Prints exit code and
# captured output; caller asserts.
run_scenario() {
    local name="$1"
    local mutator="$2"
    (
        cd "$FAKE_REPO"
        git checkout --quiet -B feat-scenario "$BASE_BRANCH"
        eval "$mutator"
        git add -A
        git -c user.email=t@t -c user.name=t commit --quiet -m "scenario: $name" || true
        GITHUB_BASE_REF="$BASE_BRANCH" \
            ./tools/check-changelog.sh "$FAKE_REPO" 2>&1
        echo "__RC__=$?"
    )
}

# ----- Test 1: no PR context -----
OUT="$(cd "$FAKE_REPO" && unset GITHUB_BASE_REF && ./tools/check-changelog.sh "$FAKE_REPO" 2>&1; echo "__RC__=$?")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "0" ] && echo "$BODY" | grep -Fq "no PR context"; then
    pass "no PR context -> exit 0 + skip message"
else
    fail "no PR context" "rc=$RC, out=$BODY"
fi

# ----- Test 2: dev-app touched without CHANGELOG -> WARN, exit 0 -----
OUT="$(run_scenario "warn-only" "echo 'changed' >> dev-apprenticeship/README.md")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "0" ] && echo "$BODY" | grep -Fq "[WARN]"; then
    pass "dev-app touched without CHANGELOG -> exit 0 + [WARN]"
else
    fail "warn-only scenario" "rc=$RC, out=$BODY"
fi

# ----- Test 3: VERSION bumped without CHANGELOG -> HARD FAIL -----
OUT="$(run_scenario "release-no-changelog" "echo '0.0.2' > dev-apprenticeship/VERSION")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "1" ] && echo "$BODY" | grep -Fq "VERSION"; then
    pass "VERSION bumped without CHANGELOG -> exit 1 (release PR hard-fail)"
else
    fail "release-no-changelog scenario" "rc=$RC, out=$BODY"
fi

# ----- Test 4: dev-app touched WITH CHANGELOG -> OK -----
OUT="$(run_scenario "feature-with-changelog" "echo 'changed' >> dev-apprenticeship/README.md; printf '\n- Added something\n' >> dev-apprenticeship/CHANGELOG.md")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "0" ] && ! echo "$BODY" | grep -Fq "[WARN]"; then
    pass "dev-app + CHANGELOG -> exit 0, no warn"
else
    fail "feature-with-changelog" "rc=$RC, out=$BODY"
fi

# ----- Test 5: non-dev-app change only -> OK, no warn -----
OUT="$(run_scenario "non-dev-app-only" "echo '# new tool' >> tools/x.sh")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "0" ] && ! echo "$BODY" | grep -Fq "[WARN]"; then
    pass "non-dev-app change -> exit 0, no warn"
else
    fail "non-dev-app-only" "rc=$RC, out=$BODY"
fi

# ----- Test 6: VERSION + CHANGELOG both bumped -> OK -----
OUT="$(run_scenario "release-complete" "echo '0.0.2' > dev-apprenticeship/VERSION; printf '\n## [0.0.2]\n' >> dev-apprenticeship/CHANGELOG.md")"
RC="${OUT##*__RC__=}"; BODY="${OUT%__RC__=*}"
if [ "$RC" = "0" ]; then
    pass "VERSION + CHANGELOG both updated -> exit 0"
else
    fail "release-complete" "rc=$RC, out=$BODY"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
