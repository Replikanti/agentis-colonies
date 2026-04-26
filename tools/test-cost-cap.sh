#!/bin/bash
# tools/test-cost-cap.sh: unit tests for the cost-cap sidecar (#318).
#
# Validates:
#   Test 1:  metered sum — same-day rows aggregate to daily_usd
#   Test 2:  metered sum — same-month rows aggregate to monthly_usd
#   Test 3:  metered sum — null cost_usd contributes 0
#   Test 4:  flat count  — daily/monthly/hourly counters
#   Test 5:  flat slope  — current/baseline ratio computed correctly
#   Test 6:  metered breach — daily over cap → status=breach
#   Test 7:  metered warning — between warn_at_pct and 100% → status=warning
#   Test 8:  flat slope spike — 5x baseline → status=breach
#   Test 9:  flat absolute — daily request count over cap → status=breach
#   Test 10: 90% soft threshold — daily near cap → status=warning
#   Test 11: cost-cap.sh --status JSON exits 0 with enabled=false
#   Test 12: cost-cap.sh evaluates a synthetic spend log end-to-end
#   Test 13: cost-cap.sh writes flag + override on metered breach (downgrade)
#   Test 14: period rollover clears flag/override
#
# Usage: ./tools/test-cost-cap.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: ${2:-}"; FAIL=$((FAIL + 1)); }

# Build a synthetic federation tree.
FAKE_FED="$TMPDIR_TEST/dev-apprenticeship"
SPEND_DIR="$FAKE_FED/triage/.agentis/spend"
mkdir -p "$SPEND_DIR" "$FAKE_FED/.agentis/logs"

today_epoch=$(date -u +%s)
today_iso=$(date -u -d "@$today_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -r "$today_epoch" "+%Y-%m-%dT%H:%M:%SZ")

# ----- Test 1: metered daily/monthly sum -----
{
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": 1.25, "cost_source": "real"}\n' "$today_epoch" "$today_iso"
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": 0.75, "cost_source": "real"}\n' "$today_epoch" "$today_iso"
} > "$SPEND_DIR/today.jsonl"

OUT="$(python3 "$SCRIPT_DIR/cost-cap-sum.py" metered "$FAKE_FED/*/.agentis/spend/*.jsonl" 60 2>/dev/null)"
DAILY="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('metered',{}).get('daily_usd'))" "$OUT")"
if [ "$DAILY" = "2.0" ]; then
    pass "metered daily_usd sums to 2.0"
else
    fail "metered daily_usd" "expected 2.0 got $DAILY"
fi

MONTHLY="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('metered',{}).get('monthly_usd'))" "$OUT")"
if [ "$MONTHLY" = "2.0" ]; then
    pass "metered monthly_usd sums to 2.0"
else
    fail "metered monthly_usd" "expected 2.0 got $MONTHLY"
fi

# ----- Test 3: null cost_usd contributes 0 -----
{
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": null, "cost_source": "unknown"}\n' "$today_epoch" "$today_iso"
    printf '{"ts": %d, "ts_iso": "%s", "cost_source": "unknown"}\n' "$today_epoch" "$today_iso"
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": 3.00, "cost_source": "real"}\n' "$today_epoch" "$today_iso"
} > "$SPEND_DIR/null.jsonl"
OUT2="$(python3 "$SCRIPT_DIR/cost-cap-sum.py" metered "$FAKE_FED/*/.agentis/spend/*.jsonl" 60 2>/dev/null)"
DAILY2="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(round(d.get('metered',{}).get('daily_usd'),2))" "$OUT2")"
if [ "$DAILY2" = "5.0" ]; then
    pass "metered: null cost_usd contributes 0 (sum=2.0+3.0=5.0)"
else
    fail "metered null handling" "expected 5.0 got $DAILY2"
fi
UNKNOWN_PCT="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('metered',{}).get('unknown_cost_pct'))" "$OUT2")"
if [ -n "$UNKNOWN_PCT" ]; then
    pass "metered: unknown_cost_pct populated ($UNKNOWN_PCT)"
else
    fail "metered unknown_cost_pct missing"
fi

rm -rf "$SPEND_DIR" && mkdir -p "$SPEND_DIR"

# ----- Test 4: flat counters -----
{
    printf '{"ts": %d, "ts_iso": "%s"}\n' "$today_epoch" "$today_iso"
    printf '{"ts": %d, "ts_iso": "%s"}\n' "$today_epoch" "$today_iso"
    printf '{"ts": %d, "ts_iso": "%s"}\n' "$today_epoch" "$today_iso"
} > "$SPEND_DIR/today.jsonl"
OUT3="$(python3 "$SCRIPT_DIR/cost-cap-sum.py" flat "$FAKE_FED/*/.agentis/spend/*.jsonl" 60 2>/dev/null)"
DREQ="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('flat',{}).get('daily_requests'))" "$OUT3")"
if [ "$DREQ" = "3" ]; then
    pass "flat: daily_requests counts 3"
else
    fail "flat daily_requests" "expected 3 got $DREQ"
fi

# ----- Test 5: slope ratio -----
# Make 100 rows in last 60 min, 24 rows in trailing 24h.
{
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19; do
        ts_off=$((today_epoch - i * 60))
        ts_iso2=$(python3 -c "import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$ts_off")
        for _j in 0 1 2 3 4; do
            printf '{"ts": %d, "ts_iso": "%s"}\n' "$ts_off" "$ts_iso2"
        done
    done
    for i in 6 12 18; do
        ts_off=$((today_epoch - i * 3600))
        ts_iso2=$(python3 -c "import datetime, sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), tz=datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$ts_off")
        printf '{"ts": %d, "ts_iso": "%s"}\n' "$ts_off" "$ts_iso2"
    done
} > "$SPEND_DIR/slope.jsonl"

OUT5="$(python3 "$SCRIPT_DIR/cost-cap-sum.py" flat "$FAKE_FED/*/.agentis/spend/*.jsonl" 60 2>/dev/null)"
SLOPE="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]).get('flat',{}); print(d.get('slope_multiplier'))" "$OUT5")"
SLOPE_HIGH="$(python3 -c "
import sys
v = sys.argv[1]
if v == 'None':
    print('skip')
else:
    print('high' if float(v) >= 5.0 else 'low')
" "$SLOPE")"
if [ "$SLOPE_HIGH" = "high" ]; then
    pass "flat: slope spike detected (multiplier=$SLOPE)"
else
    fail "flat slope" "multiplier $SLOPE not >= 5"
fi

# ----- Tests 6-10: status logic via direct python evaluator (mirror cost-cap.sh logic) -----
EVAL_PY='
import json, sys
mode = sys.argv[1]
warn_pct = float(sys.argv[2])
slope_warn = float(sys.argv[3])
slope_breach = float(sys.argv[4])
daily_usd_cap = float(sys.argv[5])
monthly_usd_cap = float(sys.argv[6])
daily_req_cap = float(sys.argv[7])
monthly_req_cap = float(sys.argv[8])
hourly_req_cap = float(sys.argv[9])
data = json.loads(sys.argv[10] or "{}")

def pct(v, cap):
    if cap <= 0:
        return 0.0
    return (v / cap) * 100.0

status = "active"
if mode == "metered":
    m = data.get("metered") or {}
    daily = float(m.get("daily_usd") or 0)
    monthly = float(m.get("monthly_usd") or 0)
    dp = pct(daily, daily_usd_cap)
    mp = pct(monthly, monthly_usd_cap)
    if dp >= 100.0 or mp >= 100.0:
        status = "breach"
    elif dp >= warn_pct or mp >= warn_pct:
        status = "warning"
else:
    f = data.get("flat") or {}
    daily = int(f.get("daily_requests") or 0)
    monthly = int(f.get("monthly_requests") or 0)
    hourly = int(f.get("hourly_requests") or 0)
    dp = pct(daily, daily_req_cap)
    mp = pct(monthly, monthly_req_cap)
    hp = pct(hourly, hourly_req_cap)
    sm = f.get("slope_multiplier")
    if dp >= 100.0 or mp >= 100.0 or hp >= 100.0:
        status = "breach"
    if sm is not None:
        smf = float(sm)
        if smf >= slope_breach:
            status = "breach"
        elif status != "breach" and smf >= slope_warn:
            status = "warning"
    if status not in ("breach", "warning"):
        if dp >= warn_pct or mp >= warn_pct or hp >= warn_pct:
            status = "warning"
print(status)
'

# Test 6: metered breach
DATA6='{"metered": {"daily_usd": 6.0, "monthly_usd": 50.0}}'
S6="$(python3 -c "$EVAL_PY" metered 80 3 5 5.00 100.00 1000 20000 200 "$DATA6")"
if [ "$S6" = "breach" ]; then
    pass "metered breach when daily $6 > $5 cap"
else
    fail "metered breach" "expected breach got $S6"
fi

# Test 7: metered warning
DATA7='{"metered": {"daily_usd": 4.5, "monthly_usd": 50.0}}'
S7="$(python3 -c "$EVAL_PY" metered 80 3 5 5.00 100.00 1000 20000 200 "$DATA7")"
if [ "$S7" = "warning" ]; then
    pass "metered warning at 90% of daily cap"
else
    fail "metered warning" "expected warning got $S7"
fi

# Test 8: flat slope spike
DATA8='{"flat": {"daily_requests": 100, "monthly_requests": 100, "hourly_requests": 50, "slope_multiplier": 6.0}}'
S8="$(python3 -c "$EVAL_PY" flat 80 3 5 5.00 100.00 1000 20000 200 "$DATA8")"
if [ "$S8" = "breach" ]; then
    pass "flat slope 6x baseline -> breach"
else
    fail "flat slope breach" "expected breach got $S8"
fi

# Test 9: flat absolute breach
DATA9='{"flat": {"daily_requests": 1500, "monthly_requests": 1500, "hourly_requests": 50, "slope_multiplier": 1.0}}'
S9="$(python3 -c "$EVAL_PY" flat 80 3 5 5.00 100.00 1000 20000 200 "$DATA9")"
if [ "$S9" = "breach" ]; then
    pass "flat daily 1500 > 1000 cap -> breach"
else
    fail "flat absolute breach" "expected breach got $S9"
fi

# Test 10: 90% soft threshold
DATA10='{"flat": {"daily_requests": 920, "monthly_requests": 920, "hourly_requests": 50, "slope_multiplier": 1.0}}'
S10="$(python3 -c "$EVAL_PY" flat 80 3 5 5.00 100.00 1000 20000 200 "$DATA10")"
if [ "$S10" = "warning" ]; then
    pass "flat 92% of daily cap -> warning"
else
    fail "flat warn" "expected warning got $S10"
fi

# ----- Test 11: cost-cap.sh --status with disabled config -----
cat > "$FAKE_FED/.cost-cap.toml" <<'TOML'
[cost]
enabled = false
mode = "metered"
TOML

# Provide a fake `agentis` so the script's `daemon list` succeeds
FAKE_BIN="$TMPDIR_TEST/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/agentis" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_BIN/agentis"
export PATH="$FAKE_BIN:$PATH"

OUT11="$("$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" --status 2>/dev/null || true)"
ENABLED11="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('enabled'))" "$OUT11" 2>/dev/null || echo "")"
if [ "$ENABLED11" = "False" ]; then
    pass "--status emits enabled=false"
else
    fail "--status JSON" "expected enabled=False got '$ENABLED11' (raw: $OUT11)"
fi

# ----- Test 12: cost-cap.sh tick over a synthetic spend log -----
cat > "$FAKE_FED/.cost-cap.toml" <<'TOML'
[cost]
enabled = true
mode = "metered"
warn_at_pct = 80
interval_s = 60

[cost.metered]
daily_usd_limit = 5.00
monthly_usd_limit = 100.00
on_breach = "downgrade"
TOML

# Provide a fake agentis returning one running daemon with a colony field
cat > "$FAKE_BIN/agentis" <<'EOF'
#!/bin/bash
case "$1 $2" in
    "daemon list")
        echo '[{"state":"running","source":"agents/router.ag","colony":"triage","agent_id":"a1","pid":123}]'
        ;;
    "daemon stop")
        ;;
    *) ;;
esac
exit 0
EOF
chmod +x "$FAKE_BIN/agentis"

# Stage spend log with $4 today (under $5 cap, over 80% warning threshold)
rm -f "$SPEND_DIR"/*.jsonl
{
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": 4.00, "cost_source": "real"}\n' "$today_epoch" "$today_iso"
} > "$SPEND_DIR/today.jsonl"

# Stub start-colony.sh so restart_agents doesn't bomb on missing scripts.
mkdir -p "$FAKE_FED/triage/scripts"
cat > "$FAKE_FED/triage/scripts/start-colony.sh" <<'EOF'
#!/bin/bash
echo "stub: $*"
exit 0
EOF
chmod +x "$FAKE_FED/triage/scripts/start-colony.sh"

"$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" >/dev/null 2>&1 || true
if [ -f "$FAKE_FED/.agentis/cost-cap-state.json" ]; then
    STATUS12="$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status'))" "$FAKE_FED/.agentis/cost-cap-state.json")"
    if [ "$STATUS12" = "warning" ]; then
        pass "tick at 80% of cap -> status=warning"
    else
        fail "tick warning" "expected warning got $STATUS12"
    fi
else
    fail "cost-cap-state.json not written"
fi

# ----- Test 13: breach over $5 cap writes flag/override -----
{
    printf '{"ts": %d, "ts_iso": "%s", "cost_usd": 6.00, "cost_source": "real"}\n' "$today_epoch" "$today_iso"
} > "$SPEND_DIR/today.jsonl"

"$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" >/dev/null 2>&1 || true
if [ -f "$FAKE_FED/.agentis/cost-cap-active" ] && [ -f "$FAKE_FED/.agentis/llm-backend-override" ]; then
    BACKEND="$(cat "$FAKE_FED/.agentis/llm-backend-override")"
    if [ "$BACKEND" = "mock" ]; then
        pass "breach -> writes cost-cap-active + override=mock"
    else
        fail "breach override content" "expected 'mock' got '$BACKEND'"
    fi
else
    fail "breach files not written"
fi

# ----- Test 14: --override clears flag/override -----
"$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" --override "test reset" >/dev/null 2>&1 || true
if [ ! -f "$FAKE_FED/.agentis/cost-cap-active" ] && [ ! -f "$FAKE_FED/.agentis/llm-backend-override" ]; then
    if [ -f "$FAKE_FED/.agentis/logs/cost-cap-override.jsonl" ]; then
        pass "--override clears flag/override + writes audit"
    else
        fail "--override audit log" "cost-cap-override.jsonl missing"
    fi
else
    fail "--override did not clear flag/override files"
fi

# ----- Test 15: --override under lock contention exits 75 (PR #328 LOW) -----
# Sidecar cron-style invocations silently exit 0 on contention (consistency
# with auto-promote.sh). Operator-facing --override needs to bubble the
# failure so the dashboard can prompt for retry instead of falsely
# reporting success.
LOCK_FILE="$SCRIPT_DIR/.cost-cap.lock"
# Hold the flock from a python subprocess for 2s, then run --override.
python3 -c "
import fcntl, sys, time
f = open(sys.argv[1], 'w')
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
time.sleep(2)
" "$LOCK_FILE" &
HOLDER_PID=$!
sleep 0.3  # let the holder grab the lock first
OVERRIDE_RC=0
"$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" --override "contention probe" >/dev/null 2>/tmp/cost-cap-15.stderr || OVERRIDE_RC=$?
wait "$HOLDER_PID" 2>/dev/null || true
if [ "$OVERRIDE_RC" = "75" ]; then
    if grep -q "another instance is running" /tmp/cost-cap-15.stderr; then
        pass "--override under lock contention exits 75 with retry hint on stderr"
    else
        fail "--override exit 75 but stderr lacks contention message" "$(cat /tmp/cost-cap-15.stderr)"
    fi
else
    fail "--override under lock contention did not exit 75 (got $OVERRIDE_RC)"
fi

# ----- Test 16: sidecar (no --override) under lock contention still exits 0 -----
python3 -c "
import fcntl, sys, time
f = open(sys.argv[1], 'w')
fcntl.flock(f.fileno(), fcntl.LOCK_EX)
time.sleep(2)
" "$LOCK_FILE" &
HOLDER_PID=$!
sleep 0.3
SIDECAR_RC=0
"$SCRIPT_DIR/cost-cap.sh" "$FAKE_FED" >/dev/null 2>&1 || SIDECAR_RC=$?
wait "$HOLDER_PID" 2>/dev/null || true
if [ "$SIDECAR_RC" = "0" ]; then
    pass "sidecar (no --override) under lock contention exits 0 (silent skip)"
else
    fail "sidecar under contention should exit 0, got $SIDECAR_RC"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
