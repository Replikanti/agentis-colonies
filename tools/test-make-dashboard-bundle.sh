#!/bin/bash
# tools/test-make-dashboard-bundle.sh: regression test for #252 — the standalone
# federation-dashboard release bundle must contain the runtime payload only,
# never contributor-only tooling, never Python bytecode, never the manifest
# file itself, and never any `dev-apprenticeship/` content. Mirrors the
# coverage `test-make-federation-bundle.sh` provides for the federation bundle.
#
# Usage: ./tools/test-make-dashboard-bundle.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUNDLER="$REPO_ROOT/tools/make-dashboard-bundle.sh"
COMP_DIR="$REPO_ROOT/federation-dashboard"
VERSION_FILE="$COMP_DIR/VERSION"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"

cleanup() { rm -rf "$TMPDIR_TEST"; }
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Sanity: bundler exists and is executable.
if [ ! -x "$BUNDLER" ]; then
    fail "0: bundler missing or not executable" "$BUNDLER"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Sanity: federation-dashboard/ exists and has VERSION.
if [ ! -f "$VERSION_FILE" ]; then
    fail "0: $VERSION_FILE missing"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

VERSION="$(tr -d ' \n' < "$VERSION_FILE")"

# --- Test 1: bundler refuses a version mismatch. ---
if BAD_OUT="$( "$BUNDLER" 99.99.99 2>&1 )"; then
    fail "1: bundler accepted mismatched version 99.99.99" "stdout: $BAD_OUT"
else
    if echo "$BAD_OUT" | grep -qE "VERSION file says.*argument is"; then
        pass "1: bundler rejects version mismatch with clear error"
    else
        fail "1: bundler rejected mismatch but error wording unexpected" "$BAD_OUT"
    fi
fi

# --- Build the canonical bundle once for tests 2-9. ---
DIST_DIR="$REPO_ROOT/dist"
TARBALL="$DIST_DIR/federation-dashboard-v${VERSION}.tar.gz"
SHAFILE="${TARBALL}.sha256"
rm -f "$TARBALL" "$SHAFILE"

if ! BUILD_OUT="$( "$BUNDLER" "$VERSION" 2>&1 )"; then
    fail "2: bundler exited non-zero on matching version" "$BUILD_OUT"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
pass "2: bundler exits 0 on matching version"

# --- Test 3: tarball + .sha256 produced. ---
if [ -s "$TARBALL" ] && [ -s "$SHAFILE" ]; then
    pass "3: tarball + .sha256 produced under dist/"
else
    fail "3: missing tarball or .sha256" "tarball=$TARBALL shafile=$SHAFILE"
fi

# --- Test 4: sha256 file matches tarball. ---
if command -v sha256sum >/dev/null 2>&1; then
    EXPECTED="$(sha256sum "$TARBALL" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
    EXPECTED="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
else
    EXPECTED=""
fi
if [ -n "$EXPECTED" ]; then
    RECORDED="$(awk '{print $1}' "$SHAFILE")"
    if [ "$EXPECTED" = "$RECORDED" ]; then
        pass "4: .sha256 matches tarball"
    else
        fail "4: sha256 mismatch" "expected=$EXPECTED recorded=$RECORDED"
    fi
else
    fail "4: no sha256 tool available to verify"
fi

# --- Capture the tarball's contents for the inclusion / exclusion tests. ---
LIST="$(tar tzf "$TARBALL")"

# --- Test 5: required runtime files are present. ---
MISSING=""
TOPDIR="federation-dashboard-v${VERSION}"
for expected in \
    "$TOPDIR/VERSION" \
    "$TOPDIR/CHANGELOG.md" \
    "$TOPDIR/README.md" \
    "$TOPDIR/install.sh" \
    "$TOPDIR/bin/federation-dashboard" \
    "$TOPDIR/lib/federation-dashboard-collector.py" \
    "$TOPDIR/lib/federation-dashboard-history.py" \
    "$TOPDIR/lib/federation-dashboard-renderer.py" \
    "$TOPDIR/lib/federation-dashboard-server.py" \
    "$TOPDIR/lib/federation-dashboard.html.template"; do
    if ! echo "$LIST" | grep -Fxq "$expected"; then
        MISSING="$MISSING $expected"
    fi
done
if [ -z "$MISSING" ]; then
    pass "5: tarball contains all required runtime files"
else
    fail "5: missing required files" "$MISSING"
fi

# --- Test 6: install.sh + bin/federation-dashboard executable bit preserved. ---
PERMS="$(tar -tzvf "$TARBALL" 2>/dev/null \
    | awk -v top="$TOPDIR" '
        $NF == top"/install.sh" || $NF == top"/bin/federation-dashboard" { print $1, $NF }
    ')"
echo "$PERMS" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    perm="${line%% *}"
    case "$perm" in
        *x*x*x*) ;;  # at least owner+group+other have x
        *x*) ;;      # owner has x
        *) echo "BAD: $line" ;;
    esac
done > "$TMPDIR_TEST/permcheck"
if [ ! -s "$TMPDIR_TEST/permcheck" ]; then
    pass "6: install.sh + bin/federation-dashboard preserve executable bit"
else
    fail "6: missing executable bit" "$(cat "$TMPDIR_TEST/permcheck")"
fi

# --- Test 7: BUNDLE.manifest must NOT leak into the tarball (it's a build-side
#     contract, not runtime). ---
if echo "$LIST" | grep -Fq "$TOPDIR/BUNDLE.manifest"; then
    fail "7: BUNDLE.manifest leaked into tarball"
else
    pass "7: BUNDLE.manifest correctly excluded"
fi

# --- Test 8: zero __pycache__ / *.pyc anywhere in the tarball. ---
LEAKED_BYTECODE="$(echo "$LIST" | grep -E '(__pycache__/|\.pyc$)' || true)"
if [ -z "$LEAKED_BYTECODE" ]; then
    pass "8: zero Python bytecode (__pycache__/, *.pyc) in tarball"
else
    fail "8: bytecode leaked" "$LEAKED_BYTECODE"
fi

# --- Test 9: zero `dev-apprenticeship/`, `tools/`, `.github/`, `CLAUDE.md`,
#     contributor-only paths in the tarball. The dashboard component must ship
#     standalone — leaking federation files would mean install collisions. ---
LEAKED=""
for blacklisted in \
    "dev-apprenticeship" \
    "tools/" \
    ".github" \
    "CLAUDE.md" \
    "test-" \
    "check-changelog" \
    "check-exec-sh" \
    "colony-lint" \
    "new-colony" \
    "make-federation-bundle" \
    "make-dashboard-bundle"; do
    if echo "$LIST" | grep -Fq "$blacklisted"; then
        LEAKED="$LEAKED $blacklisted"
    fi
done
if [ -z "$LEAKED" ]; then
    pass "9: zero federation / contributor-only paths leaked into bundle"
else
    fail "9: blacklisted paths leaked" "$LEAKED"
fi

# --- Test 10: tarball top-level has exactly one entry (the versioned dir),
#     i.e. extracting it does not splat files into cwd. ---
TOPS="$(echo "$LIST" | awk -F/ '{print $1}' | sort -u)"
TOPS_COUNT="$(echo "$TOPS" | wc -l | tr -d ' ')"
if [ "$TOPS_COUNT" = "1" ] && [ "$TOPS" = "$TOPDIR" ]; then
    pass "10: tarball wraps everything under exactly one top-level dir"
else
    fail "10: tarball top-level layout wrong" "got: $(echo "$TOPS" | tr '\n' ' ')"
fi

# --- Test 11: end-to-end install round-trip into a scratch prefix. ---
EXTRACT="$TMPDIR_TEST/extract"
PREFIX="$TMPDIR_TEST/prefix"
mkdir -p "$EXTRACT" "$PREFIX/.local/bin"
tar xzf "$TARBALL" -C "$EXTRACT"
if [ -d "$EXTRACT/$TOPDIR" ]; then
    if XDG_DATA_HOME="$PREFIX/.local/share" XDG_BIN_HOME="$PREFIX/.local/bin" \
            "$EXTRACT/$TOPDIR/install.sh" >/dev/null 2>&1; then
        if [ -x "$PREFIX/.local/share/federation-dashboard/bin/federation-dashboard" ] \
            && [ -L "$PREFIX/.local/bin/federation-dashboard" ]; then
            pass "11: install.sh installs into XDG-respecting prefix"
        else
            fail "11: install.sh ran but expected files not present"
        fi
    else
        fail "11: install.sh failed against scratch prefix"
    fi
else
    fail "11: tarball did not extract a $TOPDIR directory"
fi

# --- Test 12: uninstall round-trip. ---
if XDG_DATA_HOME="$PREFIX/.local/share" XDG_BIN_HOME="$PREFIX/.local/bin" \
        "$EXTRACT/$TOPDIR/install.sh" --uninstall >/dev/null 2>&1; then
    if [ ! -e "$PREFIX/.local/share/federation-dashboard" ] \
        && [ ! -e "$PREFIX/.local/bin/federation-dashboard" ]; then
        pass "12: install.sh --uninstall removes both data dir and symlink"
    else
        fail "12: uninstall left files behind"
    fi
else
    fail "12: install.sh --uninstall exited non-zero"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
