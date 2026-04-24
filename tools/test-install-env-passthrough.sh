#!/bin/bash
# tools/test-install-env-passthrough.sh: unit tests for the install.sh
# exec.env_passthrough fix (#277) and the daemon.heartbeat_interval_ms fix
# (#280). Both share the same `write_key` + exact-match migrate idiom, so
# the coverage lives in one harness.
#
# Validates:
#   Test 1: Fresh install writes the new env_passthrough literal
#   Test 2: env_passthrough upgrade rewrites the pre-fix literal
#   Test 3: Operator-tuned env_passthrough preserved (exact-match misses)
#   Test 4: Fresh install writes daemon.heartbeat_interval_ms = 900000
#   Test 5: Heartbeat upgrade rewrites the pre-fix 180000 literal
#   Test 6: Operator-tuned heartbeat (e.g. 300000) preserved
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

# ----- Heartbeat interval (#280) -----

# Replicates the install.sh write_key + upgrade logic for
# daemon.heartbeat_interval_ms under FAKE_ROOT.
# Keep in sync with dev-apprenticeship/install.sh §4 (heartbeat).
run_install_fragment_heartbeat() {
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

    # Migrate #280 pre-fix literal in-place. Exact-match only — any operator
    # customization (e.g. 300000 for a slow-LLM deployment) is preserved.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'daemon.heartbeat_interval_ms = 180000' "$AGENTIS_CONFIG"; then
        awk '/^daemon\.heartbeat_interval_ms = 180000$/ \
             { print "daemon.heartbeat_interval_ms = 900000"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    write_key 'daemon.heartbeat_interval_ms' '900000'
}

HB_EXPECTED_NEW='daemon.heartbeat_interval_ms = 900000'
HB_EXPECTED_OLD='daemon.heartbeat_interval_ms = 180000'
HB_OPERATOR_TUNED='daemon.heartbeat_interval_ms = 300000'

# ----- Test 4: Fresh install writes the 900000 heartbeat -----
T4_DIR="$FAKE_ROOT/t4"
mkdir -p "$T4_DIR"
T4_CONFIG="$T4_DIR/config"
: > "$T4_CONFIG"

run_install_fragment_heartbeat "$T4_CONFIG"

if grep -qxF "$HB_EXPECTED_NEW" "$T4_CONFIG"; then
    pass "fresh install writes daemon.heartbeat_interval_ms = 900000"
else
    fail "fresh install heartbeat — expected '$HB_EXPECTED_NEW', got:"
    cat "$T4_CONFIG"
fi

# ----- Test 5: Upgrade path rewrites 180000 -> 900000 -----
T5_DIR="$FAKE_ROOT/t5"
mkdir -p "$T5_DIR"
T5_CONFIG="$T5_DIR/config"
printf '%s\n' "$HB_EXPECTED_OLD" > "$T5_CONFIG"

run_install_fragment_heartbeat "$T5_CONFIG"

if grep -qxF "$HB_EXPECTED_NEW" "$T5_CONFIG" \
    && ! grep -qxF "$HB_EXPECTED_OLD" "$T5_CONFIG"; then
    pass "upgrade path rewrites heartbeat 180000 to 900000"
else
    fail "heartbeat upgrade — expected '$HB_EXPECTED_NEW' and no '$HB_EXPECTED_OLD', got:"
    cat "$T5_CONFIG"
fi

# ----- Test 6: Operator-tuned heartbeat preserved -----
T6_DIR="$FAKE_ROOT/t6"
mkdir -p "$T6_DIR"
T6_CONFIG="$T6_DIR/config"
printf '%s\n' "$HB_OPERATOR_TUNED" > "$T6_CONFIG"

run_install_fragment_heartbeat "$T6_CONFIG"

if grep -qxF "$HB_OPERATOR_TUNED" "$T6_CONFIG" \
    && ! grep -qxF "$HB_EXPECTED_NEW" "$T6_CONFIG"; then
    pass "operator-tuned heartbeat preserved (exact-match gate did not match)"
else
    fail "operator-tuned heartbeat preservation — expected '$HB_OPERATOR_TUNED' untouched, got:"
    cat "$T6_CONFIG"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
