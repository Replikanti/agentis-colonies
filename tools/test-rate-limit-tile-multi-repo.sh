#!/usr/bin/env bash
# tools/test-rate-limit-tile-multi-repo.sh: end-to-end test for the
# #316 M5a per-repo Forge Rate Limits fan-out in
# federation-dashboard-collector.py.
#
# The collector now pre-computes a `repos_for_colony` map by execing
# `<colony>/scripts/start-colony.sh --print-repos-json` per colony.
# When N>=2, the rate-limit fetch fans out across each repo via
# `start-colony.sh --rate-limit-status --repo owner/repo` and the
# emitted shape becomes:
#     forge_rate_limits[colony] = {
#         repos:    [{owner, repo, remaining, limit, reset_at}, ...],
#         aggregate: {remaining, limit, reset_at},
#     }
# Single-block / N=1 / GitLab colonies preserve the v0.7.0 scalar
# shape byte-identically — the load-bearing back-compat invariant.
#
# Cases:
#   1. Single-block legacy shape: collector emits scalar
#      `{remaining, limit, reset_at}` (no `repos[]`, no `aggregate`).
#   2. N=2 multi-block: collector emits `repos[]` with one record per
#      repo and the aggregate footer.
#   3. Aggregate sums per-repo `remaining` and `limit` and picks the
#      earliest `reset_at`.
#
# Standard scaffold: set -u, mktemp -d isolation, EXIT trap for cleanup.
# Auto-discovered by tools/colony-lint.sh's tools-test loop.
#
# Usage: ./tools/test-rate-limit-tile-multi-repo.sh
# Exit 0 if all tests pass, 1 otherwise.

set -u

REPO_ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Run the collector against a fixture federation. $1 = fed_dir,
# $2 = colony list JSON, output captured into $3 (path).
run_collector() {
    local fed_dir="$1" colony_json="$2" out_path="$3"
    python3 "$COLLECTOR" \
        '[]' \
        '[]' \
        "$fed_dir" \
        "$(date '+%s')" \
        "$fed_dir/.agentis/experience" \
        "$fed_dir/.agentis/logs" \
        "$TMPDIR_TEST/dash" \
        "$colony_json" \
        "" \
        > "$out_path" 2>"$TMPDIR_TEST/collector.err"
}

# Build a minimal fixture colony with custom start-colony.sh stub.
# $1 = fed_dir, $2 = colony name, $3 = start-colony.sh content.
build_colony() {
    local fed="$1" colony="$2" script_body="$3"
    mkdir -p "$fed/$colony/scripts" "$fed/$colony/agents" \
             "$fed/$colony/config" \
             "$fed/.agentis/logs" "$fed/.agentis/experience"
    printf '%s\n' "$script_body" > "$fed/$colony/scripts/start-colony.sh"
    chmod +x "$fed/$colony/scripts/start-colony.sh"
}

# --- Test 1: single-block legacy shape (byte-identity gate) ----------
# A start-colony.sh stub that prints empty for --print-repos-json
# (legacy single-block) and the scalar `{remaining, limit, reset_at}`
# JSON for --rate-limit-status. The collector must emit the scalar
# shape — no `repos[]`, no `aggregate`, just remaining/limit/reset_at.
FED1="$TMPDIR_TEST/fed1"
COLONY1="solo"
# shellcheck disable=SC2016  # script body is bash literal; do not expand here
SCRIPT1='#!/bin/bash
if [ "$1" = "--print-repos-json" ]; then exit 0; fi
if [ "$1" = "--rate-limit-status" ]; then
    echo "{\"remaining\": 4321, \"limit\": 5000, \"reset_at\": \"2026-04-29T12:00:00Z\"}"
    exit 0
fi
exit 0'
build_colony "$FED1" "$COLONY1" "$SCRIPT1"
OUT1="$TMPDIR_TEST/out1.json"
run_collector "$FED1" "[\"$COLONY1\"]" "$OUT1"

if python3 -c "
import json, sys
with open('$OUT1') as f:
    d = json.load(f)
rl = d.get('forge_rate_limits') or {}
c = rl.get('$COLONY1') or {}
assert c.get('remaining') == 4321, c
assert c.get('limit') == 5000, c
assert c.get('reset_at') == '2026-04-29T12:00:00Z', c
assert 'repos' not in c, 'single-block must NOT emit repos[] (byte-identity)'
assert 'aggregate' not in c, 'single-block must NOT emit aggregate (byte-identity)'
" 2>"$TMPDIR_TEST/assert1.err"; then
    pass "test 1: single-block legacy scalar shape preserved (byte-identity)"
else
    fail "test 1: single-block scalar shape regressed" "$(cat "$TMPDIR_TEST/assert1.err")"
fi

# --- Test 2: N=2 multi-block emits repos[] with per-repo records -----
# A start-colony.sh stub that prints a 2-entry JSON array for
# --print-repos-json and per-repo rate-limit JSON for
# --rate-limit-status --repo owner/repo. Different remaining/limit per
# repo so we can prove the records are not aliased.
FED2="$TMPDIR_TEST/fed2"
COLONY2="multi"
# shellcheck disable=SC2016  # script body is bash literal; do not expand here
SCRIPT2='#!/bin/bash
if [ "$1" = "--print-repos-json" ]; then
    echo "[{\"owner\":\"acme\",\"repo\":\"frontend\",\"token\":\"x\",\"url\":\"https://api.github.com\"},{\"owner\":\"acme\",\"repo\":\"backend\",\"token\":\"y\",\"url\":\"https://api.github.com\"}]"
    exit 0
fi
if [ "$1" = "--rate-limit-status" ]; then
    if [ "$2" = "--repo" ] && [ "$3" = "acme/frontend" ]; then
        echo "{\"remaining\": 1000, \"limit\": 5000, \"reset_at\": \"2026-04-29T13:00:00Z\"}"
        exit 0
    fi
    if [ "$2" = "--repo" ] && [ "$3" = "acme/backend" ]; then
        echo "{\"remaining\": 2500, \"limit\": 5000, \"reset_at\": \"2026-04-29T12:30:00Z\"}"
        exit 0
    fi
    # Fallback aggregate (would be wrong shape if hit; tests guard).
    echo "{\"remaining\": 99999, \"limit\": 99999, \"reset_at\": \"2026-04-29T11:00:00Z\"}"
    exit 0
fi
exit 0'
build_colony "$FED2" "$COLONY2" "$SCRIPT2"
OUT2="$TMPDIR_TEST/out2.json"
run_collector "$FED2" "[\"$COLONY2\"]" "$OUT2"

if python3 -c "
import json, sys
with open('$OUT2') as f:
    d = json.load(f)
rl = d.get('forge_rate_limits') or {}
c = rl.get('$COLONY2') or {}
assert isinstance(c.get('repos'), list), 'multi-block must emit repos[] as list, got ' + repr(c)
assert len(c['repos']) == 2, 'expected 2 per-repo records, got ' + str(len(c['repos']))
front = next(r for r in c['repos'] if r['repo'] == 'frontend')
back  = next(r for r in c['repos'] if r['repo'] == 'backend')
assert front['owner'] == 'acme'
assert front['remaining'] == 1000
assert front['limit'] == 5000
assert back['remaining'] == 2500
assert back['limit'] == 5000
assert isinstance(c.get('aggregate'), dict), 'multi-block must emit aggregate dict'
" 2>"$TMPDIR_TEST/assert2.err"; then
    pass "test 2: multi-block (N=2) emits repos[] with per-repo records"
else
    fail "test 2: multi-block fan-out regressed" "$(cat "$TMPDIR_TEST/assert2.err")"
fi

# --- Test 3: aggregate sums remaining + limit and picks earliest reset
# Same fed2 fixture: 1000 + 2500 = 3500 remaining, 5000 + 5000 = 10000
# limit, earliest reset_at is "2026-04-29T12:30:00Z" (backend).
if python3 -c "
import json, sys
with open('$OUT2') as f:
    d = json.load(f)
agg = (d.get('forge_rate_limits') or {}).get('$COLONY2', {}).get('aggregate') or {}
assert agg.get('remaining') == 3500, 'expected 3500, got ' + repr(agg.get('remaining'))
assert agg.get('limit') == 10000, 'expected 10000, got ' + repr(agg.get('limit'))
assert agg.get('reset_at') == '2026-04-29T12:30:00Z', 'expected earliest reset, got ' + repr(agg.get('reset_at'))
" 2>"$TMPDIR_TEST/assert3.err"; then
    pass "test 3: aggregate sums remaining/limit and picks earliest reset_at"
else
    fail "test 3: aggregate math wrong" "$(cat "$TMPDIR_TEST/assert3.err")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
