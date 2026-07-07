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
#   Test 10: Fresh install env_passthrough carries the trigger-label vars (#1185)
#   Test 11: #1185 upgrade rewrites the #277-era literal to add trigger-labels
#   Test 12: #277-era pre-fix literal also migrates straight to the #1185 value
#   Test 13: #1185-era literal migrates straight to the PLAN_AUTO_PROMOTE value
#   Test 14: #1317-era literal migrates to add PLAN_AUTO_PROMOTE (#1362)
#   Test 15: #1362-era literal migrates to add AG_DRIVEN_EDIT_LOOP +
#            CODE_EDIT_MAX_CONCURRENT + LLM_MAX_CONCURRENT (#1354/#1352)
#   Test 16: #1354/#1352-era literal migrates to add the triage crystallizer
#            rule knobs + BM25-recall knobs (#1429/#1428)
#   Test 17: #1429-era literal migrates to add the prioritizer pilot knobs
#            (#1430)
#   Test 18: #1437 residue check warns on a hand-customized allowlist that
#            is missing getenv knobs — and never modifies it
#   Test 19: #1430-era literal migrates to add QA_ADVERSARIAL_LLM_CMD +
#            CODE_EDIT_MAX_ATTEMPTS (#1428)
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
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1185 pre-fix literal in-place. Upgrades the #277-era value to
    # also pass through the trigger-label vars. Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1317 pre-fix literal in-place. Adds AUTO_MERGE so the
    # code-review colony's opt-in auto-merge flag survives the env strip.
    # Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1362 pre-fix literal in-place. Adds PLAN_AUTO_PROMOTE so the
    # planning colony's opt-in plan-approved auto-promotion flag survives the
    # env strip. Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1354/#1352 pre-fix literal in-place. Adds AG_DRIVEN_EDIT_LOOP
    # (getenv() reads the SANITIZED env, so the v2.4.0 default is inert without
    # it), CODE_EDIT_MAX_CONCURRENT (#1367) and the #1352 cap size
    # LLM_MAX_CONCURRENT (AGENTIS_* is force-stripped by agentis-core, so the
    # slot dir is derived from COLONY_DIR in the lib instead). Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1429 pre-fix literal in-place. Adds the triage crystallizer
    # rule knobs (the #1234/#1235 pilot knobs shipped without an allowlist
    # entry and were silently inert, #1428) + the #1429 BM25-recall knobs.
    # Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1430 pre-fix literal in-place. Adds the prioritizer pilot
    # knobs. Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    # Migrate #1430 pre-fix literal in-place. Closes the #1428 audit: adds
    # QA_ADVERSARIAL_LLM_CMD + CODE_EDIT_MAX_ATTEMPTS. Exact-match only.
    if [ -f "$AGENTIS_CONFIG" ] && grep -qxF 'exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL' "$AGENTIS_CONFIG"; then
        awk '/^exec\.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_\*,GITHUB_\*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL$/ \
             { print "exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL,QA_ADVERSARIAL_LLM_CMD,CODE_EDIT_MAX_ATTEMPTS"; next } { print }' \
            "$AGENTIS_CONFIG" > "$AGENTIS_CONFIG.tmp" && mv "$AGENTIS_CONFIG.tmp" "$AGENTIS_CONFIG"
    fi
    write_key 'exec.env_passthrough' 'COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL,QA_ADVERSARIAL_LLM_CMD,CODE_EDIT_MAX_ATTEMPTS'
}

EXPECTED_NEW='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL,QA_ADVERSARIAL_LLM_CMD,CODE_EDIT_MAX_ATTEMPTS'
EXPECTED_1430='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K,PRIORITIZER_RULE_FIRST,PRIORITIZER_RULE_CONFIDENCE,PRIORITIZER_BM25_RECALL'
EXPECTED_1429='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT,LABELER_RULE_FIRST,LABELER_RULE_CONFIDENCE,ROUTER_RULE_FIRST,ROUTER_RULE_CONFIDENCE,LABELER_BM25_RECALL,ROUTER_BM25_RECALL,TRIAGE_BM25_K'
EXPECTED_1354='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE,CODE_EDIT_MAX_CONCURRENT,AG_DRIVEN_EDIT_LOOP,LLM_MAX_CONCURRENT'
EXPECTED_1362='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE,PLAN_AUTO_PROMOTE'
EXPECTED_1317='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL,AUTO_MERGE'
EXPECTED_1185='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*,IMPLEMENTATION_TRIGGER_LABEL,PLANNING_TRIGGER_LABEL'
EXPECTED_277='exec.env_passthrough = COLONY_DIR,FORGE_TYPE,GITLAB_*,GITHUB_*'
EXPECTED_OLD='exec.env_passthrough = COLONY_DIR,GITLAB_*'
OPERATOR_TUNED='exec.env_passthrough = COLONY_DIR,GITLAB_*,MY_CUSTOM'

# ----- Test 1: Fresh install -----
T1_DIR="$FAKE_ROOT/t1"
mkdir -p "$T1_DIR"
T1_CONFIG="$T1_DIR/config"
: > "$T1_CONFIG"

run_install_fragment "$T1_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T1_CONFIG"; then
    pass "fresh install writes exec.env_passthrough with FORGE_TYPE + GITHUB_* + trigger labels"
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

# ----- Trigger-label env passthrough (#1185) -----

# ----- Test 10: Fresh install carries the trigger-label vars -----
# A colony.toml `trigger_label` override is exported by start-colony.sh as
# IMPLEMENTATION_TRIGGER_LABEL / PLANNING_TRIGGER_LABEL; without them in the
# allowlist agentis strips the override before `exec sh forge-api.sh`.
T10_DIR="$FAKE_ROOT/t10"
mkdir -p "$T10_DIR"
T10_CONFIG="$T10_DIR/config"
: > "$T10_CONFIG"

run_install_fragment "$T10_CONFIG"

if grep -q 'IMPLEMENTATION_TRIGGER_LABEL' "$T10_CONFIG" \
    && grep -q 'PLANNING_TRIGGER_LABEL' "$T10_CONFIG"; then
    pass "fresh install env_passthrough carries IMPLEMENTATION_TRIGGER_LABEL + PLANNING_TRIGGER_LABEL (#1185)"
else
    fail "fresh install trigger labels — expected both trigger-label vars, got:"
    cat "$T10_CONFIG"
fi

# ----- Test 11: #1185 upgrade rewrites the #277-era literal -----
T11_DIR="$FAKE_ROOT/t11"
mkdir -p "$T11_DIR"
T11_CONFIG="$T11_DIR/config"
printf '%s\n' "$EXPECTED_277" > "$T11_CONFIG"

run_install_fragment "$T11_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T11_CONFIG" \
    && ! grep -qxF "$EXPECTED_277" "$T11_CONFIG"; then
    pass "#1185 upgrade rewrites #277-era literal to add the trigger-label vars"
else
    fail "#1185 upgrade — expected '$EXPECTED_NEW' and no bare '$EXPECTED_277', got:"
    cat "$T11_CONFIG"
fi

# ----- Test 12: #277-era pre-fix literal migrates straight to the #1185 value -----
# The #277 migration's awk target now emits the full #1185 value, so an even
# older `COLONY_DIR,GITLAB_*` config lands on the trigger-label value in one
# install run (no second pass needed).
T12_DIR="$FAKE_ROOT/t12"
mkdir -p "$T12_DIR"
T12_CONFIG="$T12_DIR/config"
printf '%s\n' "$EXPECTED_OLD" > "$T12_CONFIG"

run_install_fragment "$T12_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T12_CONFIG" \
    && ! grep -qxF "$EXPECTED_OLD" "$T12_CONFIG"; then
    pass "#277-era literal migrates straight to the PLAN_AUTO_PROMOTE value"
else
    fail "#277->#1362 migration — expected '$EXPECTED_NEW', got:"
    cat "$T12_CONFIG"
fi

# ----- Test 13: #1185-era literal migrates straight to the PLAN_AUTO_PROMOTE value -----
# A federation installed between #1185 and #1317 carries the trigger-label
# value without AUTO_MERGE; the chained #1317 + #1362 migrations append both
# AUTO_MERGE and PLAN_AUTO_PROMOTE in one install run.
T13_DIR="$FAKE_ROOT/t13"
mkdir -p "$T13_DIR"
T13_CONFIG="$T13_DIR/config"
printf '%s\n' "$EXPECTED_1185" > "$T13_CONFIG"

run_install_fragment "$T13_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T13_CONFIG" \
    && ! grep -qxF "$EXPECTED_1185" "$T13_CONFIG"; then
    pass "#1185-era literal migrates straight to the PLAN_AUTO_PROMOTE value"
else
    fail "#1185->#1362 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1185', got:"
    cat "$T13_CONFIG"
fi

# ----- Test 14: #1317-era literal migrates to add PLAN_AUTO_PROMOTE (#1362) -----
# A federation installed between #1317 and #1362 carries the AUTO_MERGE value
# without PLAN_AUTO_PROMOTE; the #1362 migration appends it so the planning
# colony's opt-in auto-promotion flag survives the env strip before `exec sh`.
T14_DIR="$FAKE_ROOT/t14"
mkdir -p "$T14_DIR"
T14_CONFIG="$T14_DIR/config"
printf '%s\n' "$EXPECTED_1317" > "$T14_CONFIG"

run_install_fragment "$T14_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T14_CONFIG" \
    && ! grep -qxF "$EXPECTED_1317" "$T14_CONFIG"; then
    pass "#1317-era literal migrates to add PLAN_AUTO_PROMOTE (#1362)"
else
    fail "#1317->#1362 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1317', got:"
    cat "$T14_CONFIG"
fi

# ----- Test 15: #1362-era literal migrates to the #1354/#1352 value -----
# A federation installed between #1362 and the #1354/#1352 fix carries the
# PLAN_AUTO_PROMOTE value without AG_DRIVEN_EDIT_LOOP — on such an install the
# v2.4.0 caller-driven-edit-loop default is silently inert (getenv() reads the
# SANITIZED env; the flag never reaches code_writer.ag) and the cap-size override is
# stripped from code-edit children. The migration appends the three vars.
T15_DIR="$FAKE_ROOT/t15"
mkdir -p "$T15_DIR"
T15_CONFIG="$T15_DIR/config"
printf '%s\n' "$EXPECTED_1362" > "$T15_CONFIG"

run_install_fragment "$T15_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T15_CONFIG" \
    && ! grep -qxF "$EXPECTED_1362" "$T15_CONFIG"; then
    pass "#1362-era literal migrates to add AG_DRIVEN_EDIT_LOOP + cap vars (#1354/#1352)"
else
    fail "#1362->#1354/#1352 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1362', got:"
    cat "$T15_CONFIG"
fi

# ----- Test 16: #1354/#1352-era literal migrates to add the rule knobs (#1429) -----
# A federation installed between #1354/#1352 and #1429 carries the
# LLM_MAX_CONCURRENT value without the triage crystallizer knobs — on such an
# install every LABELER_RULE_FIRST / ROUTER_RULE_CONFIDENCE / *_BM25_RECALL
# operator export is silently inert (getenv() reads the SANITIZED env, #1428).
# The migration appends the four pilot knobs + the three #1429 BM25 knobs.
T16_DIR="$FAKE_ROOT/t16"
mkdir -p "$T16_DIR"
T16_CONFIG="$T16_DIR/config"
printf '%s\n' "$EXPECTED_1354" > "$T16_CONFIG"

run_install_fragment "$T16_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T16_CONFIG" \
    && ! grep -qxF "$EXPECTED_1354" "$T16_CONFIG"; then
    pass "#1354/#1352-era literal migrates to add the rule + BM25 knobs (#1429/#1428)"
else
    fail "#1354/#1352->#1429 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1354', got:"
    cat "$T16_CONFIG"
fi

# ----- Test 17: #1429-era literal migrates to add the prioritizer knobs (#1430) -----
# A federation installed between #1429 and #1430 carries the triage
# labeler/router knob value without the prioritizer pilot knobs — on such an
# install every PRIORITIZER_RULE_FIRST / PRIORITIZER_RULE_CONFIDENCE /
# PRIORITIZER_BM25_RECALL operator export is silently inert (getenv() reads
# the SANITIZED env, #1428). The migration appends the three knobs.
T17_DIR="$FAKE_ROOT/t17"
mkdir -p "$T17_DIR"
T17_CONFIG="$T17_DIR/config"
printf '%s\n' "$EXPECTED_1429" > "$T17_CONFIG"

run_install_fragment "$T17_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T17_CONFIG" \
    && ! grep -qxF "$EXPECTED_1429" "$T17_CONFIG"; then
    pass "#1429-era literal migrates to add the prioritizer pilot knobs (#1430)"
else
    fail "#1429->#1430 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1429', got:"
    cat "$T17_CONFIG"
fi

# ----- Test 19: #1430-era literal migrates to add the #1428 audit knobs -----
# A federation installed between #1430 and #1428 carries the prioritizer
# knob value without QA_ADVERSARIAL_LLM_CMD / CODE_EDIT_MAX_ATTEMPTS — on
# such an install the qa_reviewer cross-provider reroute (#1405) and the
# code-edit attempt-cap override are silently inert (getenv() reads the
# SANITIZED env, #1428). The migration appends both knobs.
T19_DIR="$FAKE_ROOT/t19"
mkdir -p "$T19_DIR"
T19_CONFIG="$T19_DIR/config"
printf '%s\n' "$EXPECTED_1430" > "$T19_CONFIG"

run_install_fragment "$T19_CONFIG"

if grep -qxF "$EXPECTED_NEW" "$T19_CONFIG" \
    && ! grep -qxF "$EXPECTED_1430" "$T19_CONFIG"; then
    pass "#1430-era literal migrates to add QA_ADVERSARIAL_LLM_CMD + CODE_EDIT_MAX_ATTEMPTS (#1428)"
else
    fail "#1430->#1428 migration — expected '$EXPECTED_NEW' and no bare '$EXPECTED_1430', got:"
    cat "$T19_CONFIG"
fi

# ----- Test 18: #1437 residue check on a hand-customized allowlist -----
# A customized exec.env_passthrough matches no migration literal, so new
# knobs are never auto-added and stay silently inert (#1428 class). The
# residue check must WARN (naming the missing knobs) and must NOT modify
# the operator's value. Keep in sync with dev-apprenticeship/install.sh §4.
run_residue_check() {
    local AGENTIS_CONFIG="$1"
    RESIDUE_ALLOWLIST="$(grep '^exec\.env_passthrough[[:space:]]*=' "$AGENTIS_CONFIG" | head -1 | cut -d= -f2- | tr -d ' ')"
    MISSING_KNOBS=""
    for knob in IMPLEMENTATION_TRIGGER_LABEL PLANNING_TRIGGER_LABEL AUTO_MERGE \
                PLAN_AUTO_PROMOTE CODE_EDIT_MAX_CONCURRENT AG_DRIVEN_EDIT_LOOP \
                LLM_MAX_CONCURRENT LABELER_RULE_FIRST LABELER_RULE_CONFIDENCE \
                ROUTER_RULE_FIRST ROUTER_RULE_CONFIDENCE LABELER_BM25_RECALL \
                ROUTER_BM25_RECALL TRIAGE_BM25_K PRIORITIZER_RULE_FIRST \
                PRIORITIZER_RULE_CONFIDENCE PRIORITIZER_BM25_RECALL \
                QA_ADVERSARIAL_LLM_CMD CODE_EDIT_MAX_ATTEMPTS; do
        case ",$RESIDUE_ALLOWLIST," in
            *",$knob,"*) ;;
            *) MISSING_KNOBS="$MISSING_KNOBS $knob" ;;
        esac
    done
    if [ -n "$MISSING_KNOBS" ]; then
        printf '[!!] missing:%s\n' "$MISSING_KNOBS"
    fi
}

T18_DIR="$FAKE_ROOT/t18"
mkdir -p "$T18_DIR"
T18_CONFIG="$T18_DIR/config"
printf '%s\n' "$OPERATOR_TUNED" > "$T18_CONFIG"

T18_OUT="$(run_residue_check "$T18_CONFIG")"
if printf '%s' "$T18_OUT" | grep -q 'PRIORITIZER_RULE_FIRST' \
    && printf '%s' "$T18_OUT" | grep -q 'TRIAGE_BM25_K' \
    && printf '%s' "$T18_OUT" | grep -q 'QA_ADVERSARIAL_LLM_CMD' \
    && grep -qxF "$OPERATOR_TUNED" "$T18_CONFIG"; then
    pass "#1437 residue check warns on missing knobs and leaves the customized value untouched"
else
    fail "#1437 residue check — expected a warning naming missing knobs + untouched config, got: '$T18_OUT'"
    cat "$T18_CONFIG"
fi

T18_FULL_DIR="$FAKE_ROOT/t18full"
mkdir -p "$T18_FULL_DIR"
T18_FULL_CONFIG="$T18_FULL_DIR/config"
printf '%s\n' "$EXPECTED_NEW" > "$T18_FULL_CONFIG"
T18_FULL_OUT="$(run_residue_check "$T18_FULL_CONFIG")"
if [ -z "$T18_FULL_OUT" ]; then
    pass "#1437 residue check is silent on a complete allowlist"
else
    fail "#1437 residue check false positive on the complete default: '$T18_FULL_OUT'"
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
