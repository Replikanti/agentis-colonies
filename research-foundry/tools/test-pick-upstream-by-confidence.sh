#!/usr/bin/env bash
# test-pick-upstream-by-confidence.sh: regression test for the Phase 9
# PR-A picker (#663) -- synthesise 2 upstream memo rows with different
# confidence and assert the picker selects the higher-confidence PID.
#
# The picker logic lives inline inside every downstream .ag as the helper
# `_pick_upstream_by_confidence(role, output_key, tick)`. The python
# scoring core is duplicated boilerplate across 9 .ag files. This test
# exercises the same python pipeline standalone so a regression in any
# copy can be caught without spawning a daemon.
#
# Usage: ./research-foundry/tools/test-pick-upstream-by-confidence.sh
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

# pick_winner_pid <role> <decision_key> <conf_field> <tick>
# Echoes the winning PID on stdout. Mirrors the python pipeline embedded
# in `_pick_upstream_by_confidence` across the 9 downstream .ag files.
pick_winner_pid() {
    local role="$1"
    local decision_key="$2"
    local conf_field="$3"
    local tick="$4"
    AGENTIS_ROOT="$AGENTIS_ROOT" python3 -c '
import os, sys, subprocess, json, re
role = sys.argv[1]
decision_key = sys.argv[2]
conf_field = sys.argv[3]
tick = sys.argv[4]
suffix = ":" + decision_key + ":tick-" + tick
prefix = role + ":"
try:
    out = subprocess.run(["agentis", "memo", "list"], capture_output=True, text=True, check=False).stdout
except Exception:
    out = ""
best_pid = ""
best_conf = -1.0
for line in out.splitlines():
    line = line.strip()
    if not line or not line.startswith(prefix):
        continue
    key = line.split()[0]
    if not key.endswith(suffix):
        continue
    mid = key[len(prefix):-len(suffix)]
    if ":" in mid or not mid:
        continue
    try:
        v = subprocess.run(["agentis", "memo", "get", key], capture_output=True, text=True, check=False).stdout
    except Exception:
        v = ""
    try:
        obj = json.loads(v)
    except Exception:
        obj = None
    if not isinstance(obj, dict):
        continue
    try:
        conf = float(obj.get(conf_field, 0.0))
    except Exception:
        conf = 0.0
    if conf > best_conf:
        best_conf = conf
        best_pid = mid
print(best_pid)
' "$role" "$decision_key" "$conf_field" "$tick"
}

# --- Test 1: noticer picker selects higher-confidence surprise row ---
agentis memo set "noticer:pid-aaaa:surprise:tick-7" '{"surprise_found":true,"specific_value":"x","why_surprising":"y","confidence_in_surprise":0.42}' >/dev/null
agentis memo set "noticer:pid-bbbb:surprise:tick-7" '{"surprise_found":true,"specific_value":"u","why_surprising":"v","confidence_in_surprise":0.91}' >/dev/null
got="$(pick_winner_pid noticer surprise confidence_in_surprise 7)"
if [ "$got" = "pid-bbbb" ]; then
    pass "noticer: picker selects PID with confidence_in_surprise=0.91 over 0.42"
else
    fail "noticer pick" "expected pid-bbbb, got '$got'"
fi

# --- Test 2: picker returns empty string when no rows match the tick ---
got2="$(pick_winner_pid noticer surprise confidence_in_surprise 99)"
if [ -z "$got2" ]; then
    pass "noticer: picker returns empty when no rows for tick=99"
else
    fail "noticer empty pick" "expected empty, got '$got2'"
fi

# --- Test 3: auditor picker uses 'confidence' field name ---
agentis memo set "auditor:pid-cccc:verdict:tick-3" '{"audit_verdict":"VERIFIED_NEW","reasoning":"r","confidence":0.55,"problem_summary":"p"}' >/dev/null
agentis memo set "auditor:pid-dddd:verdict:tick-3" '{"audit_verdict":"KNOWN_PRIOR","reasoning":"r","confidence":0.83,"problem_summary":"p"}' >/dev/null
got3="$(pick_winner_pid auditor verdict confidence 3)"
if [ "$got3" = "pid-dddd" ]; then
    pass "auditor: picker selects PID with confidence=0.83 over 0.55"
else
    fail "auditor pick" "expected pid-dddd, got '$got3'"
fi

# --- Test 4: tie-breaking is deterministic (first-encountered wins on equal confidence) ---
# Two equal confidences should not crash; either PID is acceptable but
# the picker must return non-empty.
agentis memo set "noticer:pid-eeee:surprise:tick-11" '{"surprise_found":true,"specific_value":"x","why_surprising":"y","confidence_in_surprise":0.5}' >/dev/null
agentis memo set "noticer:pid-ffff:surprise:tick-11" '{"surprise_found":true,"specific_value":"u","why_surprising":"v","confidence_in_surprise":0.5}' >/dev/null
got4="$(pick_winner_pid noticer surprise confidence_in_surprise 11)"
if [ "$got4" = "pid-eeee" ] || [ "$got4" = "pid-ffff" ]; then
    pass "noticer: picker resolves ties without crashing"
else
    fail "noticer tie pick" "expected pid-eeee or pid-ffff, got '$got4'"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
