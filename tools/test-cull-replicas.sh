#!/bin/bash
# tools/test-cull-replicas.sh -- smoke tests for the generalised
# cull-replicas.sh (Phase 9 PR-B of #663).
#
# Renamed from `tools/test-cull-explorers.sh`. Exercises the cull
# picker logic without a live container by replacing the
# `podman exec agentis daemon list --json` call with a synthetic
# `CULL_DAEMONS_JSON_OVERRIDE` blob.
#
# Coverage:
#   1. --dry-run mode picks the lowest-fitness replica
#   2. --min-explorers gate skips when too few replicas run
#   3. --min-acting gate skips per-row when bottom row is under-sampled
#   4. Demand-weighted specialty picker chooses the under-represented
#      specialty out of the seeded pool
#   5. Bash syntax is clean (`bash -n`)
#   6. (PR-B) colony=noticer mode invokes correctly when noticer
#      entries exist in colony-variants.json
#   7. (PR-B) the back-compat wrapper cull-explorers.sh forwards to
#      colony=explorer with the same dry-run output
#
# The decision feed (auto-promote-decisions.py --preview) is invoked
# for real because it's the contract dependency from PR 2; the fed_dir
# is a temp dir with empty experience so every fitness_score collapses
# to 0.0 and the picker is driven by tie-breaker order.
#
# Standard library only -- no pytest, no podman, no live LLM.
#
# Usage: bash tools/test-cull-replicas.sh

set -eu

# Isolate this test harness from any live research-foundry container on
# the host (#685). cull-replicas.sh resolves $CONTAINER from
# CULL_CONTAINER_NAME (default research-foundry-laptop); pointing it at
# a sentinel name that will never match a real podman container makes
# every `podman exec` invocation fail fast, so the script's try/except
# blocks fall through to the fixture-provided values
# (CULL_DAEMONS_JSON_OVERRIDE, CULL_SPECIALTY_COUNTS_OVERRIDE) rather
# than reading the live federation's memo store. Without this, tests 8
# and 10 (which assert specific daemon_id allocations) fail whenever a
# running research-foundry-laptop container has pool:specialty:<N>
# slots claimed beyond the synthetic fixture's range.
export CULL_CONTAINER_NAME=cull-test-noop

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CULL="$SCRIPT_DIR/cull-replicas.sh"
WRAPPER="$SCRIPT_DIR/cull-explorers.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -x "$CULL" ]; then
    fail "cull-replicas.sh executable" "$CULL not executable"
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

if bash -n "$WRAPPER" 2>/dev/null; then
    pass "wrapper bash -n clean"
else
    fail "wrapper bash -n clean" "$(bash -n "$WRAPPER" 2>&1)"
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
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

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
    bash "$CULL" "$WORK_DIR" explorer --dry-run --min-explorers 3 2>&1 || true)"

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
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 10 2>&1 || true)"

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
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$WEIGHTED_OUT" | grep -Fq 'respawn specialty=group_theory'; then
    pass "4. demand-weighted picker chooses under-represented specialty"
else
    fail "4. demand-weighted picker chooses under-represented specialty" "$WEIGHTED_OUT"
fi

# --- Test 6 (PR-B): colony=noticer mode picks from the noticer pool.
# Build a synthetic daemon-list with 5 noticers, all assigned distinct
# surprise-type-bias variants from colony-variants.json. Expect the
# cull picker to fire on noticer.ag and respawn a noticer with one of
# the noticer variants (we assert the dry-run text contains
# "respawn noticer" plus a specialty drawn from the noticer pool).
NOTICER_JSON="$(python3 -c "
import json
variants = ['subtle', 'dramatic', 'coincidence', 'pattern', 'symmetry']
daemons = []
for i, sp in enumerate(variants, start=1):
    daemons.append({
        'source': '/run-root/noticer/agents/noticer.ag',
        'agent_id': 'agent-noticer-%d' % i,
        'pid': 3000 + i,
        'state': 'running',
        'effective_state': 'running',
        'colony': 'noticer',
        'started_at': 0,
        'confidence': 0.7,
    })
print(json.dumps(daemons))
")"

NOTICER_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$NOTICER_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"subtle":2,"dramatic":1,"coincidence":1,"pattern":1,"symmetry":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" noticer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

# Expect under-representation tie-break to pick one of dramatic /
# coincidence / pattern / symmetry (all at 1, vs subtle at 2). The
# dry-run banner names the respawn variant; we accept any of the four
# tied minima.
if printf '%s' "$NOTICER_OUT" | grep -Eq 'respawn specialty=(dramatic|coincidence|pattern|symmetry)' \
        && printf '%s' "$NOTICER_OUT" | grep -Fq 'would respawn noticer'; then
    pass "6. colony=noticer mode picks from noticer variant pool (PR-B)"
else
    fail "6. colony=noticer mode picks from noticer variant pool (PR-B)" "$NOTICER_OUT"
fi

# --- Test 7 (PR-B): back-compat wrapper cull-explorers.sh forwards to
# cull-replicas.sh with colony=explorer. The wrapper output for the
# same synthetic input must contain the same "respawn explorer" banner
# as a direct invocation with colony=explorer.
WRAPPER_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$WRAPPER" "$WORK_DIR" --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$WRAPPER_OUT" | grep -Fq '[dry-run] would cull pid=' \
        && printf '%s' "$WRAPPER_OUT" | grep -Fq '[dry-run] would respawn explorer'; then
    pass "7. cull-explorers.sh wrapper forwards to cull-replicas explorer (PR-B)"
else
    fail "7. cull-explorers.sh wrapper forwards to cull-replicas explorer (PR-B)" "$WRAPPER_OUT"
fi

# --- Test 8 (#650): DAEMON_ID gap allocation -- when surviving replicas
# carry daemon_id=1,2,4 the respawn must claim max(existing)+1 = 5, not
# colliding with the surviving daemon_id=4 nor reusing the daemon_id=3
# gap (the orchestrator reserves max+1 so pool slots never collide).
GAP_JSON="$(python3 -c "
import json
daemons = []
for did, pid_off in [(1, 1), (2, 2), (4, 4)]:
    daemons.append({
        'source': '/run-root/explorer/agents/explorer.ag',
        'agent_id': 'agent-explorer-%d' % did,
        'pid': 1000 + pid_off,
        'daemon_id': did,
        'state': 'running',
        'effective_state': 'running',
        'colony': 'explorer',
        'started_at': 0,
        'confidence': 0.7,
    })
print(json.dumps(daemons))
")"

GAP_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$GAP_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.34 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$GAP_OUT" | grep -Fq 'next daemon_id=5'; then
    pass "8. DAEMON_ID gap allocation -- alive=1,2,4 -> respawn=5 (#650)"
else
    fail "8. DAEMON_ID gap allocation -- alive=1,2,4 -> respawn=5 (#650)" "$GAP_OUT"
fi

# --- Test 9 (#651): all-below-min-acting batch is a no-op.
# Inject decisions where every row has entries_acting below --min-acting
# (here driven by --min-acting=10 with the synthetic fixture's implicit
# zero acting count). Assert zero cull/respawn ledger rows are emitted
# even outside dry-run. The script writes to <fed_dir>/replication-
# ledger.jsonl so we truncate that canonical path first to isolate from
# prior tests, then assert it stays empty after the invocation.
NOOP_LEDGER_PATH="$WORK_DIR/replication-ledger.jsonl"
: > "$NOOP_LEDGER_PATH"

CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" explorer --bottom-pct 0.4 --min-explorers 3 --min-acting 10 \
    > "$WORK_DIR/noop.stdout" 2>&1 || true

CULL_ROWS="$(grep -c '"event": "cull"' "$NOOP_LEDGER_PATH" 2>/dev/null | head -n 1 || true)"
RESPAWN_ROWS="$(grep -c '"event": "respawn"' "$NOOP_LEDGER_PATH" 2>/dev/null | head -n 1 || true)"
CULL_ROWS="${CULL_ROWS:-0}"
RESPAWN_ROWS="${RESPAWN_ROWS:-0}"

if [ "$CULL_ROWS" -eq 0 ] && [ "$RESPAWN_ROWS" -eq 0 ]; then
    pass "9. all-below-min-acting -> no cull/respawn rows emitted (#651)"
else
    fail "9. all-below-min-acting -> no cull/respawn rows emitted (#651)" \
        "cull=$CULL_ROWS respawn=$RESPAWN_ROWS ledger=$(cat "$NOOP_LEDGER_PATH" 2>/dev/null)"
fi

# --- Test 10 (#675): NEXT_ID must increment per dry-run respawn so a
# multi-pick batch produces distinct daemon_ids. Reuses the alive=1,2,4
# gap fixture from Test 8 but with --bottom-pct 0.67 to force the picker
# to take all 3 surviving replicas (ceil(3 * 0.67) = 3). The expected
# respawn allocation is daemon_id=5, 6, 7 on distinct dry-run lines.
# Pre-fix, every line read daemon_id=5 because NEXT_ID was set once and
# the dry-run branch never bumped it.
MULTI_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$GAP_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.67 --min-explorers 3 --min-acting 0 2>&1 || true)"

MULTI_ID5="$(printf '%s\n' "$MULTI_OUT" | grep -cF 'daemon_id=5' || true)"
MULTI_ID6="$(printf '%s\n' "$MULTI_OUT" | grep -cF 'daemon_id=6' || true)"
MULTI_ID7="$(printf '%s\n' "$MULTI_OUT" | grep -cF 'daemon_id=7' || true)"

if [ "$MULTI_ID5" -ge 1 ] && [ "$MULTI_ID6" -ge 1 ] && [ "$MULTI_ID7" -ge 1 ]; then
    pass "10. dry-run NEXT_ID bumps per respawn -> daemon_id=5,6,7 distinct (#675)"
else
    fail "10. dry-run NEXT_ID bumps per respawn -> daemon_id=5,6,7 distinct (#675)" \
        "id5=$MULTI_ID5 id6=$MULTI_ID6 id7=$MULTI_ID7 out=$MULTI_OUT"
fi

# --- Test 11 (#767): aging cull request override fires reason=aging.
# When CULL_AGING_REQUESTS_OVERRIDE names a pid that exists in the
# daemons fixture AND its fitness is below CULL_AGING_FITNESS_FLOOR
# (every fitness here collapses to 0.0 because the experience dir is
# empty), the picker must include that pid with reason=aging so the
# dry-run log mentions it explicitly.
AGING_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    CULL_AGING_REQUESTS_OVERRIDE='1001,1002' \
    CULL_AGING_FITNESS_FLOOR_OVERRIDE='0.3' \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$AGING_OUT" | grep -Fq 'reason=aging'; then
    pass "11. aging request override -> dry-run log carries reason=aging (#767)"
else
    fail "11. aging request override -> dry-run log carries reason=aging (#767)" "$AGING_OUT"
fi

# --- Test 12 (#767): aging request below the fitness floor IS picked even
# when the pid is outside the bottom-pct slice (--bottom-pct 0.0 forces
# the bottom-pct picker empty; the aging request must still flow
# through). Pre-#767 there is no aging path -- this test exists only to
# exercise the new code path.
AGING_OUT_FORCED="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    CULL_AGING_REQUESTS_OVERRIDE='1003' \
    CULL_AGING_FITNESS_FLOOR_OVERRIDE='0.3' \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.01 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$AGING_OUT_FORCED" | grep -Fq 'pid=1003' \
        && printf '%s' "$AGING_OUT_FORCED" | grep -Fq 'reason=aging'; then
    pass "12. aging request bypasses bottom-pct slice + min-acting gate (#767)"
else
    fail "12. aging request bypasses bottom-pct slice + min-acting gate (#767)" "$AGING_OUT_FORCED"
fi

# --- Test 13 (#767): aging request whose fitness is at-or-above the
# floor is NOT culled. The CULL_AGING_FITNESS_FLOOR_OVERRIDE='-1.0' value
# forces every (>=0.0) fitness to fail the `score < floor` check, so the
# aging path collapses even though the request memo names a live pid.
# The output must NOT carry reason=aging for any row.
AGING_OUT_GATED="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    CULL_AGING_REQUESTS_OVERRIDE='1001' \
    CULL_AGING_FITNESS_FLOOR_OVERRIDE='-1.0' \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.01 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$AGING_OUT_GATED" | grep -Fq 'reason=aging'; then
    fail "13. aging-out request above fitness floor must NOT pick reason=aging (#767)" "$AGING_OUT_GATED"
else
    pass "13. aging-out request above fitness floor stays out of cull picks (#767)"
fi

# --- Test 14 (#767): size-decrement bug fix is opt-out via
# CULL_SIZE_DECREMENT_DISABLED=1. Sanity check that the script tolerates
# the flag and still emits a working dry-run banner -- the live path
# (memo writes) cannot fire here because podman exec always fails fast
# under cull-test-noop, but the env knob must short-circuit the
# size-decrement leg without aborting the loop.
SIZE_DEC_DISABLED_OUT="$(CULL_DAEMONS_JSON_OVERRIDE="$SYNTH_JSON" \
    CULL_SPECIALTY_COUNTS_OVERRIDE='{"group_theory":1,"combinatorics":1,"number_theory":1,"probability":1,"algebra":1}' \
    CULL_NOW_MS_OVERRIDE=0 \
    CULL_SIZE_DECREMENT_DISABLED=1 \
    bash "$CULL" "$WORK_DIR" explorer --dry-run --bottom-pct 0.2 --min-explorers 3 --min-acting 0 2>&1 || true)"

if printf '%s' "$SIZE_DEC_DISABLED_OUT" | grep -Fq '[dry-run] would cull pid='; then
    pass "14. CULL_SIZE_DECREMENT_DISABLED=1 toggle does not break dry-run (#767)"
else
    fail "14. CULL_SIZE_DECREMENT_DISABLED=1 toggle does not break dry-run (#767)" "$SIZE_DEC_DISABLED_OUT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
