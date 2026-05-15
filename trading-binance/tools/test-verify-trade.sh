#!/bin/bash
# test-verify-trade.sh -- unit tests for verify-trade.sh (#573 PR-4).
#
# Builds a fixed 20-candle CSV fixture in a tempdir, then exercises the
# verifier across LONG/SHORT/FLAT, slippage/funding subtraction, size
# scaling, and edge cases (overflow, missing file, malformed JSON).

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERIFIER="$SCRIPT_DIR/verify-trade.sh"

if [ ! -x "$VERIFIER" ]; then
    echo "FAIL: verifier not executable: $VERIFIER" >&2
    exit 1
fi

PASS=0
FAIL=0

assert_pnl_sign() {
    # $1: label, $2: verdict_json, $3: expected_sign (pos|neg|zero)
    local label="$1"
    local verdict="$2"
    local expected="$3"
    local pnl
    pnl="$(python3 -c 'import sys,json; v=json.loads(sys.argv[1]); print(v.get("pnl_bps", 0.0))' "$verdict")"
    local sign
    sign="$(python3 -c 'import sys; v=float(sys.argv[1]); print("pos" if v>0 else ("neg" if v<0 else "zero"))' "$pnl")"
    if [ "$sign" = "$expected" ]; then
        echo "[PASS] $label (pnl_bps=$pnl sign=$sign)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label expected sign=$expected got pnl_bps=$pnl sign=$sign"
        FAIL=$((FAIL + 1))
    fi
}

assert_field() {
    # $1: label, $2: verdict_json, $3: jq-style key, $4: expected
    local label="$1"
    local verdict="$2"
    local key="$3"
    local expected="$4"
    local actual
    actual="$(python3 -c 'import sys,json; v=json.loads(sys.argv[1]); print(v.get(sys.argv[2]))' "$verdict" "$key")"
    if [ "$actual" = "$expected" ]; then
        echo "[PASS] $label ($key=$actual)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label expected $key=$expected got $actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    # $1: label, $2: actual_exit, $3: expected_exit
    local label="$1"
    local actual="$2"
    local expected="$3"
    if [ "$actual" = "$expected" ]; then
        echo "[PASS] $label (exit=$actual)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label expected exit=$expected got exit=$actual"
        FAIL=$((FAIL + 1))
    fi
}

assert_approx() {
    # $1: label, $2: actual, $3: expected, $4: tolerance
    local label="$1"
    local actual="$2"
    local expected="$3"
    local tol="$4"
    local ok
    ok="$(python3 -c 'import sys; a=float(sys.argv[1]); e=float(sys.argv[2]); t=float(sys.argv[3]); print("yes" if abs(a-e)<=t else "no")' "$actual" "$expected" "$tol")"
    if [ "$ok" = "yes" ]; then
        echo "[PASS] $label (actual=$actual expected=$expected tol=$tol)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label expected=$expected actual=$actual tol=$tol"
        FAIL=$((FAIL + 1))
    fi
}

# --- Build the candle CSV fixture ---
# 20 rows of synthetic OHLCV. Deliberately deterministic for stable
# assertions:
#   - rows 0..9 have open monotonically increasing 100..109 (uptrend).
#   - rows 10..19 have open monotonically decreasing 109..100 (downtrend).
# Volume is constant (1000) to keep volume-conditioned setups out of
# the verifier's path; verify-trade.sh ignores volume.
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
CANDLES="$WORK_DIR/candles.csv"
python3 - "$CANDLES" <<'PYFIXTURE'
import sys
path = sys.argv[1]
opens = [100 + i for i in range(10)] + [109 - i for i in range(10)]
with open(path, "w") as out:
    out.write("ts,open,high,low,close,volume\n")
    for idx, o in enumerate(opens):
        high = o + 0.5
        low = o - 0.5
        close = o + 0.1
        out.write(f"{idx},{o:.2f},{high:.2f},{low:.2f},{close:.2f},1000\n")
PYFIXTURE

# --- Test 1: LONG winning trade (uptrend slice 0..8) ---
# entry = row[1].open = 101, exit = row[9].open = 109 → +800 bps raw,
# minus slippage (10 bps both sides) and minimal funding → still positive.
verdict="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
assert_pnl_sign "1: LONG winning trade" "$verdict" "pos"

# --- Test 2: LONG losing trade (downtrend slice 11..19) ---
# entry = row[12].open = 107, exit = row[19].open = 100 → -654 bps raw,
# minus costs → solidly negative.
verdict="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=11 HOLD_PERIOD=7 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
assert_pnl_sign "2: LONG losing trade" "$verdict" "neg"

# --- Test 3: SHORT winning (price drops) ---
# direction = -1, entry = 107, exit = 100 → +654 bps raw, minus costs.
verdict="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=11 HOLD_PERIOD=7 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
assert_pnl_sign "3: SHORT winning trade" "$verdict" "pos"

# --- Test 4: SHORT losing (price rises) ---
verdict="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
assert_pnl_sign "4: SHORT losing trade" "$verdict" "neg"

# --- Test 5: FLAT → PnL = 0, classification = FLAT ---
verdict="$(DECISION_JSON='{"action":"FLAT","size":0.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "5a: FLAT classification" "$verdict" "classification" "FLAT"
assert_field "5b: FLAT pnl_bps" "$verdict" "pnl_bps" "0.0"

# --- Test 6: Slippage subtraction verified ---
# Same LONG trade as test 1, but SLIPPAGE_BPS=0 → pnl_bps higher than
# default slippage path. Subtraction effect must be observable.
verdict_default="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
verdict_no_slip="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" SLIPPAGE_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
pnl_default="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict_default")"
pnl_no_slip="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict_no_slip")"
# default slippage = 5 bps per side, size=1.0 → 2 * 5 * 1.0 = 10 bps total subtracted.
slip_delta="$(python3 -c 'import sys; print(float(sys.argv[1]) - float(sys.argv[2]))' "$pnl_no_slip" "$pnl_default")"
assert_approx "6: slippage subtraction (10 bps)" "$slip_delta" "10.0" "0.01"

# --- Test 7: Funding subtraction verified ---
# Toggle FUNDING_RATE_BPS=0 → delta == default funding cost for size=1.0
# HOLD_PERIOD=8 30m candles → (8*30)/480 = 0.5 blocks * 1 bps * 1.0 = 0.5 bps.
verdict_no_fund="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" FUNDING_RATE_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
pnl_no_fund="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict_no_fund")"
fund_delta="$(python3 -c 'import sys; print(float(sys.argv[1]) - float(sys.argv[2]))' "$pnl_no_fund" "$pnl_default")"
assert_approx "7: funding subtraction (0.5 bps)" "$fund_delta" "0.5" "0.01"

# --- Test 8: Size scaling (half size = half PnL) ---
verdict_half="$(DECISION_JSON='{"action":"LONG","size":0.5,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
pnl_half="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict_half")"
expected_half="$(python3 -c 'import sys; print(float(sys.argv[1]) / 2.0)' "$pnl_default")"
assert_approx "8: half-size = half PnL" "$pnl_half" "$expected_half" "0.01"

# --- Test 9: Zero-volume candle handling (uses open price regardless) ---
# Build a one-row-tweaked CSV where the entry candle has volume=0; the
# verifier must still produce a verdict (volume is not referenced).
CANDLES_ZV="$WORK_DIR/candles-zerovol.csv"
python3 - "$CANDLES" "$CANDLES_ZV" <<'PYZVOL'
import sys
with open(sys.argv[1]) as src, open(sys.argv[2], "w") as out:
    for idx, line in enumerate(src):
        if idx == 2:
            # Row index 1 (entry candle in test 9): wipe volume column.
            parts = line.rstrip("\n").split(",")
            parts[-1] = "0"
            out.write(",".join(parts) + "\n")
        else:
            out.write(line)
PYZVOL
verdict="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES_ZV" \
    bash "$VERIFIER" 2>/dev/null)"
assert_pnl_sign "9: zero-volume entry candle still verifiable" "$verdict" "pos"

# --- Test 10: Overflow → exit 2 ---
# CANDLES is 20 rows long. CONTEXT_TICK=18 + 1 + HOLD_PERIOD=5 = 24 → overflow.
set +e
DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=18 HOLD_PERIOD=5 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "10: overflow CONTEXT_TICK + HOLD_PERIOD >= len(candles)" "$rc" "2"

# --- Test 11: Missing CANDLES_CSV → exit 3 ---
set +e
DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$WORK_DIR/no-such-file.csv" \
    bash "$VERIFIER" >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "11: missing CANDLES_CSV exits 3" "$rc" "3"

# --- Test 12: Malformed DECISION_JSON → exit 4 ---
set +e
DECISION_JSON='not json at all' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" >/dev/null 2>&1
rc=$?
set -e
assert_exit_code "12: malformed DECISION_JSON exits 4" "$rc" "4"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
