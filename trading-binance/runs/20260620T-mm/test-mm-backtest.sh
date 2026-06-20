#!/usr/bin/env bash
# test-mm-backtest.sh -- unit tests for mm-backtest.py (#1205). Synthetic tick
# files exercise the fill logic (bid fills on a sell that crosses it, ask on a
# buy), spread capture, inventory cap, adverse selection, and maker fees. No
# network (--trades-file).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MM="$SCRIPT_DIR/mm-backtest.py"
[ -f "$MM" ] || { echo "FAIL: missing $MM" >&2; exit 1; }

PASS=0; FAIL=0
FIX="$(mktemp -d)"; trap 'rm -rf "$FIX"' EXIT

# 1. OSCILLATING price around 100: sells at 99.9 fill our bid (buy), buys at
#    100.1 fill our ask (sell) -> capture the spread -> positive PnL, balanced
#    inventory. is_buyer_maker: true=market SELL (fills bid), false=market BUY.
python3 - "$FIX/osc.csv" <<'PY'
import sys
rows=[]
t=1000
for i in range(200):
    if i % 2 == 0:
        rows.append((t,"99.9","100","true"))   # market sell -> fills our bid (we buy @99.9-ish)
    else:
        rows.append((t,"100.1","100","false"))  # market buy  -> fills our ask (we sell @100.1-ish)
    t+=1000
open(sys.argv[1],"w").write("\n".join("%d,%s,%s,%s"%r for r in rows))
PY
OSC=$(python3 "$MM" --trades-file "$FIX/osc.csv" --half-spreads-bps 5 --maker-fees-bps 0 \
  --inventory-skews-bps 0 --ema-alphas 0.3 --max-inventory-notional 100000 --quote-notional 1000 2>/dev/null)
pnl=$(echo "$OSC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["pnl"])')
fills=$(echo "$OSC" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["fills"])')
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>0 else 1)' "$pnl" \
  && { echo "[PASS] 1a. oscillation captures spread -> positive PnL ($pnl)"; PASS=$((PASS+1)); } \
  || { echo "[FAIL] 1a. expected positive PnL got $pnl"; FAIL=$((FAIL+1)); }
[ "$fills" -gt 0 ] && { echo "[PASS] 1b. fills happen ($fills)"; PASS=$((PASS+1)); } || { echo "[FAIL] 1b. no fills"; FAIL=$((FAIL+1)); }

# 2. MONOTONIC RISE: only market BUYs at ever-higher prices -> only our ask fills
#    -> we keep SELLING into a rising market (accumulate SHORT) -> adverse
#    selection -> negative PnL, inventory pinned near -max.
python3 - "$FIX/rise.csv" <<'PY'
import sys
rows=[]; t=1000; px=100.0
for i in range(300):
    px*=1.0005  # +5bps each trade, monotonic
    rows.append((t,"%.4f"%px,"100","false"))  # all market buys -> hit our ask
    t+=1000
open(sys.argv[1],"w").write("\n".join("%d,%s,%s,%s"%r for r in rows))
PY
RISE=$(python3 "$MM" --trades-file "$FIX/rise.csv" --half-spreads-bps 5 --maker-fees-bps 0 \
  --inventory-skews-bps 0 --ema-alphas 0.3 --max-inventory-notional 5000 --quote-notional 1000 2>/dev/null)
rpnl=$(echo "$RISE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["pnl"])')
rinv=$(echo "$RISE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["final_inventory_notional"])')
maxinv=$(echo "$RISE" | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["max_abs_inventory_notional"])')
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])<0 else 1)' "$rpnl" \
  && { echo "[PASS] 2a. selling into a rising market loses (adverse selection) ($rpnl)"; PASS=$((PASS+1)); } \
  || { echo "[FAIL] 2a. expected negative PnL got $rpnl"; FAIL=$((FAIL+1)); }
# inventory should be short (negative) and capped near -max; the cap is checked
# BEFORE a fill, so it can overshoot by up to one quote_notional ($1000) -> the
# true bound is max_inv (5000) + quote_notional (1000) + mark slack.
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])<0 and abs(float(sys.argv[2]))<=6300 else 1)' "$rinv" "$maxinv" \
  && { echo "[PASS] 2b. inventory short + capped near -max +1 quote (inv=$rinv max=$maxinv)"; PASS=$((PASS+1)); } \
  || { echo "[FAIL] 2b. inventory cap breached inv=$rinv max=$maxinv"; FAIL=$((FAIL+1)); }

# 3. MAKER FEE monotonicity: a rebate (-2bps) beats paying (+2bps) on the same path.
REB=$(python3 "$MM" --trades-file "$FIX/osc.csv" --half-spreads-bps 5 --maker-fees-bps -2 \
  --inventory-skews-bps 0 --ema-alphas 0.3 --max-inventory-notional 100000 --quote-notional 1000 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["pnl"])')
PAY=$(python3 "$MM" --trades-file "$FIX/osc.csv" --half-spreads-bps 5 --maker-fees-bps 2 \
  --inventory-skews-bps 0 --ema-alphas 0.3 --max-inventory-notional 100000 --quote-notional 1000 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["results"][0]["pnl"])')
python3 -c 'import sys;sys.exit(0 if float(sys.argv[1])>float(sys.argv[2]) else 1)' "$REB" "$PAY" \
  && { echo "[PASS] 3. rebate PnL > pay-fee PnL ($REB > $PAY)"; PASS=$((PASS+1)); } \
  || { echo "[FAIL] 3. rebate not better: rebate=$REB pay=$PAY"; FAIL=$((FAIL+1)); }

# 4. too few trades -> exit 2
printf '1000,100,1,true\n2000,100,1,false\n' > "$FIX/tiny.csv"
python3 "$MM" --trades-file "$FIX/tiny.csv" --ema-alphas 0.3 >/dev/null 2>&1 \
  && { echo "[FAIL] 4. too-few-trades should exit nonzero"; FAIL=$((FAIL+1)); } \
  || { echo "[PASS] 4. too-few-trades exits nonzero"; PASS=$((PASS+1)); }

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
