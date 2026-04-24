#!/bin/bash
# tools/test-install-env-passthrough.sh: unit tests for the install.sh
# exec.env_passthrough fix and in-place upgrade block (#277).
#
# Validates:
#   Test 1: Fresh install writes the new literal with FORGE_TYPE + GITHUB_*
#   Test 2: Upgrade path rewrites the pre-fix literal to the new value
#   Test 3: Operator-tuned values are preserved (exact-match gate misses)
#
# Usage: ./tools/test-install-env-passthrough.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

FAKE_ROOT="$(mktemp -d)"
trap 'rm -rf "$FAKE_ROOT"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

# Replicates the install.sh write_key + upgrade logic under FAKE_ROOT.
# Keep in sync with dev-apprenticeship/install.sh §4 (env_passthrough).
run_install_fragment() {
    local AGENTIS_CONFIG="$1"

    write_key() {
        local key="$1"
        local value="$2"
        local grep_key
        grep_key=$(printf '%s' "$key" | sed 's/\./\\./g')
        if ! grep -q "^${grep_key}[[:space:]]*=" "$AGENTIS_CONFIG" 2>/dev/null; then
            printf '%s = %s\n' "$key" "$value" >> "$AGENTIS_CONFIG"
        fi
    }

    # Migrate #277 pre-fix literal in-place. Exact-match only — any operator
    # customization (extra vars, reordering) is preserved untouched.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,GITLAB_*' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,GITLAB_\*$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    write_key 'exec.env_passthrough' 'COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*'
}

EXPECTED_NEW='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*'
EXPECTED_OLD='exec.env_passthrough = COLONY_DIR,GITLAB_*'
OPERATOR_TUNED='exec.env_passthrough = COLONY_DIR,GITLAB_*,MY_CUSTOM'

# ----- Test 1: Fresh install -----
T1_DIR="$FAKE_ROOT/t1"
mkdir -p "$T1_DIR"
T1_CONFIG="$T1_DIR/config"
: > "$T1_CONFIG"

run_install_fragment "$T1_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T1_CONFIG"; then
    pass "fresh install writes exec.env_passthrough with FORGE_TYPE + GITHUB_*"
else
    fail "fresh install — expected '$EXPECTED_NEW', got:"
    cat "$T1_CONFIG"
fi

# ----- Test 2: Upgrade path -----
T2_DIR="$FAKE_ROOT/t2"
mkdir -p "$T2_DIR"
T2_CONFIG="$T2_DIR/config"
printf '%s\n' "$EXPECTED_OLD" > "$T2_CONFIG"

run_install_fragment "$T2_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T2_CONFIG" \
    && ! grep -qxF "$EXPECTED_OLD" "$T2_CONFIG"; then
    pass "upgrade path rewrites pre-fix literal to the new value"
else
    fail "upgrade path — expected '$EXPECTED_NEW', got:"
    cat "$T2_CONFIG"
fi

# ----- Test 3: Operator-tuned preserved -----
T3_DIR="$FAKE_ROOT/t3"
mkdir -p "$T3_DIR"
T3_CONFIG="$T3_DIR/config"
printf '%s\n' "$OPERATOR_TUNED" > "$T3_CONFIG"

run_install_fragment "$T3_CONFIG"

if grep -qxF "$OPERATOR_TUNED" "$T3_CONFIG" \
    && ! grep -qxF "$EXPECTED_NEW" "$T3_CONFIG"; then
    pass "operator-tuned value preserved (exact-match gate did not match)"
else
    fail "operator-tuned preservation — expected '$OPERATOR_TUNED' untouched, got:"
    cat "$T3_CONFIG"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
