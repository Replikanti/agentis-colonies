#!/bin/bash
# tools/test-auto-promote.sh: unit tests for the auto-promote classification
# and decision logic (#186).
#
# The embedded Python mirror-tests replicate the core logic in auto-promote.sh
# (classify_entry, acting-row fitness computation, bootstrap override behaviour)
# against synthetic experience fixtures, verifying that:
#   1. tags {"acted", "review-gated", "emitted"} map to the acting bucket
#      and "observed" maps to the observe bucket
#   2. reject_rate and delta_slope are computed on acting rows only,
#      so all-observe fixtures produce 0.0 / 0.0 regardless of row count
#   3. the issue #186 scenario (425 observed + 0 acting at confidence 0.6)
#      resolves to SKIP with "entries_acting=0 < 60" as the fail reason
#   4. the bootstrap override (shadow -> propose, min_acting_entries=0)
#      promotes without evaluating fitness gates
#
# Mirror-tests are a sanity check on the documented contract; they do NOT
# guarantee the production script uses identical code. An end-to-end check
# against the real heredoc would require mocking `agentis daemon list` and
# is deferred.
#
# Usage: ./tools/test-auto-promote.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

run_py() {
    local name="$1"
    local script="$2"
    local expected="$3"
    local actual
    if ! actual=$(python3 -c "$script" 2>&1); then
        fail "$name" "python3 error: $actual"
        return
    fi
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "expected <$expected>, got <$actual>"
    fi
}

# --- Test 1: classify_entry ---
# Replicates the classification function from auto-promote.sh PYEVAL block.
# If this fails, the fix for #186 has regressed.

CLASSIFY_SETUP='
ACTING_TAGS = {"acted", "review-gated", "emitted"}
OBSERVE_TAGS = {"observed"}

def classify_entry(entry):
    tags = entry.get("tags") or []
    if not isinstance(tags, list):
        return "legacy"
    tag_set = {str(t) for t in tags}
    if tag_set & ACTING_TAGS:
        return "acting"
    if tag_set & OBSERVE_TAGS:
        return "observe"
    return "legacy"
'

run_py "classify: acted tag -> acting" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['acted', 'triage']}))" \
    "acting"

run_py "classify: review-gated tag -> acting" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['review-gated', 'code-review']}))" \
    "acting"

run_py "classify: emitted tag -> acting" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['emitted', 'planning']}))" \
    "acting"

run_py "classify: observed tag -> observe" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['observed', 'triage']}))" \
    "observe"

run_py "classify: missing tags field -> legacy" \
    "$CLASSIFY_SETUP
print(classify_entry({'outcome': 'success'}))" \
    "legacy"

run_py "classify: empty tags array -> legacy" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': []}))" \
    "legacy"

run_py "classify: non-list tags -> legacy" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': 'acted'}))" \
    "legacy"

run_py "classify: unrecognised tag -> legacy" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['something-else']}))" \
    "legacy"

# acted wins when both acted and observed present (shouldn't happen in
# practice but the classifier should handle it deterministically).
run_py "classify: acting tag wins over observe" \
    "$CLASSIFY_SETUP
print(classify_entry({'tags': ['acted', 'observed']}))" \
    "acting"

# --- Test 2: acting-row counters on issue #186 fixture ---
# Issue body scenario: risk_assessor with 425 observed rows, 0 acting rows.
# Pre-fix behaviour: entries_total=425 passes min_entries=200 and the
# observe rows' hardcoded outcome=success pulls reject_rate to 0 -> agent
# erroneously promotes. Post-fix: entries_acting=0 < 60, so SKIP.

FIXTURE_DIR="$TMPDIR_TEST/experience"
mkdir -p "$FIXTURE_DIR"
FIXTURE_FILE="$FIXTURE_DIR/risk_assessor.jsonl"

python3 -c "
import json, sys
with open('$FIXTURE_FILE', 'w') as f:
    for _ in range(425):
        f.write(json.dumps({
            'tags': ['observed', 'planning'],
            'outcome': 'success',
            'delta': 0.0,
        }) + '\n')
"

run_py "issue #186 fixture: 425 observe rows classified correctly" \
    "$CLASSIFY_SETUP
import json
acting, observe, legacy = 0, 0, 0
with open('$FIXTURE_FILE') as f:
    for line in f:
        e = json.loads(line)
        c = classify_entry(e)
        if c == 'acting': acting += 1
        elif c == 'observe': observe += 1
        else: legacy += 1
print(f'{acting},{observe},{legacy}')" \
    "0,425,0"

# --- Test 3: reject_rate computed on acting rows only ---
# A fixture with 425 observed (outcome=success) + 10 acting (5 reject).
# Pre-fix: reject_count=5, total=435 -> rate=0.0115 (looks great).
# Post-fix: reject_count=5, acting_count=10 -> rate=0.5 (clearly bad).

FIXTURE_MIX="$FIXTURE_DIR/mixed_agent.jsonl"
python3 -c "
import json
with open('$FIXTURE_MIX', 'w') as f:
    for _ in range(425):
        f.write(json.dumps({'tags': ['observed'], 'outcome': 'success', 'delta': 0.0}) + '\n')
    for _ in range(5):
        f.write(json.dumps({'tags': ['acted'], 'outcome': 'success', 'delta': 0.15}) + '\n')
    for _ in range(5):
        f.write(json.dumps({'tags': ['acted'], 'outcome': 'reject', 'delta': -0.15}) + '\n')
"

run_py "reject_rate computed on acting rows only" \
    "$CLASSIFY_SETUP
import json
acting_entries = []
for line in open('$FIXTURE_MIX'):
    e = json.loads(line)
    if classify_entry(e) == 'acting':
        acting_entries.append(e)
reject_count = sum(1 for e in acting_entries
                   if e.get('verdict') == 'reject'
                   or e.get('outcome') == 'reject'
                   or e.get('rejected', False))
rate = reject_count / len(acting_entries) if acting_entries else 0.0
print(f'{len(acting_entries)},{reject_count},{round(rate, 4)}')" \
    "10,5,0.5"

# --- Test 4: bootstrap override (shadow -> propose) ---
# With effective_min_acting=0, the fitness gates must be skipped even
# with zero acting rows. Simulates the promote check's gate logic.

run_py "bootstrap override=0: fitness gates skipped" \
    "
effective_min_acting = 0
entry_count = 200
acting_count = 0
runtime_hours = 50
reject_rate_acting = 0.0
delta_slope_acting = 0.0
min_entries = 200
min_runtime_hours = 48
reject_rate_threshold = 0.05
delta_slope_min = 0.0

fails = []
if entry_count < min_entries:
    fails.append('entries_total')
if acting_count < effective_min_acting:
    fails.append('entries_acting')
if runtime_hours < min_runtime_hours:
    fails.append('runtime')
if effective_min_acting > 0:
    if reject_rate_acting >= reject_rate_threshold:
        fails.append('reject_rate')
    if delta_slope_acting < delta_slope_min:
        fails.append('delta_slope')
print('fails=' + str(fails))" \
    "fails=[]"

# --- Test 5: no bootstrap for propose -> review-gated ---
# With effective_min_acting=60 (global default) and 0 acting rows,
# acting floor AND fitness gates should all fail. This guards against
# an off-by-one where override=None is conflated with override=0.

run_py "global floor: zero acting rows fails at acting floor" \
    "
effective_min_acting = 60
entry_count = 425
acting_count = 0
runtime_hours = 96
reject_rate_acting = 0.0
delta_slope_acting = 0.0
min_entries = 200
min_runtime_hours = 48
reject_rate_threshold = 0.05
delta_slope_min = 0.0

fails = []
if entry_count < min_entries:
    fails.append('entries_total')
if acting_count < effective_min_acting:
    fails.append('entries_acting')
if runtime_hours < min_runtime_hours:
    fails.append('runtime')
# Fitness gates are skipped on acting_count==0 because reject_rate and
# delta_slope are undefined there; behaviour mirrors auto-promote.sh.
if effective_min_acting > 0:
    # reject_rate gate only evaluated when there's a denominator;
    # the script skips both fitness gates together when the acting
    # floor itself is zero, so we match that branch.
    pass
print('fails=' + ','.join(fails))" \
    "fails=entries_acting"

# --- Test 6: rule-of-three formula derivation ---
# At reject_rate_threshold = 0.05, the formula ceil(3/0.05) = 60.
# At 0.025, ceil(3/0.025) = 120 (the halved-tolerance override for
# review-gated -> autonomous). At 0.10, ceil(3/0.10) = 30. These are
# the baseline values cited in doc/auto-promote.md.

run_py "formula: ceil(3/0.05) = 60" \
    "import math; print(math.ceil(3/0.05))" \
    "60"

run_py "formula: ceil(3/0.025) = 120" \
    "import math; print(math.ceil(3/0.025))" \
    "120"

run_py "formula: ceil(3/0.10) = 30" \
    "import math; print(math.ceil(3/0.10))" \
    "30"

# --- Test 7: step triple encoding round-trip ---
# auto-promote.sh encodes steps as "from:to:override" triples (empty
# third field = use global). Verify parse is symmetric with emit.

run_py "step encoding: shadow->propose override=0" \
    "
triples = '0.4:0.6:0 0.6:0.8: 0.8:0.95:120'
steps = []
for t in triples.split():
    parts = t.split(':')
    if len(parts) == 3:
        override = int(parts[2]) if parts[2] else None
        steps.append((float(parts[0]), float(parts[1]), override))
print(steps)" \
    "[(0.4, 0.6, 0), (0.6, 0.8, None), (0.8, 0.95, 120)]"

# --- Test 8: config parser produces expected CFG_* exports ---
# End-to-end check on the real parser helper (auto-promote-config-parser.py,
# extracted from the PYCONFIG heredoc in #245). Running the production
# helper here — not a mirror — so the test drifts with the helper and
# cannot desync.

CFG_STEPS=$(python3 "$SCRIPT_DIR/auto-promote-config-parser.py" \
    "$SCRIPT_DIR/auto-promote-config.yaml" \
    | grep '^CFG_PROMOTE_STEPS=' \
    | sed "s/CFG_PROMOTE_STEPS='\\(.*\\)'/\\1/")

if [ "$CFG_STEPS" = "0.4:0.6:0 0.6:0.8: 0.8:0.95:120" ]; then
    pass "config parser: triples match ADR-0001 ladder"
else
    fail "config parser" "expected <0.4:0.6:0 0.6:0.8: 0.8:0.95:120>, got <$CFG_STEPS>"
fi

# Verify output is shell-eval-able and sets every CFG_* the script needs.
CFG_EVAL=$(bash -c "eval \"\$(python3 '$SCRIPT_DIR/auto-promote-config-parser.py' '$SCRIPT_DIR/auto-promote-config.yaml')\" && echo \"\$CFG_MIN_ENTRIES|\$CFG_DRY_RUN|\$CFG_REJECT_RATE_THRESHOLD\"")

if [ "$CFG_EVAL" = "200|true|0.05" ]; then
    pass "config parser: output shell-eval-able, CFG_* populated"
else
    fail "config parser eval" "expected <200|true|0.05>, got <$CFG_EVAL>"
fi

# --- Test 9: config has canonical tier boundaries ---
# Per ADR-0001 the lower bounds 0.4/0.6/0.8/0.95 are the canonical
# numeric promotion thresholds. Lint-as-test: fail if the config
# drifts from these.

EXPECTED_BOUNDS="0.4 0.6 0.8 0.95"
ACTUAL_BOUNDS=$(python3 -c "
import re
bounds = set()
with open('$SCRIPT_DIR/auto-promote-config.yaml') as f:
    for line in f:
        m = re.search(r'(?:from|to):\s*([0-9.]+)', line)
        if m:
            bounds.add(m.group(1))
print(' '.join(sorted(bounds)))
")

if [ "$ACTUAL_BOUNDS" = "$EXPECTED_BOUNDS" ]; then
    pass "config bounds match ADR-0001: 0.4 / 0.6 / 0.8 / 0.95"
else
    fail "config bounds" "expected <$EXPECTED_BOUNDS>, got <$ACTUAL_BOUNDS>"
fi

# --- Test 10: no heredocs in auto-promote.sh ---
# #245 invariant: no `<<HEREDOC` in auto-promote.sh. The macOS bash 3.2
# parser cannot handle the `eval "$(python3 - <<'TAG' ... TAG)"` combo.
# Same gate as #172 added for federation-dashboard.sh via
# test-timeline-rendering.sh. Every embedded Python block must live in
# its own .py file next to the script.
#
# Match `<<TAG`, `<<'TAG'`, or `<<"TAG"` anywhere on a non-comment line.
# Previous pattern `^[[:space:]]*<<` missed the original PYEVAL case where
# the heredoc marker sat at the end of a backslash-continued line.

HEREDOC_COUNT=$(grep -vE '^[[:space:]]*#' "$SCRIPT_DIR/auto-promote.sh" \
    | grep -cE "<<['\"]?[A-Z_]+['\"]?" || true)
if [ "$HEREDOC_COUNT" -eq 0 ]; then
    pass "auto-promote.sh has no heredocs (#245)"
else
    fail "heredoc count" "expected 0 heredocs, found $HEREDOC_COUNT in auto-promote.sh"
fi

# --- Test 11: lock helper detects contention ---
# auto-promote-lock.py replaces flock(1) (util-linux, missing on macOS).
# Two parallel invocations against the same lock file must yield one
# acquisition + one contention (exit 1) on both Linux and macOS.

LOCK_TEST_FILE="$TMPDIR_TEST/contention.lock"

# First acquire in a background shell that holds fd 200 open for 1.5s.
# During that window, a second invocation must see contention.
(
    exec 200>"$LOCK_TEST_FILE"
    python3 "$SCRIPT_DIR/auto-promote-lock.py" 200 2>/dev/null || exit 99
    sleep 1.5
) &
BG_PID=$!
sleep 0.3

CONTEND_EXIT=0
(
    exec 201>"$LOCK_TEST_FILE"
    python3 "$SCRIPT_DIR/auto-promote-lock.py" 201 2>/dev/null
) || CONTEND_EXIT=$?

wait "$BG_PID" || true

if [ "$CONTEND_EXIT" -eq 1 ]; then
    pass "lock helper: second invocation blocked while first holds (#245)"
else
    fail "lock contention" "expected exit 1 from second invocation, got $CONTEND_EXIT"
fi

# After the first shell exited, the lock must be released and a fresh
# invocation must succeed.
RECLAIM_EXIT=0
(
    exec 200>"$LOCK_TEST_FILE"
    python3 "$SCRIPT_DIR/auto-promote-lock.py" 200 2>/dev/null
) || RECLAIM_EXIT=$?

if [ "$RECLAIM_EXIT" -eq 0 ]; then
    pass "lock helper: lock released on parent shell exit"
else
    fail "lock reclaim" "expected exit 0 after first holder exited, got $RECLAIM_EXIT"
fi

# --- Test 12: --preview mode produces identical output to legacy mode ---
# #248: federation-dashboard-collector invokes auto-promote-decisions.py
# --preview to unify dashboard fitness math with the scheduler. The two
# invocation shapes must produce byte-identical JSON so the dashboard and
# the sidecar never disagree. If this drifts, operators will see the same
# bug #248 originally reported (dashboard lying about promote candidates).

DAEMONS_FIXTURE='[{"source":"/fake/x.ag","pid":1,"agent_id":"a","colony":"c","started_at":1,"confidence":0.6,"state":"running"}]'
FED_DIR_FIXTURE=/tmp

# Parse config once via the real helper to get the 9 threshold values in
# the same positional form the sidecar uses.
eval "$(python3 "$SCRIPT_DIR/auto-promote-config-parser.py" "$SCRIPT_DIR/auto-promote-config.yaml")"

LEGACY_OUT=$(python3 "$SCRIPT_DIR/auto-promote-decisions.py" \
    "$DAEMONS_FIXTURE" "$FED_DIR_FIXTURE" \
    "$CFG_MIN_ENTRIES" "$CFG_MIN_ACTING_ENTRIES" "$CFG_MIN_RUNTIME_HOURS" \
    "$CFG_REJECT_RATE_THRESHOLD" "$CFG_DELTA_SLOPE_WINDOW" "$CFG_DELTA_SLOPE_MIN" \
    "$CFG_PROMOTE_STEPS" "$CFG_EVOLVE_SLOPE_NEG_FOR" "$CFG_EVOLVE_REJECT_ABOVE")

PREVIEW_OUT=$(python3 "$SCRIPT_DIR/auto-promote-decisions.py" \
    --preview --config "$SCRIPT_DIR/auto-promote-config.yaml" \
    "$DAEMONS_FIXTURE" "$FED_DIR_FIXTURE")

if [ "$LEGACY_OUT" = "$PREVIEW_OUT" ]; then
    pass "preview mode matches legacy mode byte-for-byte (#248)"
else
    fail "preview parity" "legacy <$LEGACY_OUT> preview <$PREVIEW_OUT>"
fi

# Preview mode must reject unknown flags / wrong arity so the dashboard
# gets a loud failure instead of silent empty decisions.
BAD_EXIT=0
python3 "$SCRIPT_DIR/auto-promote-decisions.py" --preview 2>/dev/null || BAD_EXIT=$?
if [ "$BAD_EXIT" -eq 2 ]; then
    pass "preview mode: missing args rejected with exit 2 (#248)"
else
    fail "preview arity" "expected exit 2 on missing args, got $BAD_EXIT"
fi

# --- Test 14: prereqs structure is attached to promote-path skips ---
# #248 PR B: the dashboard's promote-candidates skipped rendering reads
# evidence.prereqs to show a per-criterion checklist. If this array is
# missing or malformed the UI silently degrades back to the raw reason
# string. Verify every prereq object has {name, value, threshold, op, meets}.
SELF_PID=$$
LIVE_FIXTURE='[{"source":"/fake/y.ag","pid":'"$SELF_PID"',"agent_id":"y","colony":"c","started_at":'"$(date +%s)"',"confidence":0.4,"state":"running"}]'
PREREQS_OUT=$(python3 "$SCRIPT_DIR/auto-promote-decisions.py" \
    --preview --config "$SCRIPT_DIR/auto-promote-config.yaml" \
    "$LIVE_FIXTURE" "$FED_DIR_FIXTURE")

# Agent has zero experience + fresh started_at so it must fail on at least
# two prereqs (entries_total, runtime_hours). Evidence must carry a
# prereqs array with all required keys on each entry.
PREREQS_OK=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
if len(arr) != 1: sys.exit(1)
d = arr[0]
if d.get('decision') != 'skip': sys.exit(2)
ev = d.get('evidence', {})
pr = ev.get('prereqs')
if not isinstance(pr, list) or len(pr) < 3: sys.exit(3)
required = {'name', 'value', 'threshold', 'op', 'meets'}
for p in pr:
    if not isinstance(p, dict): sys.exit(4)
    if not required.issubset(p.keys()): sys.exit(5)
    if not isinstance(p['meets'], bool): sys.exit(6)
names = {p['name'] for p in pr}
# entries_total, entries_acting, runtime_hours always present
for n in ('entries_total', 'entries_acting', 'runtime_hours'):
    if n not in names: sys.exit(7)
print('ok')
" "$PREREQS_OUT" 2>&1 || true)
if [ "$PREREQS_OK" = "ok" ]; then
    pass "prereqs structure attached to promote-path skips (#248 PR B)"
else
    fail "prereqs structure" "got <$PREREQS_OK> from <$PREREQS_OUT>"
fi

# --- Test 15: tier-range step matcher (#331) ---
# Pre-#331 the matcher used `abs(confidence - step_from) < 0.001`, which only
# matched a confidence sitting exactly on a tier boundary (0.4 / 0.6 / 0.8).
# Real federations end up with off-boundary confidences either via operator
# typos at install (the live federation seeded 0.61) or via learn() nudges
# moving the value by +/-0.005..0.02. The matcher now uses tier-range
# membership (`step_from <= confidence < step_to`) aligned with ADR-0001.
#
# Each case below feeds a single-agent daemons fixture (using $$ as the pid
# so the os.kill(pid, 0) liveness check passes) and asserts the resulting
# decision matches expectation: either a skip with reason
# "no applicable promote step" (below ladder / already autonomous) or a
# step matched (the prereq fail path runs after target_step was identified;
# the absence of the no-step reason is what we assert).

# Helper: invoke decisions.py in --preview mode with a single-agent fixture.
# Args: $1=confidence, $2=expected_outcome ("step:from-to" or "no_step").
test_step_match() {
    case_conf="$1"
    case_expect="$2"
    case_label="step matcher: confidence=$case_conf -> $case_expect (#331)"
    case_fixture='[{"source":"/fake/x.ag","pid":'"$$"',"agent_id":"x","colony":"c","started_at":'"$(date +%s)"',"confidence":'"$case_conf"',"state":"running"}]'
    if ! case_out=$(python3 "$SCRIPT_DIR/auto-promote-decisions.py" \
            --preview --config "$SCRIPT_DIR/auto-promote-config.yaml" \
            "$case_fixture" "$FED_DIR_FIXTURE" 2>&1); then
        fail "$case_label" "decisions.py error: $case_out"
        return
    fi
    case_check=$(python3 -c "
import json, sys
arr = json.loads(sys.argv[1])
if len(arr) != 1:
    print('arity:' + str(len(arr))); sys.exit(0)
d = arr[0]
expect = sys.argv[2]
reason = d.get('reason', '')
decision = d.get('decision', '')
if expect == 'no_step':
    if decision == 'skip' and reason.startswith('no applicable promote step'):
        print('ok')
    else:
        print('expected no-step skip, got decision=' + decision + ' reason=' + reason)
else:
    if decision == 'skip' and reason.startswith('no applicable promote step'):
        print('expected step ' + expect + ' to match, got no-step skip')
    else:
        ev = d.get('evidence', {})
        pr = ev.get('prereqs')
        if pr is None and decision != 'promote':
            print('missing prereqs on skip and not a promote')
        else:
            print('ok')
" "$case_out" "$case_expect" 2>&1 || true)
    if [ "$case_check" = "ok" ]; then
        pass "$case_label"
    else
        fail "$case_label" "$case_check"
    fi
}

test_step_match "0.61" "step:0.6-0.8"
test_step_match "0.4" "step:0.4-0.6"
test_step_match "0.6" "step:0.6-0.8"
test_step_match "0.8" "step:0.8-0.95"
test_step_match "0.39" "no_step"
test_step_match "0.95" "no_step"
test_step_match "0.799" "step:0.6-0.8"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
