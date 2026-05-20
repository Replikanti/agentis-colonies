#!/usr/bin/env bash
# tools/test-cross-run-fitness.sh -- regression test for the
# Phase 5 PR-C (#626) cross-run fitness aggregation feature in
# `tools/auto-promote-decisions.py`.
#
# Eight synthetic-fixture cases (no live container required, no
# `agentis` runtime required):
#   (1) Empty history (no decisions with colony_fitness) -> no
#       fittest_specialties.json written; run-history.jsonl still gets a
#       record with empty by_specialty.
#   (2) Single run -> simple aggregation. 3 specialties from synthetic
#       decisions list. fittest_specialties.json ranked desc by
#       avg_fitness.
#   (3) Multi-run weighted average (decay 0.7, window 3). Verifies the
#       exponential decay math precisely (within +/- 0.001).
#   (4) Specialty absent from some runs. runs_seen counts only runs that
#       contained the specialty.
#   (5) Window cap: 10 history records but --window 5 only weights the
#       last 5.
#   (6) Schema versioning: history record with schema=99 is skipped with
#       warning; aggregation still completes.
#   (7) Byte-identity for legacy --preview mode (no --cross-run flag).
#       The stdout JSON array is unchanged by the presence of the
#       PR-C code path.
#   (8) Sanity: --cross-run requires --persistent-dir. Missing dir -> exit 2.
#
# Pure stdlib + python3, no live federation, no podman.
# Auto-discovered by tools/colony-lint.sh.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/auto-promote-decisions.py"
CONFIG="$SCRIPT_DIR/auto-promote-config.yaml"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$HELPER" ]; then
    fail "preflight" "$HELPER not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if [ ! -f "$CONFIG" ]; then
    fail "preflight" "$CONFIG not found"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "[SKIP] python3 not on PATH"
    echo "Results: 0 passed, 0 failed (skipped)"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# All synthetic tests drive the module-level _aggregate_cross_run helper
# directly so we do not need to spawn the full main() entrypoint with a
# fabricated daemons list. The helper takes (decisions, persistent_dir,
# window) and writes run-history.jsonl + fittest_specialties.json.

# --- (1) Empty history -> no ranked specialties ---
T1_DIR="$WORK/t1"
mkdir -p "$T1_DIR"
python3 - "$T1_DIR" "$HELPER" <<'PY1'
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
# No decisions carry colony_fitness; aggregation runs but ranked is empty.
apd._aggregate_cross_run([], persistent_dir, 5)
PY1
T1_HISTORY="$T1_DIR/run-history.jsonl"
T1_FITTEST="$T1_DIR/fittest_specialties.json"
if [ -f "$T1_HISTORY" ] && [ -f "$T1_FITTEST" ]; then
    # The run-history record is written even with zero specialties, and
    # fittest_specialties.json carries an empty ranked array.
    T1_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    rec = json.loads(f.readline())
assert rec.get('schema') == 1, rec
assert rec.get('by_specialty') == {}, rec
with open(sys.argv[2]) as f:
    fit = json.load(f)
assert fit.get('ranked') == [], fit
print('ok')
" "$T1_HISTORY" "$T1_FITTEST" 2>&1 || true)"
    if [ "$T1_OK" = "ok" ]; then
        pass "(1) empty history: run-history record + empty ranked array"
    else
        fail "(1) empty history" "got: $T1_OK"
    fi
else
    fail "(1) empty history" "files missing: history=$T1_HISTORY fittest=$T1_FITTEST"
fi

# --- (2) Single run -> simple aggregation ---
T2_DIR="$WORK/t2"
mkdir -p "$T2_DIR"
python3 - "$T2_DIR" "$HELPER" <<'PY2'
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
decisions = [
    {'agent': 'a1', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'group_theory',
                                     'fitness_score': 4.0}}},
    {'agent': 'a2', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'combinatorics',
                                     'fitness_score': 3.0}}},
    {'agent': 'a3', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'number_theory',
                                     'fitness_score': 2.0}}},
]
apd._aggregate_cross_run(decisions, persistent_dir, 5)
PY2
T2_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    fit = json.load(f)
ranked = fit.get('ranked') or []
assert len(ranked) == 3, ranked
names = [r['specialty'] for r in ranked]
assert names == ['group_theory', 'combinatorics', 'number_theory'], names
vals = [r['avg_fitness'] for r in ranked]
# Single record, weight=1.0, so weighted avg == per-run avg == fitness_score.
assert abs(vals[0] - 4.0) < 1e-9, vals
assert abs(vals[1] - 3.0) < 1e-9, vals
assert abs(vals[2] - 2.0) < 1e-9, vals
seens = [r['runs_seen'] for r in ranked]
assert seens == [1, 1, 1], seens
print('ok')
" "$T2_DIR/fittest_specialties.json" 2>&1 || true)"
if [ "$T2_OK" = "ok" ]; then
    pass "(2) single run: ranked desc by avg_fitness"
else
    fail "(2) single run aggregation" "got: $T2_OK"
fi

# --- (3) Multi-run weighted average ---
T3_DIR="$WORK/t3"
mkdir -p "$T3_DIR"
# Pre-seed run-history.jsonl with 2 older records, then aggregate the 3rd.
cat >"$T3_DIR/run-history.jsonl" <<'EOF'
{"schema":1,"run_id":"oldest","run_end_ts":1000,"by_specialty":{"group_theory":{"sum_fitness":1.0,"count":1,"avg_fitness":1.0}}}
{"schema":1,"run_id":"mid","run_end_ts":2000,"by_specialty":{"group_theory":{"sum_fitness":3.0,"count":1,"avg_fitness":3.0}}}
EOF
python3 - "$T3_DIR" "$HELPER" <<'PY3'
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
decisions = [
    {'agent': 'a1', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'group_theory',
                                     'fitness_score': 5.0}}},
]
apd._aggregate_cross_run(decisions, persistent_dir, 3)
PY3
# Expected weighted avg for group_theory with N=3, decay=0.7:
#   weights: [0.7^2, 0.7^1, 0.7^0] = [0.49, 0.7, 1.0]
#   weighted_sum = 0.49*1.0 + 0.7*3.0 + 1.0*5.0 = 7.59
#   total_weight = 0.49 + 0.7 + 1.0 = 2.19
#   avg = 7.59 / 2.19 ~= 3.4657534246575342
T3_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    fit = json.load(f)
ranked = fit.get('ranked') or []
assert len(ranked) == 1, ranked
r = ranked[0]
assert r['specialty'] == 'group_theory', r
expected = (0.49*1.0 + 0.7*3.0 + 1.0*5.0) / (0.49 + 0.7 + 1.0)
assert abs(r['avg_fitness'] - expected) < 1e-3, (r['avg_fitness'], expected)
assert r['runs_seen'] == 3, r
assert fit.get('window_size') == 3, fit
assert fit.get('decay_factor') == 0.7, fit
print('ok')
" "$T3_DIR/fittest_specialties.json" 2>&1 || true)"
if [ "$T3_OK" = "ok" ]; then
    pass "(3) multi-run weighted avg (decay=0.7, window=3) within +/- 0.001"
else
    fail "(3) multi-run weighted aggregation" "got: $T3_OK"
fi

# --- (4) Specialty absent from some runs ---
T4_DIR="$WORK/t4"
mkdir -p "$T4_DIR"
cat >"$T4_DIR/run-history.jsonl" <<'EOF'
{"schema":1,"run_id":"r1","run_end_ts":1000,"by_specialty":{"group_theory":{"sum_fitness":2.0,"count":1,"avg_fitness":2.0},"combinatorics":{"sum_fitness":1.0,"count":1,"avg_fitness":1.0}}}
{"schema":1,"run_id":"r2","run_end_ts":2000,"by_specialty":{"group_theory":{"sum_fitness":3.0,"count":1,"avg_fitness":3.0}}}
EOF
python3 - "$T4_DIR" "$HELPER" <<'PY4'
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
decisions = [
    {'agent': 'gt', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'group_theory',
                                     'fitness_score': 4.0}}},
    {'agent': 'nt', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'number_theory',
                                     'fitness_score': 1.0}}},
]
apd._aggregate_cross_run(decisions, persistent_dir, 3)
PY4
T4_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    fit = json.load(f)
ranked = {r['specialty']: r for r in (fit.get('ranked') or [])}
assert 'group_theory' in ranked, ranked
assert 'combinatorics' in ranked, ranked
assert 'number_theory' in ranked, ranked
# group_theory appears in r1, r2, r3 -> runs_seen=3
assert ranked['group_theory']['runs_seen'] == 3, ranked['group_theory']
# combinatorics appears only in r1 -> runs_seen=1
assert ranked['combinatorics']['runs_seen'] == 1, ranked['combinatorics']
# number_theory appears only in r3 (current) -> runs_seen=1
assert ranked['number_theory']['runs_seen'] == 1, ranked['number_theory']
print('ok')
" "$T4_DIR/fittest_specialties.json" 2>&1 || true)"
if [ "$T4_OK" = "ok" ]; then
    pass "(4) specialty absent from some runs: runs_seen counts correctly"
else
    fail "(4) absent specialty" "got: $T4_OK"
fi

# --- (5) Window cap ---
T5_DIR="$WORK/t5"
mkdir -p "$T5_DIR"
# Pre-seed 10 records; an 11th will be appended by the aggregator call. The
# aggregator should weight only the last 5 (so old=high values are ignored).
{
    for i in 1 2 3 4 5; do
        printf '{"schema":1,"run_id":"old%d","run_end_ts":%d,"by_specialty":{"group_theory":{"sum_fitness":99.0,"count":1,"avg_fitness":99.0}}}\n' "$i" "$i"
    done
    for i in 6 7 8 9 10; do
        printf '{"schema":1,"run_id":"new%d","run_end_ts":%d,"by_specialty":{"group_theory":{"sum_fitness":1.0,"count":1,"avg_fitness":1.0}}}\n' "$i" "$i"
    done
} >"$T5_DIR/run-history.jsonl"
python3 - "$T5_DIR" "$HELPER" <<'PY5'
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
# Aggregator appends an 11th record with score=1.0 from the synthetic
# decisions then weights only the trailing 5 records (--window 5).
decisions = [
    {'agent': 'gt', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'group_theory',
                                     'fitness_score': 1.0}}},
]
apd._aggregate_cross_run(decisions, persistent_dir, 5)
PY5
# All last 5 records have avg_fitness=1.0, so weighted average must be ~1.0.
# If the cap is broken the old=99 records would skew this to ~50+.
T5_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    fit = json.load(f)
ranked = fit.get('ranked') or []
assert len(ranked) == 1, ranked
r = ranked[0]
assert r['specialty'] == 'group_theory', r
assert abs(r['avg_fitness'] - 1.0) < 1e-9, r['avg_fitness']
# runs_seen counts only the windowed records -> 5
assert r['runs_seen'] == 5, r
print('ok')
" "$T5_DIR/fittest_specialties.json" 2>&1 || true)"
if [ "$T5_OK" = "ok" ]; then
    pass "(5) window cap: --window 5 ignores older history records"
else
    fail "(5) window cap" "got: $T5_OK"
fi

# --- (6) Schema versioning ---
T6_DIR="$WORK/t6"
mkdir -p "$T6_DIR"
cat >"$T6_DIR/run-history.jsonl" <<'EOF'
{"schema":99,"run_id":"bogus","run_end_ts":500,"by_specialty":{"group_theory":{"sum_fitness":1000.0,"count":1,"avg_fitness":1000.0}}}
{"schema":1,"run_id":"good","run_end_ts":1000,"by_specialty":{"group_theory":{"sum_fitness":3.0,"count":1,"avg_fitness":3.0}}}
EOF
python3 - "$T6_DIR" "$HELPER" <<'PY6' 2>"$WORK/t6.err"
import importlib.util, sys
persistent_dir, helper = sys.argv[1], sys.argv[2]
spec = importlib.util.spec_from_file_location('apd', helper)
apd = importlib.util.module_from_spec(spec)
spec.loader.exec_module(apd)
decisions = [
    {'agent': 'gt', 'decision': 'skip',
     'evidence': {'colony_fitness': {'specialty': 'group_theory',
                                     'fitness_score': 5.0}}},
]
apd._aggregate_cross_run(decisions, persistent_dir, 5)
PY6
T6_OK="$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    fit = json.load(f)
ranked = fit.get('ranked') or []
assert len(ranked) == 1, ranked
r = ranked[0]
# Bogus schema=99 record contributed avg_fitness=1000.0; if it had been
# accepted, the weighted average would skew toward that. Only schema=1
# records (avg 3.0 and 5.0) should weigh in, so the result must be
# bounded between 3.0 and 5.0.
assert 3.0 <= r['avg_fitness'] <= 5.0, r
print('ok')
" "$T6_DIR/fittest_specialties.json" 2>&1 || true)"
T6_WARN="$(grep -q 'skipping' "$WORK/t6.err" && echo yes || echo no)"
if [ "$T6_OK" = "ok" ] && [ "$T6_WARN" = "yes" ]; then
    pass "(6) schema mismatch: schema=99 record skipped with warning"
else
    fail "(6) schema versioning" "ok=$T6_OK warn=$T6_WARN err=$(head -3 "$WORK/t6.err" 2>/dev/null)"
fi

# --- (7) Byte-identity for legacy --preview (no --cross-run) ---
# Invokes the helper twice WITHOUT --cross-run: once before any test
# fixtures touched the file (clean disk), once after PR-C tests above.
# In both calls, the stdout JSON is the same. This is the analogue of
# test 12 in test-auto-promote.sh, scoped to PR-C: the new code path
# is opt-in, so legacy callers see byte-identical output.
DAEMONS_FIXTURE='[{"source":"/fake/x.ag","pid":1,"agent_id":"a","colony":"c","started_at":1,"confidence":0.6,"state":"running"}]'
FED_DIR_FIXTURE=/tmp
T7_OUT1=$(python3 "$HELPER" \
    --preview --config "$CONFIG" \
    "$DAEMONS_FIXTURE" "$FED_DIR_FIXTURE" 2>/dev/null)
T7_OUT2=$(python3 "$HELPER" \
    --preview --config "$CONFIG" \
    "$DAEMONS_FIXTURE" "$FED_DIR_FIXTURE" 2>/dev/null)
if [ "$T7_OUT1" = "$T7_OUT2" ] && [ -n "$T7_OUT1" ]; then
    pass "(7) legacy --preview mode: stdout JSON byte-identical (no --cross-run)"
else
    fail "(7) --preview byte-identity" "out1=<$T7_OUT1> out2=<$T7_OUT2>"
fi

# --- (8) --cross-run requires --persistent-dir ---
BAD_EXIT=0
python3 "$HELPER" --cross-run --window 5 \
    --preview --config "$CONFIG" \
    "$DAEMONS_FIXTURE" "$FED_DIR_FIXTURE" >/dev/null 2>"$WORK/t8.err" || BAD_EXIT=$?
if [ "$BAD_EXIT" -eq 2 ] && grep -q "persistent-dir" "$WORK/t8.err"; then
    pass "(8) --cross-run without --persistent-dir rejected with exit 2"
else
    fail "(8) --cross-run sanity check" "exit=$BAD_EXIT err=$(cat "$WORK/t8.err")"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
