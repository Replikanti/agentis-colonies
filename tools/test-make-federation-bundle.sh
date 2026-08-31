#!/bin/bash
# tools/test-make-federation-bundle.sh: unit tests for
# tools/make-federation-bundle.sh (#220).
#
# Validates:
#   Test 1: arg validation (0 or 1 args -> exit 1, usage printed)
#   Test 2: missing federation dir -> exit 2
#   Test 3: missing BUNDLE.manifest -> exit 2
#   Test 4: empty manifest (comments only) -> exit 2
#   Test 5: manifest listing non-existent path -> exit 3
#   Test 6: happy path on a synthetic mini-repo — tar + sha256 produced,
#           every listed path present in the tar, blacklisted paths absent
#   Test 7: bash -n on every .sh in the extracted tree (catch cp truncations)
#   Test 8: real federation smoke — run against the repo's actual
#           dev-apprenticeship/BUNDLE.manifest, verify key runtime files are
#           in and contributor-only files are out
#
# Tests 1-7 use an isolated mktemp repo; test 8 runs against the live
# Test 8a builds the grand-rounds bundle and runs that federation's own suite
# inside the extracted tarball, asserting the leak-guard mutation actually ran.
# worktree but cleans up `dist/` after. No live file is modified.
#
# Usage: ./tools/test-make-federation-bundle.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
REAL_BUNDLER="$SCRIPT_DIR/make-federation-bundle.sh"

if [ ! -x "$REAL_BUNDLER" ]; then
    echo "[FAIL] tools/make-federation-bundle.sh missing or not executable"
    exit 1
fi

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"; rm -rf "$REPO_ROOT/dist"' EXIT

# ----- Synthetic mini-repo for tests 1-7 -----
FAKE_REPO="$TMPDIR_TEST/repo"
mkdir -p "$FAKE_REPO/tools" "$FAKE_REPO/fakefed/nested" "$FAKE_REPO/doc" "$FAKE_REPO/.github/workflows"
cp "$REAL_BUNDLER" "$FAKE_REPO/tools/make-federation-bundle.sh"
chmod +x "$FAKE_REPO/tools/make-federation-bundle.sh"

# Legitimate federation + runtime content
echo "1.0.0" > "$FAKE_REPO/fakefed/VERSION"
echo "#!/bin/bash" > "$FAKE_REPO/fakefed/start.sh"
echo "echo fake" >> "$FAKE_REPO/fakefed/start.sh"
chmod +x "$FAKE_REPO/fakefed/start.sh"
echo "data" > "$FAKE_REPO/fakefed/nested/data.txt"
echo "shared toml parser" > "$FAKE_REPO/tools/parse-toml.sh"
echo "adr content" > "$FAKE_REPO/doc/ADR.md"

# Blacklisted contributor-only content that MUST NOT leak into bundles.
echo "repo-dev docs" > "$FAKE_REPO/CLAUDE.md"
echo "colony lint" > "$FAKE_REPO/tools/colony-lint.sh"
echo "tool test" > "$FAKE_REPO/tools/test-other.sh"
echo "check prompt" > "$FAKE_REPO/tools/check-prompt-gate.sh"
echo "scaffolder" > "$FAKE_REPO/tools/new-colony.sh"
echo "on: push" > "$FAKE_REPO/.github/workflows/ci.yml"

# ----- Test 1: arg validation -----
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -Fq "Usage:"; then
    pass "arg validation: zero args -> exit 1 + usage"
else
    fail "arg validation (zero args)" "rc=$RC, out=$OUT"
fi
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh fakefed 2>&1)"; RC=$?
if [ "$RC" -eq 1 ] && echo "$OUT" | grep -Fq "Usage:"; then
    pass "arg validation: one arg -> exit 1 + usage"
else
    fail "arg validation (one arg)" "rc=$RC, out=$OUT"
fi
set -e

# ----- Test 2: missing federation directory -----
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh nonexistent 0.0.1 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "federation directory"; then
    pass "missing federation dir -> exit 2"
else
    fail "missing-federation-dir" "rc=$RC, out=$OUT"
fi

# ----- Test 3: missing manifest -----
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh fakefed 0.0.1 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "BUNDLE.manifest"; then
    pass "missing manifest -> exit 2"
else
    fail "missing-manifest" "rc=$RC, out=$OUT"
fi

# ----- Test 4: empty manifest (only comments / blanks) -----
cat > "$FAKE_REPO/fakefed/BUNDLE.manifest" <<'EOF'
# Comment-only manifest.
#
#   indented comment

EOF
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh fakefed 0.0.1 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 2 ] && echo "$OUT" | grep -Fq "empty"; then
    pass "empty manifest -> exit 2"
else
    fail "empty-manifest" "rc=$RC, out=$OUT"
fi

# ----- Test 5: manifest lists non-existent path -----
cat > "$FAKE_REPO/fakefed/BUNDLE.manifest" <<'EOF'
fakefed/
tools/parse-toml.sh
tools/does-not-exist.sh
EOF
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh fakefed 0.0.1 2>&1)"; RC=$?
set -e
if [ "$RC" -eq 3 ] && echo "$OUT" | grep -Fq "does-not-exist"; then
    pass "manifest entry missing on disk -> exit 3"
else
    fail "manifest-entry-missing" "rc=$RC, out=$OUT"
fi

# ----- Test 6: happy path — tarball + sha256 + layout + no leaks -----
cat > "$FAKE_REPO/fakefed/BUNDLE.manifest" <<'EOF'
# fakefed bundle manifest (test fixture)
fakefed/
tools/parse-toml.sh
doc/ADR.md
EOF
set +e
OUT="$(cd "$FAKE_REPO" && ./tools/make-federation-bundle.sh fakefed 0.0.1 2>&1)"; RC=$?
set -e
TARBALL="$FAKE_REPO/dist/fakefed-v0.0.1.tar.gz"
SHAFILE="$FAKE_REPO/dist/fakefed-v0.0.1.tar.gz.sha256"
if [ "$RC" -ne 0 ]; then
    fail "happy-path exit" "rc=$RC, out=$OUT"
elif [ ! -f "$TARBALL" ]; then
    fail "happy-path tarball" "tarball not at $TARBALL; out=$OUT"
elif [ ! -f "$SHAFILE" ]; then
    fail "happy-path sha256" "sha256 not at $SHAFILE; out=$OUT"
else
    # sha256 matches
    if ( cd "$FAKE_REPO/dist" && sha256sum -c "fakefed-v0.0.1.tar.gz.sha256" >/dev/null 2>&1 ); then
        pass "happy path: tarball + .sha256 produced, sha256 verifies"
    else
        fail "happy-path sha256 verify" "sha256 mismatch"
    fi
fi

# Layout checks on the produced tarball
LIST="$(tar tzf "$TARBALL")"
for expected in \
    "fakefed-v0.0.1/fakefed/VERSION" \
    "fakefed-v0.0.1/fakefed/start.sh" \
    "fakefed-v0.0.1/fakefed/nested/data.txt" \
    "fakefed-v0.0.1/tools/parse-toml.sh" \
    "fakefed-v0.0.1/doc/ADR.md"; do
    if echo "$LIST" | grep -Fxq "$expected"; then :; else
        fail "happy-path layout" "expected '$expected' missing from tarball"
    fi
done
pass "happy path: every manifest-listed path present in tarball"

# Blacklist non-leakage
LEAKED=""
for blacklisted in \
    "CLAUDE.md" \
    ".github/workflows/ci.yml" \
    "tools/colony-lint.sh" \
    "tools/test-other.sh" \
    "tools/check-prompt-gate.sh" \
    "tools/new-colony.sh"; do
    if echo "$LIST" | grep -Fq "$blacklisted"; then
        LEAKED="$LEAKED $blacklisted"
    fi
done
if [ -z "$LEAKED" ]; then
    pass "happy path: no blacklisted contributor-only files leaked"
else
    fail "blacklist-leak" "leaked paths:$LEAKED"
fi

# ----- Test 7: bash -n on every .sh in extracted tree -----
EXTRACT="$TMPDIR_TEST/extract"
mkdir -p "$EXTRACT"
tar -C "$EXTRACT" -xzf "$TARBALL"
SHELL_BROKEN=0
while IFS= read -r -d '' sh; do
    if ! bash -n "$sh" 2>/dev/null; then
        SHELL_BROKEN=$((SHELL_BROKEN + 1))
        echo "  bash -n failed: $sh"
    fi
done < <(find "$EXTRACT" -name "*.sh" -print0)
if [ "$SHELL_BROKEN" -eq 0 ]; then
    pass "extracted tree: bash -n clean on every .sh"
else
    fail "extracted-bash-n" "$SHELL_BROKEN script(s) failed syntax check"
fi

# ----- Test 8a: a federation's OWN test suite must pass inside its bundle -----
# The gap this closes: grand-rounds shipped a tarball in which demo-baseline.sh
# reported 46 ok / 1 failed / exit 1, because the leak guard it invokes was not
# in BUNDLE.manifest — and the guard's mutation half passed vacuously for the
# same reason. Eleven green tests here missed it, because none of them ever RAN
# the federation's suite from inside the extracted tarball. This does.
GR_FED="grand-rounds"
GR_SUITE="baseline/demo-baseline.sh"
if [ ! -f "$REPO_ROOT/$GR_FED/$GR_SUITE" ]; then
    fail "bundled-suite" "$GR_FED/$GR_SUITE missing from the live repo"
else
    set +e
    OUT="$(cd "$REPO_ROOT" && ./tools/make-federation-bundle.sh "$GR_FED" 0.0.0-suite 2>&1)"; RC=$?
    set -e
    GR_TARBALL="$REPO_ROOT/dist/$GR_FED-v0.0.0-suite.tar.gz"
    if [ "$RC" -ne 0 ] || [ ! -f "$GR_TARBALL" ]; then
        fail "bundled-suite build" "rc=$RC, out=$OUT"
    else
        GR_X="$(mktemp -d)"
        tar xzf "$GR_TARBALL" -C "$GR_X"
        GR_ROOT="$GR_X/$GR_FED-v0.0.0-suite"
        set +e
        SUITE_OUT="$(cd "$GR_ROOT" && bash "./$GR_FED/$GR_SUITE" 2>&1)"; SUITE_RC=$?
        set -e
        if [ "$SUITE_RC" -ne 0 ]; then
            fail "bundled-suite" "demo-baseline.sh exits $SUITE_RC inside the bundle:
$(printf '%s' "$SUITE_OUT" | tail -5)"
        elif ! printf '%s' "$SUITE_OUT" | grep -q '0 failed'; then
            fail "bundled-suite" "no '0 failed' in the bundled run:
$(printf '%s' "$SUITE_OUT" | tail -5)"
        elif ! printf '%s' "$SUITE_OUT" | grep -q 'fails on a planted leak'; then
            # "0 failed" alone is not enough: with the guard missing from the
            # manifest the suite skips its leak-guard block and still reports
            # 0 failed. Require the MUTATION assertion to have actually run,
            # which it can only do when the guard script shipped.
            fail "bundled-suite" "leak-guard mutation test did not run in the bundle (guard not shipped?):
$(printf '%s' "$SUITE_OUT" | tail -5)"
        else
            pass "bundled-suite: grand-rounds demo-baseline.sh passes inside its own tarball, leak-guard mutation included"
        fi
        rm -rf "$GR_X" "$GR_TARBALL" "$GR_TARBALL.sha256" "$REPO_ROOT/dist/$GR_FED-v0.0.0-suite"
    fi
fi

# ----- Test 8: real federation smoke (uses live repo) -----
REAL_FED="dev-apprenticeship"
REAL_MANIFEST="$REPO_ROOT/$REAL_FED/BUNDLE.manifest"
if [ ! -f "$REAL_MANIFEST" ]; then
    fail "real-federation-smoke" "live manifest $REAL_MANIFEST missing"
else
    set +e
    OUT="$(cd "$REPO_ROOT" && ./tools/make-federation-bundle.sh "$REAL_FED" 0.0.0-smoke 2>&1)"; RC=$?
    set -e
    REAL_TARBALL="$REPO_ROOT/dist/$REAL_FED-v0.0.0-smoke.tar.gz"
    if [ "$RC" -ne 0 ] || [ ! -f "$REAL_TARBALL" ]; then
        fail "real-federation-smoke build" "rc=$RC, out=$OUT"
    else
        REAL_LIST="$(tar tzf "$REAL_TARBALL")"
        # Required runtime files
        MISSING=""
        for expected in \
            "$REAL_FED-v0.0.0-smoke/$REAL_FED/install.sh" \
            "$REAL_FED-v0.0.0-smoke/$REAL_FED/start-federation.sh" \
            "$REAL_FED-v0.0.0-smoke/$REAL_FED/VERSION" \
            "$REAL_FED-v0.0.0-smoke/$REAL_FED/CHANGELOG.md" \
            "$REAL_FED-v0.0.0-smoke/$REAL_FED/.dashboard-version" \
            "$REAL_FED-v0.0.0-smoke/tools/parse-toml.sh" \
            "$REAL_FED-v0.0.0-smoke/tools/auto-promote.sh" \
            "$REAL_FED-v0.0.0-smoke/doc/adr/ADR-0001-confidence-tiers.md" \
            "$REAL_FED-v0.0.0-smoke/README.md" \
            "$REAL_FED-v0.0.0-smoke/LICENSE"; do
            if ! echo "$REAL_LIST" | grep -Fxq "$expected"; then
                MISSING="$MISSING $expected"
            fi
        done
        # Contributor-only files that MUST NOT be present.
        # #252: tools/federation-dashboard* must NEVER appear here. The
        # dashboard is a separately-versioned standalone component now;
        # leaking it back into the federation bundle would mean two
        # competing dashboards at install time.
        REAL_LEAKED=""
        for blacklisted in \
            "CLAUDE.md" \
            ".github/" \
            "tools/colony-lint.sh" \
            "tools/check-changelog.sh" \
            "tools/check-exec-sh.sh" \
            "tools/check-prompt-gate.sh" \
            "tools/check-getenv-allowlist.sh" \
            "tools/new-colony.sh" \
            "tools/test-" \
            "tools/federation-dashboard" \
            "federation-dashboard/"; do
            if echo "$REAL_LIST" | grep -Fq "$blacklisted"; then
                REAL_LEAKED="$REAL_LEAKED $blacklisted"
            fi
        done
        if [ -z "$MISSING" ] && [ -z "$REAL_LEAKED" ]; then
            pass "real federation: all required runtime files in, no contributor files leaked"
        else
            [ -n "$MISSING" ] && fail "real-federation required-files" "missing:$MISSING"
            [ -n "$REAL_LEAKED" ] && fail "real-federation blacklist" "leaked:$REAL_LEAKED"
        fi
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
