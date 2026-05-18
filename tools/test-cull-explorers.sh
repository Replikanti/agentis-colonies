#!/bin/bash
# tools/test-cull-explorers.sh -- smoke tests for cull-explorers.sh.
#
# Phase 3 PR 3 of #624. Exercises the cull picker logic without a live
# container: synthetic CULL_DAEMONS_JSON_OVERRIDE replaces the
# `podman exec agentis daemon list --json` call so we can assert on
#
#   1. --dry-run mode picks the lowest-fitness explorer
#   2. --min-explorers gate skips the cull when too few explorers run
#   3. --min-acting gate skips per-row when bottom row is under-sampled
#   4. Demand-weighted specialty picker chooses the under-represented
#      specialty out of the seeded pool
#   5. Bash syntax is clean (`bash -n`).
#
# The decision feed (auto-promote-decisions.py --preview) is invoked
# for real because it's the contract dependency from PR 2; the fed_dir
# is a temp dir with empty experience so every fitness_score collapses
# to 0.0 and the picker is driven by tie-breaker order.
#
# Standard library only -- no pytest, no podman, no live LLM.
#
# Usage: bash tools/test-cull-explorers.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CULL="$SCRIPT_DIR/cull-explorers.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$CULL" ]; then
    fail "cull-explorers.sh executable" "$CULL not executable"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Test 5 first so a missing dep crashes early.
if bash -n "$CULL" 2>/dev/null; then
    pass "bash -n clean"
else
    fail "bash -n clean" "$(bash -n "$CULL" 2>&1)"
fi

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
mkdir -p "$WORK_DIR/.agentis/experience"
: > "$WORK_DIR/replication-ledger.jsonl"

# Build a synthetic daemon-list with 5 explorers + 1 auditor. Each
# explorer carries a distinct pid + agent_id; effective_state=running
# so the containerized-mode liveness probe in auto-promote-decisions.py
# treats them all as alive.
SYNTH_JSON="$(python3 -c "
import json
daemons = []
specialties = ['group_theory', 'combinatorics', 'number_theory', 'probability', 'algebra']
for i, sp in enumerate(specialties, start=1):
    daemons.append({
        'source': '/run-root/explorer/agents/explorer.ag',
        'agent_id': 'agent-explorer-%d' % i,
        'pid': 1000 + i,
        'state': 'running',
        'effective_state': 'running',
        'colony': 'explorer',
        'started_at': 0,
        'confidence': 0.7,
    })
daemons.append({
    'source': '/run-root/auditor/agents/auditor.ag',
    'agent_id': 'agent-auditor-1',
    'pid': 2000,
    'state': 'running',
    'effective_state': 'running',
    'colony': 'auditor',
    'started_at': 0,
    'confidence': 0.7,
})
print(json.dumps(daemons))
")"

# --- Test 1: --dry-run mode picks at least one cull candidate
DRY_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$DRY_OUT" | grep -Fq '[dry-run] would cull pid='; then
    pass "1. --dry-run emits cull intent"
else
    fail "1. --dry-run emits cull intent" "$DRY_OUT"
fi

if printf '%s' "$DRY_OUT" | grep -Fq '[dry-run] would respawn explorer'; then
    pass "1b. --dry-run emits respawn intent"
else
    fail "1b. --dry-run emits respawn intent" "$DRY_OUT"
fi

# Ensure NO ledger writes happened in dry-run mode (the file must
# stay empty, the trap leaves it readable for inspection).
if [ ! -s "$WORK_DIR/replication-ledger.jsonl" ]; then
    pass "1c. --dry-run does not write to replication-ledger.jsonl"
else
    fail "1c. --dry-run does not write to replication-ledger.jsonl" \
        "$(cat "$WORK_DIR/replication-ledger.jsonl")"
fi

# --- Test 2: --min-explorers gate skips when count too low
LOW_JSON="$(python3 -c "
import json
daemons = []
for i in range(2):
    daemons.append({
        'source': '/run-root/explorer/agents/explorer.ag',
        'agent_id': 'agent-explorer-%d' % i,
        'pid': 1000 + i,
        'state': 'running',
        'effective_state': 'running',
        'colony': 'explorer',
        'started_at': 0,
        'confidence': 0.7,
    })
print(json.dumps(daemons))
")"

LOW_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$LOW_JSON" \
    bash "$CULL" "$WORK_DIR" --dry-run --min-explorers 3 2>&1 || true)"

if printf '%s' "$LOW_OUT" | grep -Fq 'skip: explorer_count=2 < min_explorers=3'; then
    pass "2. --min-explorers gate skips below floor"
else
    fail "2. --min-explorers gate skips below floor" "$LOW_OUT"
fi

# --- Test 3: --min-acting gate skips per-row when under-sampled
# With min-acting=10 and zero acting rows in the fixture, the per-row
# skip message must surface.
ACTING_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 10 2>&1 || true)"

if printf '%s' "$ACTING_OUT" | grep -Eq 'skip pid=[0-9]+: entries_acting=[0-9]+ < 10'; then
    pass "3. --min-acting gate skips under-sampled row"
else
    fail "3. --min-acting gate skips under-sampled row" "$ACTING_OUT"
fi

# --- Test 4: demand-weighted specialty picker (under-representation)
# Counts: group_theory has 0 (gone), others have >=1. Expectation: pick
# group_theory as the respawn specialty even with tie-breaker offset 0.
WEIGHTED_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"combinatorics":2,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$WEIGHTED_OUT" | grep -Fq 'respawn specialty=group_theory'; then
    pass "4. demand-weighted picker chooses under-represented specialty"
else
    fail "4. demand-weighted picker chooses under-represented specialty" "$WEIGHTED_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
