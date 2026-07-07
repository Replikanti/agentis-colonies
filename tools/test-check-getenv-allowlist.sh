#!/bin/bash
# tools/test-check-getenv-allowlist.sh: unit tests for
# check-getenv-allowlist.sh (#1428).
#
# Validates:
#   Test 1: allowlisted exact-name getenv passes
#   Test 2: glob-covered getenv (GITLAB_FOO under GITLAB_*) passes,
#           without a residue-list requirement
#   Test 3: waived unregistered getenv passes (annotation on the line
#           or the preceding line)
#   Test 4: unregistered getenv fails with [UNREGISTERED]
#   Test 5: allowlisted getenv missing from the #1437 residue list fails
#           with [RESIDUE-DRIFT] (reported once across multiple readers)
#   Test 6: a typo-suffixed waiver (getenv-unregistered-okey) does NOT
#           suppress the check
#   Test 7: the real repo passes clean (end-to-end)
#   Test 8: glob entries survive a hostile cwd (a file named GITLAB_TOKEN
#           in the caller's working dir must not corrupt matching; set -f)
#   Test 9: a newline-`do` residue loop cannot mask drift (the extractor
#           must stop at the bare `do` line, not sweep later ALLCAPS words)
#   Test 10: `//` inside a string literal (URL) does not blind the scanner
#            to a getenv() later on the same line
#   Test 11: missing dev-apprenticeship/install.sh exits 2 (infra error),
#            distinct from the exit-1 finding path
#   Test 12: two getenv() on one line are both scanned — exactly one
#            [UNREGISTERED] for the unregistered var, none for the
#            allowlisted one
#
# Usage: ./tools/test-check-getenv-allowlist.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

TOOLS_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$TOOLS_DIR/.." && pwd)"
CHECK="$TOOLS_DIR/check-getenv-allowlist.sh"

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# make_fixture <root> <allowlist-literal> <residue-knobs...>
# Builds a minimal dev-apprenticeship tree with an install.sh carrying the
# write_key allowlist line and a #1437-style residue-check loop.
make_fixture() {
    local root="$1" allowlist="$2"
    shift 2
    mkdir -p "$root/dev-apprenticeship/triage/agents"
    {
        printf '#!/bin/bash\n'
        printf "    write_key 'exec.env_passthrough'         '%s'\n" "$allowlist"
        printf '    for knob in %s; do\n' "$*"
        printf '        :\n    done\n'
    } > "$root/dev-apprenticeship/install.sh"
}

# ----- Test 1: allowlisted exact name passes -----
T1="$FAKE_ROOT/t1"
make_fixture "$T1" 'COLONY_DIR,GITLAB_*,MY_KNOB' 'MY_KNOB'
cat > "$T1/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let x = getenv("MY_KNOB");
}
EOF
if "$CHECK" "$T1" >/dev/null 2>&1; then
    pass "allowlisted exact-name getenv passes"
else
    fail "allowlisted exact-name getenv — expected exit 0, got: $("$CHECK" "$T1" 2>&1 || true)"
fi

# ----- Test 2: glob-covered getenv passes without a residue entry -----
T2="$FAKE_ROOT/t2"
make_fixture "$T2" 'COLONY_DIR,GITLAB_*' 'COLONY_DIR'
cat > "$T2/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let url = getenv("GITLAB_URL");
}
EOF
if "$CHECK" "$T2" >/dev/null 2>&1; then
    pass "glob-covered getenv passes (no residue-list requirement for globs)"
else
    fail "glob-covered getenv — expected exit 0, got: $("$CHECK" "$T2" 2>&1 || true)"
fi

# ----- Test 3: waived unregistered getenv passes -----
T3="$FAKE_ROOT/t3"
make_fixture "$T3" 'COLONY_DIR' 'COLONY_DIR'
cat > "$T3/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    // colony-lint: getenv-unregistered-ok
    let x = getenv("NOT_A_KNOB");
    let y = getenv("ALSO_NOT_A_KNOB"); // colony-lint: getenv-unregistered-ok
}
EOF
if "$CHECK" "$T3" >/dev/null 2>&1; then
    pass "waived unregistered getenv passes (preceding-line and same-line annotation)"
else
    fail "waived getenv — expected exit 0, got: $("$CHECK" "$T3" 2>&1 || true)"
fi

# ----- Test 4: unregistered getenv fails with [UNREGISTERED] -----
T4="$FAKE_ROOT/t4"
make_fixture "$T4" 'COLONY_DIR' 'COLONY_DIR'
cat > "$T4/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let x = getenv("SHINY_NEW_KNOB");
}
EOF
T4_OUT="$("$CHECK" "$T4" 2>&1)" && T4_RC=0 || T4_RC=$?
if [ "$T4_RC" -eq 1 ] && printf '%s' "$T4_OUT" | grep -q '\[UNREGISTERED\].*SHINY_NEW_KNOB'; then
    pass "unregistered getenv fails with [UNREGISTERED]"
else
    fail "unregistered getenv — expected exit 1 + [UNREGISTERED], got rc=$T4_RC: $T4_OUT"
fi

# ----- Test 5: residue-list drift fails with [RESIDUE-DRIFT], once -----
T5="$FAKE_ROOT/t5"
make_fixture "$T5" 'COLONY_DIR,DRIFTED_KNOB' 'COLONY_DIR'
cat > "$T5/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let x = getenv("DRIFTED_KNOB");
}
EOF
cat > "$T5/dev-apprenticeship/triage/agents/b.ag" <<'EOF'
fn tick() -> void {
    let x = getenv("DRIFTED_KNOB");
}
EOF
T5_OUT="$("$CHECK" "$T5" 2>&1)" && T5_RC=0 || T5_RC=$?
T5_COUNT="$(printf '%s\n' "$T5_OUT" | grep -c '\[RESIDUE-DRIFT\]' || true)"
if [ "$T5_RC" -eq 1 ] && [ "$T5_COUNT" -eq 1 ]; then
    pass "residue-list drift fails with a single [RESIDUE-DRIFT] across multiple readers"
else
    fail "residue drift — expected exit 1 + exactly one [RESIDUE-DRIFT], got rc=$T5_RC count=$T5_COUNT: $T5_OUT"
fi

# ----- Test 6: typo-suffixed waiver does not suppress -----
T6="$FAKE_ROOT/t6"
make_fixture "$T6" 'COLONY_DIR' 'COLONY_DIR'
cat > "$T6/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    // colony-lint: getenv-unregistered-okey
    let x = getenv("SNEAKY_KNOB");
}
EOF
T6_OUT="$("$CHECK" "$T6" 2>&1)" && T6_RC=0 || T6_RC=$?
if [ "$T6_RC" -eq 1 ] && printf '%s' "$T6_OUT" | grep -q '\[UNREGISTERED\].*SNEAKY_KNOB'; then
    pass "typo-suffixed waiver (getenv-unregistered-okey) does not suppress the check"
else
    fail "typo-suffixed waiver — expected exit 1 + [UNREGISTERED], got rc=$T6_RC: $T6_OUT"
fi

# ----- Test 7: real repo passes clean -----
T7_OUT="$("$CHECK" "$REPO_ROOT" 2>&1)" && T7_RC=0 || T7_RC=$?
if [ "$T7_RC" -eq 0 ]; then
    pass "real repo: every dev-apprenticeship getenv() knob allowlisted or waived"
else
    fail "real repo — expected exit 0, got rc=$T7_RC: $T7_OUT"
fi

# ----- Test 8: glob entries survive a hostile cwd (set -f regression) -----
# Without `set -f`, `for entry in $ALLOWLIST` pathname-expands the GITLAB_*
# glob entry against the caller's cwd — a file literally named GITLAB_TOKEN
# (a very plausible credentials file) replaces the glob with filenames and
# produces a false [UNREGISTERED] for glob-covered vars.
T8="$FAKE_ROOT/t8"
make_fixture "$T8" 'COLONY_DIR,GITLAB_*' 'COLONY_DIR'
cat > "$T8/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let url = getenv("GITLAB_URL");
}
EOF
T8_CWD="$FAKE_ROOT/t8-cwd"
mkdir -p "$T8_CWD"
touch "$T8_CWD/GITLAB_TOKEN" "$T8_CWD/GITLAB_URL"
T8_OUT="$( (cd "$T8_CWD" && "$CHECK" "$T8") 2>&1 )" && T8_RC=0 || T8_RC=$?
if [ "$T8_RC" -eq 0 ]; then
    pass "glob entry survives a cwd containing GITLAB_* files (set -f)"
else
    fail "hostile-cwd glob — expected exit 0, got rc=$T8_RC: $T8_OUT"
fi

# ----- Test 9: newline-`do` residue loop cannot mask drift -----
# The residue extractor must stop collecting at a bare `do` line; if it ran
# to EOF it would sweep every later ALLCAPS word (here: the echo DRIFTED
# line) into the list and hide a real drift.
T9="$FAKE_ROOT/t9"
mkdir -p "$T9/dev-apprenticeship/triage/agents"
{
    printf '#!/bin/bash\n'
    printf "    write_key 'exec.env_passthrough'         'COLONY_DIR,DRIFTED'\n"
    printf '    for knob in COLONY_DIR\n'
    printf '    do\n        :\n    done\n'
    printf '    echo DRIFTED\n'
} > "$T9/dev-apprenticeship/install.sh"
cat > "$T9/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let x = getenv("DRIFTED");
}
EOF
T9_OUT="$("$CHECK" "$T9" 2>&1)" && T9_RC=0 || T9_RC=$?
if [ "$T9_RC" -eq 1 ] && printf '%s' "$T9_OUT" | grep -q '\[RESIDUE-DRIFT\].*DRIFTED'; then
    pass "newline-do residue loop: drift still detected (extractor stops at bare do)"
else
    fail "newline-do drift — expected exit 1 + [RESIDUE-DRIFT], got rc=$T9_RC: $T9_OUT"
fi

# ----- Test 10: // inside a string literal does not blind the scanner -----
T10="$FAKE_ROOT/t10"
make_fixture "$T10" 'COLONY_DIR' 'COLONY_DIR'
cat > "$T10/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let u = "https://example.com/" + getenv("URL_SUFFIX_KNOB");
}
EOF
T10_OUT="$("$CHECK" "$T10" 2>&1)" && T10_RC=0 || T10_RC=$?
if [ "$T10_RC" -eq 1 ] && printf '%s' "$T10_OUT" | grep -q '\[UNREGISTERED\].*URL_SUFFIX_KNOB'; then
    pass "URL string literal (//) does not hide a getenv() on the same line"
else
    fail "URL-line getenv — expected exit 1 + [UNREGISTERED], got rc=$T10_RC: $T10_OUT"
fi

# ----- Test 11: missing install.sh exits 2 (infra error, not a finding) -----
# colony-lint labels exit 2 distinctly ("infra/usage error — not a knob
# finding"), so the script must never collapse infra errors into exit 1.
T11="$FAKE_ROOT/t11"
mkdir -p "$T11/dev-apprenticeship/triage/agents"
T11_OUT="$("$CHECK" "$T11" 2>&1)" && T11_RC=0 || T11_RC=$?
if [ "$T11_RC" -eq 2 ] && printf '%s' "$T11_OUT" | grep -q 'install.sh not found'; then
    pass "missing install.sh exits 2 with an infra-error message"
else
    fail "missing install.sh — expected exit 2 + 'install.sh not found', got rc=$T11_RC: $T11_OUT"
fi

# ----- Test 12: two getenv() on one line are both scanned -----
T12="$FAKE_ROOT/t12"
make_fixture "$T12" 'COLONY_DIR,GOOD_KNOB' 'GOOD_KNOB'
cat > "$T12/dev-apprenticeship/triage/agents/a.ag" <<'EOF'
fn tick() -> void {
    let pair = getenv("GOOD_KNOB") + getenv("BAD_KNOB");
}
EOF
T12_OUT="$("$CHECK" "$T12" 2>&1)" && T12_RC=0 || T12_RC=$?
T12_COUNT="$(printf '%s\n' "$T12_OUT" | grep -c '\[UNREGISTERED\]' || true)"
if [ "$T12_RC" -eq 1 ] && [ "$T12_COUNT" -eq 1 ] \
    && printf '%s' "$T12_OUT" | grep -q '\[UNREGISTERED\].*BAD_KNOB'; then
    pass "two getenv() on one line: only the unregistered one is flagged"
else
    fail "same-line multi-getenv — expected exit 1 + one [UNREGISTERED] for BAD_KNOB, got rc=$T12_RC count=$T12_COUNT: $T12_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
