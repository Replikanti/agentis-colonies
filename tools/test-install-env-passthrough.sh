#!/bin/bash
# tools/test-install-env-passthrough.sh: unit tests for the install.sh
# exec.env_passthrough fix (#277), the daemon.heartbeat_interval_ms fix
# (#280), and the gitlab:me operator-identity seed fix (#278). All three
# share the same `run_install_fragment*` harness idiom, so the coverage
# lives in one file.
#
# Validates:
#   Test 1: Fresh install writes the new env_passthrough literal
#   Test 2: env_passthrough upgrade rewrites the pre-fix literal
#   Test 3: Operator-tuned env_passthrough preserved (exact-match misses)
#   Test 4: Fresh install writes daemon.heartbeat_interval_ms = 900000
#   Test 5: Heartbeat upgrade rewrites the pre-fix 180000 literal
#   Test 6: Operator-tuned heartbeat (e.g. 300000) preserved
#   Test 7: GITHUB_ME (GITLAB_ME unset) seeds gitlab:me on github backend
#   Test 8: GITLAB_ME (GITHUB_ME unset) seeds gitlab:me on gitlab backend
#   Test 9: Both unset — gitlab:me memo left unset
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

# ----- Operator identity seed (#278) -----
#
# Replicates the install.sh §5b gitlab:me seeding logic under FAKE_ROOT.
# Unlike #277/#280 the fragment operates on the memo store via the
# `agentis` CLI (not a config file), so each test needs a real
# `agentis init`ed directory as FED_ROOT. Skip gracefully when
# `agentis` is not on PATH (CI runners without the binary).
# Keep in sync with dev-apprenticeship/install.sh §5b.
run_install_fragment_gitlab_me() {
    local FED_ROOT="$1"

    OPERATOR_ME="${GITLAB_ME:-${GITHUB_ME:-}}"
    if [ -n "$OPERATOR_ME" ]; then
        local current
        # shellcheck disable=SC2015
        current=$(cd "$FED_ROOT" && agentis memo get gitlab:me 2>/dev/null || true)
        if [ -z "$current" ] || [ "$current" = "$OPERATOR_ME" ]; then
            (cd "$FED_ROOT" && agentis memo set gitlab:me "$OPERATOR_ME" 2>/dev/null) || true
        fi
    fi
}

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis not on PATH — skipping #278 memo tests (T7/T8/T9)"
else
    # ----- Test 7: GITHUB_ME seeds gitlab:me on github backend -----
    T7_DIR="$FAKE_ROOT/t7"
    mkdir -p "$T7_DIR"
    (cd "$T7_DIR" && agentis init >/dev/null 2>&1) || true
    (
        unset GITLAB_ME
        export GITHUB_ME=ylohnitram
        run_install_fragment_gitlab_me "$T7_DIR"
    )
    # shellcheck disable=SC2015
    T7_GOT=$(cd "$T7_DIR" && agentis memo get gitlab:me 2>/dev/null || true)
    if [ "$T7_GOT" = "ylohnitram" ]; then
        pass "GITHUB_ME=ylohnitram seeds gitlab:me memo to 'ylohnitram'"
    else
        fail "GITHUB_ME seeding — expected 'ylohnitram', got: '$T7_GOT'"
    fi

    # ----- Test 8: GITLAB_ME seeds gitlab:me on gitlab backend -----
    T8_DIR="$FAKE_ROOT/t8"
    mkdir -p "$T8_DIR"
    (cd "$T8_DIR" && agentis init >/dev/null 2>&1) || true
    (
        unset GITHUB_ME
        export GITLAB_ME=martinh
        run_install_fragment_gitlab_me "$T8_DIR"
    )
    # shellcheck disable=SC2015
    T8_GOT=$(cd "$T8_DIR" && agentis memo get gitlab:me 2>/dev/null || true)
    if [ "$T8_GOT" = "martinh" ]; then
        pass "GITLAB_ME=martinh seeds gitlab:me memo to 'martinh'"
    else
        fail "GITLAB_ME seeding — expected 'martinh', got: '$T8_GOT'"
    fi

    # ----- Test 9: Both unset — gitlab:me left unset -----
    T9_DIR="$FAKE_ROOT/t9"
    mkdir -p "$T9_DIR"
    (cd "$T9_DIR" && agentis init >/dev/null 2>&1) || true
    (
        unset GITLAB_ME
        unset GITHUB_ME
        run_install_fragment_gitlab_me "$T9_DIR"
    )
    # shellcheck disable=SC2015
    T9_GOT=$(cd "$T9_DIR" && agentis memo get gitlab:me 2>/dev/null || true)
    if [ -z "$T9_GOT" ]; then
        pass "both GITLAB_ME and GITHUB_ME unset — gitlab:me memo left unset"
    else
        fail "no-op case — expected empty memo, got: '$T9_GOT'"
    fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
