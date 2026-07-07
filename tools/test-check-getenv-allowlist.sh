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
if "$CHECK" "$T6" >/dev/null 2>&1; then
    fail "typo-suffixed waiver — expected the check to still fail"
else
    pass "typo-suffixed waiver (getenv-unregistered-okey) does not suppress the check"
fi

# ----- Test 7: real repo passes clean -----
T7_OUT="$("$CHECK" "$REPO_ROOT" 2>&1)" && T7_RC=0 || T7_RC=$?
if [ "$T7_RC" -eq 0 ]; then
    pass "real repo: every dev-apprenticeship getenv() knob allowlisted or waived"
else
    fail "real repo — expected exit 0, got rc=$T7_RC: $T7_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
