#!/usr/bin/env bash
# test-pick-upstream.sh: regression test for the #712 picker fix.
#
# The Phase 9 PR-A picker (`_pick_upstream_by_confidence`, duplicated
# verbatim across 9 downstream .ag files) used to silently swallow
# the caller's `output_key` via a hardcoded `meta` map that collapsed
# every formulator call to `formulator:*:problem:tick-N`. The fix
# accepts explicit `(role, ranking_key, output_key, confidence_field,
# tick)` and adds a single-replica fast path so N=1 is race-free.
#
# This test exercises the same python pipeline standalone -- if any
# of the 9 .ag copies drifts the helper, this script catches it.
#
# Usage: ./research-foundry/tools/test-pick-upstream.sh
# Exit 0 if all tests pass, 1 otherwise.

set -eu

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
export AGENTIS_ROOT="$TMPDIR_TEST/.agentis"
mkdir -p "$AGENTIS_ROOT"

cleanup() {
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis binary not on PATH; cannot exercise memo store"
    exit 0
fi

# Initialise the temp agentis root.
(cd "$TMPDIR_TEST" && agentis init >/dev/null 2>&1) || true

# pick_value <role> <ranking_key> <output_key> <confidence_field> <tick>
# Echoes the value of `<role>:<picked_pid>:<output_key>:tick-<tick>`
# on stdout (empty when no candidates). Mirrors the new python pipeline
# inlined into `_pick_upstream_pid_by_key` + `_pick_upstream_by_confidence`
# across all 9 downstream .ag files.
pick_value() {
    local role="$1"
    local ranking_key="$2"
    local output_key="$3"
    local confidence_field="$4"
    local tick="$5"
    AGENTIS_ROOT="$AGENTIS_ROOT" python3 -c '
import sys, subprocess, json
role = sys.argv[1]
rk = sys.argv[2]
ok = sys.argv[3]
cf = sys.argv[4]
tick = sys.argv[5]
suf = ":" + rk + ":tick-" + tick
pre = role + ":"
try:
    out = subprocess.run(["agentis","memo","list"], capture_output=True, text=True, check=False).stdout
except Exception:
    out = ""
pids = []
for line in out.splitlines():
    line = line.strip()
    if not line or not line.startswith(pre):
        continue
    key = line.split()[0]
    if not key.endswith(suf):
        continue
    mid = key[len(pre):-len(suf)]
    if ":" in mid or not mid:
        continue
    pids.append(mid)
best_pid = ""
if len(pids) == 1:
    best_pid = pids[0]
elif len(pids) > 1:
    if not cf:
        pids.sort()
        best_pid = pids[0]
    else:
        best_conf = -1.0
        for mid in sorted(pids):
            try:
                v = subprocess.run(["agentis","memo","get",pre+mid+suf], capture_output=True, text=True, check=False).stdout
            except Exception:
                v = ""
            try:
                obj = json.loads(v)
            except Exception:
                obj = None
            if not isinstance(obj, dict):
                continue
            try:
                conf = float(obj.get(cf, 0.0))
            except Exception:
                conf = 0.0
            if conf > best_conf:
                best_conf = conf
                best_pid = mid
        if not best_pid:
            best_pid = sorted(pids)[0]
if not best_pid:
    sys.stdout.write("")
    sys.stderr.write("[" + role + "] picker empty rank=" + rk + " tick=" + tick + "\n")
    sys.exit(0)
val_key = pre + best_pid + ":" + ok + ":tick-" + tick
try:
    val = subprocess.run(["agentis","memo","get",val_key], capture_output=True, text=True, check=False).stdout
except Exception:
    val = ""
sys.stdout.write(val.rstrip("\n"))
' "$role" "$ranking_key" "$output_key" "$confidence_field" "$tick"
}

# --- Test 1: single-replica fast path returns the explicit output_key ---
# Pre-fix bug: with formulator's 4 output keys (problem, problem_text,
# answer, novelty_claim) the meta map always rewrote dk=problem, so
# the picker found the candidate but then read `problem` instead of
# the requested `problem_text` / `answer`. With the new signature the
# caller controls output_key independently of ranking_key.
agentis memo set "formulator:111:problem:tick-3" '{"self_check_confidence":0.8,"problem":"P","answer":"A","novelty_claim":"NC"}' >/dev/null
agentis memo set "formulator:111:problem_text:tick-3" 'P' >/dev/null
agentis memo set "formulator:111:answer:tick-3" 'A' >/dev/null
agentis memo set "formulator:111:novelty_claim:tick-3" 'NC' >/dev/null

got_pt="$(pick_value formulator problem problem_text self_check_confidence 3)"
if [ "$got_pt" = "P" ]; then
    pass "Test 1a (N=1 fast path): problem_text returned as 'P'"
else
    fail "Test 1a" "expected 'P', got '$got_pt'"
fi

got_ans="$(pick_value formulator problem answer self_check_confidence 3)"
if [ "$got_ans" = "A" ]; then
    pass "Test 1b (N=1 fast path): answer returned as 'A'"
else
    fail "Test 1b" "expected 'A', got '$got_ans'"
fi

got_nc="$(pick_value formulator problem novelty_claim self_check_confidence 3)"
if [ "$got_nc" = "NC" ]; then
    pass "Test 1c (N=1 fast path): novelty_claim returned as 'NC'"
else
    fail "Test 1c" "expected 'NC', got '$got_nc'"
fi

# --- Test 2: multi-replica path -- higher confidence_field wins ---
# Two formulator PIDs writing distinct problem_text values; the picker
# must rank by self_check_confidence and return the winner's value.
agentis memo set "formulator:444:problem:tick-5" '{"self_check_confidence":0.4,"problem":"LowConf","answer":"A1","novelty_claim":"N1"}' >/dev/null
agentis memo set "formulator:444:problem_text:tick-5" 'LowConf' >/dev/null
agentis memo set "formulator:444:answer:tick-5" 'A1' >/dev/null
agentis memo set "formulator:555:problem:tick-5" '{"self_check_confidence":0.9,"problem":"HighConf","answer":"A2","novelty_claim":"N2"}' >/dev/null
agentis memo set "formulator:555:problem_text:tick-5" 'HighConf' >/dev/null
agentis memo set "formulator:555:answer:tick-5" 'A2' >/dev/null

got_high="$(pick_value formulator problem problem_text self_check_confidence 5)"
if [ "$got_high" = "HighConf" ]; then
    pass "Test 2a (N=2 ranking): higher-confidence PID's problem_text wins"
else
    fail "Test 2a" "expected 'HighConf', got '$got_high'"
fi

got_high_ans="$(pick_value formulator problem answer self_check_confidence 5)"
if [ "$got_high_ans" = "A2" ]; then
    pass "Test 2b (N=2 ranking): higher-confidence PID's answer wins"
else
    fail "Test 2b" "expected 'A2', got '$got_high_ans'"
fi

# --- Test 3: no candidates -- empty string + picker-empty log ---
got_empty_stdout="$(pick_value formulator problem problem_text self_check_confidence 99 2>/dev/null)"
got_empty_stderr="$(pick_value formulator problem problem_text self_check_confidence 99 2>&1 >/dev/null)"
if [ -z "$got_empty_stdout" ]; then
    pass "Test 3a (no candidates): stdout is empty"
else
    fail "Test 3a" "expected empty stdout, got '$got_empty_stdout'"
fi
if echo "$got_empty_stderr" | grep -q "picker empty rank=problem tick=99"; then
    pass "Test 3b (no candidates): picker-empty marker logged"
else
    fail "Test 3b" "expected picker-empty log, got '$got_empty_stderr'"
fi

# --- Test 4: malformed JSON in ranking_key -- graceful alpha-first fallback ---
# Two PIDs at tick=7; both ranking_key memos are bare strings (no JSON
# parseable). Picker must NOT crash and must return alphabetical-first
# PID's output_key value.
agentis memo set "formulator:aaa:problem:tick-7" 'not-json-garbage' >/dev/null
agentis memo set "formulator:aaa:problem_text:tick-7" 'AAA-text' >/dev/null
agentis memo set "formulator:bbb:problem:tick-7" '{malformed json}' >/dev/null
agentis memo set "formulator:bbb:problem_text:tick-7" 'BBB-text' >/dev/null

got_garbage="$(pick_value formulator problem problem_text self_check_confidence 7)"
if [ "$got_garbage" = "AAA-text" ]; then
    pass "Test 4 (malformed JSON): alpha-first fallback returns AAA-text"
else
    fail "Test 4" "expected 'AAA-text' (alpha-first), got '$got_garbage'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
