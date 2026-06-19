#!/bin/bash
# test-verify-trade.sh -- unit tests for verify-trade.sh (#573 PR-4).
#
# Builds a fixed 20-candle CSV fixture in a tempdir, then exercises the
# verifier across LONG/SHORT/FLAT, slippage/funding subtraction, size
# scaling, and edge cases (overflow, missing file, malformed JSON).
#
# Also covers the optional R-multiple stop-loss / take-profit settlement
# (#1148) via dedicated engineered intrabar fixtures: stop-first,
# target-first, time-fallback, same-candle tie (pessimistic), SHORT mirror,
# funding-over-actual-hold, and a byte-identical disabled-path regression
# proving the verdict carries no `exit_reason` key when the knobs are unset.

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

# --- Test 13: pnl_bps_x100 field present and = int(pnl_bps * 100) ---
# Closes #589: strategist.ag parse_int truncates float pnl_bps to 0,
# so verify-trade.sh emits pnl_bps_x100 for precision-preserving int parse.
PRICES_CSV13="$(mktemp --suffix=.csv)"
{
    printf 'open\n'
    for i in $(seq 0 20); do printf '%s\n' "$(python3 -c "print(60000 + $i * 7)")"; done
} > "$PRICES_CSV13"
verdict13="$(DECISION_JSON='{"action":"LONG","size":1.0,"rationale":"r","setup":"s"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$PRICES_CSV13" \
    SLIPPAGE_BPS=0 FUNDING_RATE_BPS=0 \
    bash "$VERIFIER")"
field_x100="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps_x100"])' "$verdict13")"
field_float="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict13")"
expected="$(python3 -c "print(int(round($field_float * 100)))")"
if [ "$field_x100" = "$expected" ]; then
    PASS=$((PASS+1))
    echo "[PASS] 13b: pnl_bps_x100 = int(pnl_bps*100) (x100=$field_x100 float=$field_float)"
else
    FAIL=$((FAIL+1))
    echo "[FAIL] 13b: pnl_bps_x100 expected $expected got $field_x100"
fi
rm -f "$PRICES_CSV13"

# === R-multiple stop-loss / take-profit settlement (#1148) ===
#
# The 20-candle fixture above has ±0.5 intrabar range on a ~100 price
# (≈ ±50 bps), too tight to express controlled stop/target touches with
# margin. Build a dedicated fixture with engineered intrabar high/low rows
# so each scenario touches exactly one level deterministically.
#
# RFIX layout (entry candle is row[CONTEXT_TICK+1] = row[1]):
#   row 0 : seed (decision tick, not entered)
#   row 1 : entry, open=100.00, tight body (no touch)
#   row 2 : DOWN spike  — low=98.50 (-150 bps), high=100.20  (stop for LONG)
#   row 3 : UP   spike  — low=99.90, high=102.00 (+200 bps)  (target for LONG)
#   row 4 : TIE  candle — low=98.00 (-200 bps), high=102.00 (+200 bps)
#   rows 5..11 : flat body around 100 (no touch), open=100.00
# This lets a LONG with STOP_BPS=100/TARGET_BPS=180 hit:
#   - stop first  when the window includes row 2 before row 3,
#   - target first when row 3 is reachable but row 2's stop is disabled,
#   - tie (row 4) resolves pessimistically to stop.
RFIX="$WORK_DIR/candles-rmultiple.csv"
python3 - "$RFIX" <<'PYRFIX'
import sys
path = sys.argv[1]
# (open, high, low, close)
rows = [
    (100.00, 100.20, 99.80, 100.00),  # 0 seed
    (100.00, 100.20, 99.90, 100.00),  # 1 entry (no touch)
    (100.00, 100.20, 98.50, 99.00),   # 2 down spike -> LONG stop @ -150 bps
    (100.00, 102.00, 99.90, 101.50),  # 3 up spike   -> LONG target @ +200 bps
    (100.00, 102.00, 98.00, 100.00),  # 4 tie: both stop & target touched
    (100.00, 100.10, 99.90, 100.00),  # 5 flat
    (100.00, 100.10, 99.90, 100.00),  # 6 flat
    (100.00, 100.10, 99.90, 100.00),  # 7 flat
    (100.00, 100.10, 99.90, 100.00),  # 8 flat
    (100.00, 100.10, 99.90, 100.00),  # 9 flat
    (100.00, 100.10, 99.90, 100.00),  # 10 flat
    (100.00, 100.10, 99.90, 100.00),  # 11 flat
]
with open(path, "w") as out:
    out.write("ts,open,high,low,close,volume\n")
    for idx, (o, h, lo, c) in enumerate(rows):
        out.write(f"{idx},{o:.2f},{h:.2f},{lo:.2f},{c:.2f},1000\n")
PYRFIX

# --- Test 14: stop-first (LONG) ---
# Window entry_idx=1 .. last_idx=1+HOLD_PERIOD. With STOP_BPS=100 the down
# spike at row 2 (low=98.50 <= stop_px=99.00) is the first touch; target is
# disabled (TARGET_BPS=0) so exit_reason=stop, pnl negative-ish.
verdict14="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$RFIX" STOP_BPS=100 TARGET_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "14a: stop-first exit_reason" "$verdict14" "exit_reason" "stop"
assert_pnl_sign "14b: stop-first pnl negative" "$verdict14" "neg"

# --- Test 15: target-first (LONG) ---
# STOP_BPS=0 disables the down-spike stop; the up spike at row 3
# (high=102.00 >= tgt_px=101.80 for TARGET_BPS=180) is the first touch.
verdict15="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$RFIX" STOP_BPS=0 TARGET_BPS=180 \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "15a: target-first exit_reason" "$verdict15" "exit_reason" "target"
assert_pnl_sign "15b: target-first pnl positive" "$verdict15" "pos"

# --- Test 16: time-fallback (neither touched) ---
# Stop @ -300 bps (px 97.00) and target @ +300 bps (px 103.00) are never
# touched by any candle in the window (max swing is row 4 at ±200 bps).
# exit_reason=time, and pnl must equal the legacy fixed-time path for the
# same DECISION_JSON + tick (R-multiple disabled).
verdict16="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$RFIX" STOP_BPS=300 TARGET_BPS=300 \
    bash "$VERIFIER" 2>/dev/null)"
verdict16_legacy="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$RFIX" \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "16a: time-fallback exit_reason" "$verdict16" "exit_reason" "time"
pnl16="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict16")"
pnl16_legacy="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$verdict16_legacy")"
assert_approx "16b: time-fallback pnl == legacy fixed-time pnl" "$pnl16" "$pnl16_legacy" "0.001"

# --- Test 17: same-candle tie (pessimistic -> stop) ---
# A dedicated tie fixture where the FIRST forward candle (row 2) touches
# both levels intrabar: low=98.00 and high=102.00. With STOP_BPS=100
# (stop_px=99.00) and TARGET_BPS=100 (tgt_px=101.00), row 2's low <= stop
# AND high >= target -> a same-candle tie that must resolve pessimistically
# to the stop.
TIEFIX="$WORK_DIR/candles-tie.csv"
python3 - "$TIEFIX" <<'PYTIE'
import sys
path = sys.argv[1]
rows = [
    (100.00, 100.20, 99.80, 100.00),  # 0 seed
    (100.00, 100.10, 99.90, 100.00),  # 1 entry (no touch)
    (100.00, 102.00, 98.00, 100.00),  # 2 TIE: low -200bps & high +200bps
    (100.00, 100.10, 99.90, 100.00),  # 3 flat
    (100.00, 100.10, 99.90, 100.00),  # 4 flat
    (100.00, 100.10, 99.90, 100.00),  # 5 flat
    (100.00, 100.10, 99.90, 100.00),  # 6 flat
    (100.00, 100.10, 99.90, 100.00),  # 7 flat
    (100.00, 100.10, 99.90, 100.00),  # 8 flat
    (100.00, 100.10, 99.90, 100.00),  # 9 flat
    (100.00, 100.10, 99.90, 100.00),  # 10 flat
    (100.00, 100.10, 99.90, 100.00),  # 11 flat
]
with open(path, "w") as out:
    out.write("ts,open,high,low,close,volume\n")
    for idx, (o, h, lo, c) in enumerate(rows):
        out.write(f"{idx},{o:.2f},{h:.2f},{lo:.2f},{c:.2f},1000\n")
PYTIE
# LONG, STOP_BPS=100 (stop_px=99.00, row2 low 98.00 <= 99.00 -> stop hit)
# TARGET_BPS=100 (tgt_px=101.00, row2 high 102.00 >= 101.00 -> target hit)
# both in the same candle -> pessimistic stop wins.
verdict17="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$TIEFIX" STOP_BPS=100 TARGET_BPS=100 \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "17a: same-candle tie -> stop (pessimistic)" "$verdict17" "exit_reason" "stop"
assert_pnl_sign "17b: tie stop pnl negative" "$verdict17" "neg"

# --- Test 18: SHORT mirror (stop on high, target on low) ---
# SHORT direction: stop_px = entry*(1+STOP/10000) (above), tgt_px =
# entry*(1-TARGET/10000) (below). On TIEFIX row 2 (high=102.00, low=98.00):
#   STOP_BPS=100 -> stop_px=101.00, high 102.00 >= 101.00 -> stop hit (loss).
#   TARGET_BPS=100 -> tgt_px=99.00, low 98.00 <= 99.00 -> target hit (win).
# Same-candle tie -> stop wins -> SHORT stopped out -> pnl negative.
verdict18="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$TIEFIX" STOP_BPS=100 TARGET_BPS=100 \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "18a: SHORT tie -> stop" "$verdict18" "exit_reason" "stop"
assert_pnl_sign "18b: SHORT stop pnl negative" "$verdict18" "neg"
# SHORT target-only (stop disabled): row 2 low 98.00 <= tgt_px 99.00 -> win.
verdict18b="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$TIEFIX" STOP_BPS=0 TARGET_BPS=100 \
    bash "$VERIFIER" 2>/dev/null)"
assert_field "18c: SHORT target-only exit_reason" "$verdict18b" "exit_reason" "target"
assert_pnl_sign "18d: SHORT target pnl positive" "$verdict18b" "pos"

# --- Test 19: funding over ACTUAL hold (< HOLD_PERIOD) ---
# A target hit at row 2 (TIEFIX) means held = 1 candle, far short of
# HOLD_PERIOD=8. Funding accrues over the actual hold, so the R-multiple
# funding cost is strictly smaller than the legacy full-hold funding for the
# same params. Compare R-multiple target-hit vs the same trade run with a
# huge FUNDING_RATE_BPS to make the magnitude difference observable.
# held=1 -> funding_blocks=(1*30)/480=0.0625; legacy held=8 -> 0.5.
# Use FUNDING_RATE_BPS=100 size=1.0: R-multiple funding = 6.25 bps,
# legacy full-hold funding = 50 bps. Toggle FUNDING_RATE_BPS=0 to isolate.
v19_fund="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$TIEFIX" STOP_BPS=0 TARGET_BPS=100 \
    FUNDING_RATE_BPS=100 SLIPPAGE_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
v19_nofund="$(DECISION_JSON='{"action":"SHORT","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$TIEFIX" STOP_BPS=0 TARGET_BPS=100 \
    FUNDING_RATE_BPS=0 SLIPPAGE_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
p19_fund="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$v19_fund")"
p19_nofund="$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["pnl_bps"])' "$v19_nofund")"
# Actual funding charged = nofund - fund. Held=1 candle -> 100 * 0.0625 = 6.25 bps.
actual_fund="$(python3 -c 'import sys; print(float(sys.argv[1]) - float(sys.argv[2]))' "$p19_nofund" "$p19_fund")"
assert_approx "19a: funding over actual hold (held=1 -> 6.25 bps)" "$actual_fund" "6.25" "0.01"
# Legacy full-hold funding for the same FUNDING_RATE_BPS would be 50 bps;
# assert the R-multiple charge is strictly smaller (6.25 << 50).
fund_strictly_smaller="$(python3 -c 'import sys; print("yes" if float(sys.argv[1]) < 50.0 else "no")' "$actual_fund")"
if [ "$fund_strictly_smaller" = "yes" ]; then
    echo "[PASS] 19b: R-multiple funding (6.25 bps) < legacy full-hold funding (50 bps)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 19b: R-multiple funding not smaller than legacy full-hold"
    FAIL=$((FAIL + 1))
fi

# --- Test 20: BYTE-IDENTICAL disabled-path regression ---
# Same DECISION_JSON + tick with STOP_BPS / TARGET_BPS UNSET must produce a
# verdict with NO exit_reason key, byte-identical to the legacy path.
verdict20="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" \
    bash "$VERIFIER" 2>/dev/null)"
has_exit_reason="$(python3 -c 'import sys,json; print("yes" if "exit_reason" in json.loads(sys.argv[1]) else "no")' "$verdict20")"
if [ "$has_exit_reason" = "no" ]; then
    echo "[PASS] 20a: disabled path emits NO exit_reason key"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 20a: disabled path leaked exit_reason key (verdict=$verdict20)"
    FAIL=$((FAIL + 1))
fi
# Explicit STOP_BPS=0 TARGET_BPS=0 must be byte-identical to the unset case.
verdict20_zero="$(DECISION_JSON='{"action":"LONG","size":1.0,"setup":"price_action","rationale":"x"}' \
    CONTEXT_TICK=0 HOLD_PERIOD=8 CANDLES_CSV="$CANDLES" STOP_BPS=0 TARGET_BPS=0 \
    bash "$VERIFIER" 2>/dev/null)"
if [ "$verdict20" = "$verdict20_zero" ]; then
    echo "[PASS] 20b: STOP_BPS=0 TARGET_BPS=0 byte-identical to unset path"
    PASS=$((PASS + 1))
else
    echo "[FAIL] 20b: zero knobs differ from unset (unset=$verdict20 zero=$verdict20_zero)"
    FAIL=$((FAIL + 1))
fi
# pnl_bps for the disabled path matches test 1's winning LONG slice sign.
assert_pnl_sign "20c: disabled-path pnl positive (legacy LONG win)" "$verdict20" "pos"

# --- Summary ---
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

