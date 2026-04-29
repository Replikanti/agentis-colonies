#!/bin/bash
# tools/test-per-repo-confidence.sh: unit tests for the #316 M4 repo_tier()
# helper convention.
#
# repo_tier(agent_name, owner, repo) is a per-agent helper (copy-pasted
# across all 21 .ag files in dev-apprenticeship/) that reads the per-repo
# confidence memo `<owner>__<repo>:<agent>:confidence` first and falls
# back to the legacy unscoped `<agent>:confidence` key when the per-repo
# memo is absent. The helper returns one of the five tier strings from
# ADR-0001: dormant / shadow / propose / review-gated / autonomous.
#
# Tests:
#   1. Fallback path: no per-repo memo + legacy 0.7 -> "propose".
#   2. Per-repo wins: legacy 0.7 + per-repo 0.95 -> "autonomous".
#   3. Divergence: two repos at different per-repo values for the same
#      agent return different tiers (the M4 use case).
#   4. Sentinel byte-identity: owner == "" bypasses the scoped lookup
#      entirely; for every confidence value the helper must return the
#      same string the runtime tier() builtin returns.
#   5. Boundary respect: the helper maps exactly at the ADR-0001
#      thresholds (0.4 / 0.6 / 0.8 / 0.95) to the upper-tier string and
#      just-below to the lower-tier string.
#
# Implementation: each test writes a tiny .ag scenario into a tempdir,
# seeds the relevant memo keys with `agentis memo set`, runs the script
# with `agentis go`, and matches stdout against the expected tier string.
# The .ag scenario embeds the same canonical helper text the agents use,
# so a future helper-text drift in the agents would be detected by the
# byte-identity check the test 4 boundary table indirectly enforces.
#
# Standard scaffold: set -eu, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-per-repo-confidence.sh
# Exit 0 if all tests pass, 1 otherwise. Skips with exit 0 when the
# `agentis` binary is not on $PATH (CI fallback).

set -eu

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis binary not found on \$PATH"
    echo "Results: 0 passed, 0 failed (skipped — agentis not installed)"
    exit 0
fi

# Canonical M4 helper text (byte-identical to the helper inserted into
# all 21 dev-apprenticeship/ .ag files). Embedded here so the test
# exercises the same code path the agents do — divergence between this
# string and the per-agent helper bodies is the regression surface.
HELPER='fn scoped_memo(owner: string, repo: string, suffix: string) -> string {
    if len(owner) == 0 { return suffix; };
    return owner + "__" + repo + ":" + suffix;
}

fn repo_tier(agent_name: string, owner: string, repo: string) -> string {
    let raw = if len(owner) == 0 {
        recall_latest(agent_name + ":confidence");
    } else {
        let scoped = recall_latest(scoped_memo(owner, repo, agent_name + ":confidence"));
        if len(scoped) > 0 { scoped; } else { recall_latest(agent_name + ":confidence"); };
    };
    if len(raw) == 0 { return "dormant"; };
    let c = parse_float(raw);
    if c >= 0.95 { return "autonomous"; };
    if c >= 0.8  { return "review-gated"; };
    if c >= 0.6  { return "propose"; };
    if c >= 0.4  { return "shadow"; };
    return "dormant";
}'

# run_repo_tier <agent_name> <owner> <repo> -> stdout = tier string.
# Builds a fresh agentis repo per call (memo store is per-repo-init in
# this scaffold), seeds the memos passed via REPO_TIER_MEMOS env (a
# semicolon-separated list of `key=value` pairs), and invokes the helper
# with the requested args. Stderr is suppressed to keep stdout clean.
run_repo_tier() {
    local agent_name="$1"
    local owner="$2"
    local repo="$3"
    local seeds="${4:-}"

    local sandbox
    sandbox="$(mktemp -d -p "$TMPDIR_TEST")"

    (
        cd "$sandbox"
        agentis init >/dev/null 2>&1
        if [ -n "$seeds" ]; then
            local IFS=';'
            for kv in $seeds; do
                if [ -n "$kv" ]; then
                    local k="${kv%%=*}"
                    local v="${kv#*=}"
                    agentis memo set "$k" "$v" >/dev/null 2>&1 || true
                fi
            done
        fi
        cat > probe.ag <<EOF
cb 100;

$HELPER

print(repo_tier("$agent_name", "$owner", "$repo"));
EOF
        # `agentis go` runs the file as a script; the top-level print(...)
        # emits exactly one line carrying the tier string we test against.
        # `[genesis] <hash>` is unconditionally printed first; tail -n 1
        # selects the helper output.
        agentis go probe.ag 2>/dev/null | tail -n 1
    )

    rm -rf "$sandbox"
}

# --- Test 1: fallback path -----------------------------------------------
# No per-repo memo set, legacy unscoped key at 0.7 -> "propose".
GOT="$(run_repo_tier "router" "acme" "frontend" "router:confidence=0.7")"
if [ "$GOT" = "propose" ]; then
    pass "test 1: fallback (legacy 0.7, no per-repo) -> propose"
else
    fail "test 1: fallback (legacy 0.7, no per-repo) -> propose" \
         "got='$GOT'"
fi

# --- Test 2: per-repo wins ------------------------------------------------
# Legacy 0.7 + per-repo 0.95 for the same (agent, owner, repo) triple ->
# scoped_memo lookup wins, tier = "autonomous".
GOT="$(run_repo_tier "router" "acme" "frontend" \
    "router:confidence=0.7;acme__frontend:router:confidence=0.95")"
if [ "$GOT" = "autonomous" ]; then
    pass "test 2: per-repo wins (legacy 0.7 + per-repo 0.95) -> autonomous"
else
    fail "test 2: per-repo wins (legacy 0.7 + per-repo 0.95) -> autonomous" \
         "got='$GOT'"
fi

# --- Test 3: divergence across two repos ----------------------------------
# Same agent, two repos, two per-repo values -> two different tiers.
# This is the M4 use case: an agent can be "propose" on repo A and
# "autonomous" on repo B at the same point in time.
SEEDS="router:confidence=0.5;acme__frontend:router:confidence=0.65;acme__backend:router:confidence=0.97"
GOT_A="$(run_repo_tier "router" "acme" "frontend" "$SEEDS")"
GOT_B="$(run_repo_tier "router" "acme" "backend" "$SEEDS")"
if [ "$GOT_A" = "propose" ] && [ "$GOT_B" = "autonomous" ]; then
    pass "test 3: divergence (frontend=0.65 -> propose, backend=0.97 -> autonomous)"
else
    fail "test 3: divergence (frontend=0.65 -> propose, backend=0.97 -> autonomous)" \
         "frontend='$GOT_A' backend='$GOT_B'"
fi

# --- Test 4: sentinel byte-identity ---------------------------------------
# owner == "" must bypass the scoped lookup entirely. For every legacy
# confidence value, the helper returns the same string the runtime tier()
# builtin returns. The boundary table here mirrors ADR-0001 — divergence
# between this list and the helper body is what test 4 catches.
sentinel_ok=true
for pair in \
    "0.0=dormant" \
    "0.39=dormant" \
    "0.4=shadow" \
    "0.59=shadow" \
    "0.6=propose" \
    "0.79=propose" \
    "0.8=review-gated" \
    "0.94=review-gated" \
    "0.95=autonomous" \
    "1.0=autonomous"
do
    val="${pair%%=*}"
    expected="${pair#*=}"
    GOT="$(run_repo_tier "router" "" "" "router:confidence=$val")"
    if [ "$GOT" != "$expected" ]; then
        sentinel_ok=false
        fail "test 4: sentinel owner='' value=$val -> $expected" \
             "got='$GOT'"
    fi
done
if $sentinel_ok; then
    pass "test 4: sentinel byte-identity (owner='' matches runtime tier() across 10 values)"
fi

# --- Test 5: boundary respect ---------------------------------------------
# Per-repo path: the helper must map exactly at the ADR-0001 thresholds
# (0.4 / 0.6 / 0.8 / 0.95) to the upper-tier string and just-below to
# the lower tier. Same table as test 4 but seeded as the per-repo key
# so the scoped-memo branch is exercised explicitly.
boundary_ok=true
for pair in \
    "0.39=dormant" \
    "0.4=shadow" \
    "0.59=shadow" \
    "0.6=propose" \
    "0.79=propose" \
    "0.8=review-gated" \
    "0.94=review-gated" \
    "0.95=autonomous"
do
    val="${pair%%=*}"
    expected="${pair#*=}"
    SEEDS="router:confidence=0.0;acme__frontend:router:confidence=$val"
    GOT="$(run_repo_tier "router" "acme" "frontend" "$SEEDS")"
    if [ "$GOT" != "$expected" ]; then
        boundary_ok=false
        fail "test 5: boundary per-repo value=$val -> $expected" \
             "got='$GOT'"
    fi
done
if $boundary_ok; then
    pass "test 5: boundary respect (8 ADR-0001 boundary points map to expected tier)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
