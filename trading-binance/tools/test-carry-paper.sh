#!/usr/bin/env bash
# test-carry-paper.sh -- unit tests for carry-paper.py (#1190). Fixture funding +
# the merged carry-verify.sh; exercises basket selection, the regime gate
# (DEPLOY vs CASH), settlement of the prior snapshot, and cumulative accounting.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAPER="$SCRIPT_DIR/carry-paper.py"
VERIFIER="$SCRIPT_DIR/carry-verify.sh"
[ -f "$PAPER" ] || { echo "FAIL: missing $PAPER" >&2; exit 1; }
[ -x "$VERIFIER" ] || { echo "FAIL: carry-verify not executable" >&2; exit 1; }

PASS=0; FAIL=0
FIX="$(mktemp -d)"; LEDGER="$FIX/ledger.jsonl"
trap 'rm -rf "$FIX"' EXIT

# AAAUSDT: persistent positive funding; events for the first snapshot's lookback
# (1000-5000) and for the settlement period (7000-9000). 0.0003/8h -> ~32.85%/yr.
printf 'fundingTime,fundingRate\n1000,0.0003\n2000,0.0003\n3000,0.0003\n4000,0.0003\n5000,0.0003\n7000,0.0003\n8000,0.0003\n9000,0.0003\n' > "$FIX/AAAUSDT.csv"
# BBBUSDT: negative funding -> never selected.
printf 'fundingTime,fundingRate\n1000,-0.0002\n2000,-0.0002\n3000,-0.0002\n4000,-0.0002\n5000,-0.0002\n' > "$FIX/BBBUSDT.csv"

field() { python3 -c 'import sys,json; print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }
lastrow() { tail -1 "$LEDGER"; }
assert_eq() {
  local label="$1" got="$2" want="$3"
  if python3 -c 'import sys;sys.exit(0 if abs(float(sys.argv[1])-float(sys.argv[2]))<1e-6 else 1)' "$got" "$want"; then
    echo "[PASS] $label (=$got)"; PASS=$((PASS+1))
  else echo "[FAIL] $label got=$got want=$want"; FAIL=$((FAIL+1)); fi
}
assert_str() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then echo "[PASS] $label (=$got)"; PASS=$((PASS+1))
  else echo "[FAIL] $label got=$got want=$want"; FAIL=$((FAIL+1)); fi
}

# 1. First snapshot at now=6000: trailing sees AAA(+)/BBB(-) -> DEPLOY AAA only,
#    weight 1.0; entry cost from cash (turnover 1.0 * 40bps/2 = 20bps).
python3 "$PAPER" --universe AAAUSDT,BBBUSDT --funding-dir "$FIX" --ledger "$LEDGER" \
  --verifier "$VERIFIER" --top-k 6 --lookback-days 21 --min-pos-ratio 0.55 \
  --cost-bps-roundtrip 40 --min-annual-carry-pct 3 --now 6000 >/dev/null
R="$(lastrow)"
assert_str "1a. snapshot1 regime DEPLOY" "$(field "$R" regime)" "DEPLOY"
assert_str "1b. snapshot1 basket = AAAUSDT" "$(python3 -c 'import sys,json;print(",".join(p["symbol"] for p in json.loads(sys.argv[1])["positions"]))' "$R")" "AAAUSDT"
assert_eq  "1c. snapshot1 entry turnover cost = 20bps" "$(field "$R" period_turnover_bps)" "20.0"
assert_eq  "1d. snapshot1 period_net = -20 (entry cost, no carry yet)" "$(field "$R" period_net_bps)" "-20.0"

# 2. Second snapshot at now=10000: settles AAA over [6000,10000) = funding
#    7000+8000+9000 = 0.0009 -> 9 bps carry at weight 1.0; AAA->AAA no turnover.
python3 "$PAPER" --universe AAAUSDT,BBBUSDT --funding-dir "$FIX" --ledger "$LEDGER" \
  --verifier "$VERIFIER" --top-k 6 --lookback-days 21 --min-pos-ratio 0.55 \
  --cost-bps-roundtrip 40 --min-annual-carry-pct 3 --now 10000 >/dev/null
R="$(lastrow)"
assert_eq  "2a. snapshot2 realised carry = 9 bps" "$(field "$R" period_carry_bps)" "9.0"
assert_eq  "2b. snapshot2 turnover = 0 (unchanged basket)" "$(field "$R" period_turnover_bps)" "0.0"
assert_eq  "2c. snapshot2 period_net = +9" "$(field "$R" period_net_bps)" "9.0"
assert_eq  "2d. cumulative = -20 + 9 = -11" "$(field "$R" cumulative_net_bps)" "-11.0"

# 3. REGIME GATE: same data, but min-annual-carry impossibly high -> CASH.
LEDGER2="$FIX/ledger2.jsonl"
python3 "$PAPER" --universe AAAUSDT,BBBUSDT --funding-dir "$FIX" --ledger "$LEDGER2" \
  --verifier "$VERIFIER" --min-annual-carry-pct 9999 --now 6000 >/dev/null
R="$(tail -1 "$LEDGER2")"
assert_str "3a. high carry-hurdle -> regime CASH" "$(field "$R" regime)" "CASH"
assert_str "3b. CASH basket empty" "$(python3 -c 'import sys,json;print(len(json.loads(sys.argv[1])["positions"]))' "$R")" "0"

# 4. negative-only universe -> CASH (no symbol clears pos-ratio).
LEDGER3="$FIX/ledger3.jsonl"
python3 "$PAPER" --universe BBBUSDT --funding-dir "$FIX" --ledger "$LEDGER3" \
  --verifier "$VERIFIER" --min-annual-carry-pct 3 --now 6000 >/dev/null
assert_str "4. negative-only universe -> CASH" "$(field "$(tail -1 "$LEDGER3")" regime)" "CASH"

# 5. missing funding dir -> exit 2
if python3 "$PAPER" --universe AAAUSDT --funding-dir "$FIX/nope" --ledger "$FIX/l4" --verifier "$VERIFIER" >/dev/null 2>&1; then
  echo "[FAIL] 5. missing funding dir should be non-zero"; FAIL=$((FAIL+1))
else echo "[PASS] 5. missing funding dir exits non-zero"; PASS=$((PASS+1)); fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
