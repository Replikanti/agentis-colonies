#!/usr/bin/env bash
# run-robustness.sh -- run the deterministic walk-forward carry backtest
# (runs/20260620T-carry/backtest-carry.py) across per-half-year regime windows
# + the full 2.5y span, to test whether the funding-carry edge holds OUT-OF-
# SAMPLE across bull/calm/weak regimes (#1175 robustness). Emits results.json.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BT="$REPO/trading-binance/runs/20260620T-carry/backtest-carry.py"
FUNDING="${FUNDING_DIR:-$REPO/trading-binance/data/funding}"
UNIV="BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT,XRPUSDT,DOGEUSDT,AVAXUSDT,LINKUSDT,SUIUSDT,ADAUSDT,LTCUSDT,NEARUSDT,APTUSDT,ARBUSDT,OPUSDT,INJUSDT,TIAUSDT,AAVEUSDT"
win() { python3 "$BT" --funding-dir "$FUNDING" --symbols "$UNIV" --start "$1" --end "$2" \
  --rebalance-days 30 --lookback-days 21 --top-k 6 --min-pos-ratio 0.55 --cost-bps-roundtrip 20; }
{
  echo '{"config":"top-6 / rebalance 30d / lookback 21d / min_pos_ratio 0.55 / cost 20bps","windows":{'
  first=1
  for w in "2024H1:2024-01-01:2024-07-01" "2024H2:2024-07-01:2025-01-01" \
           "2025H1:2025-01-01:2025-07-01" "2025H2:2025-07-01:2026-01-01" \
           "2026H1:2026-01-01:2026-06-20" "FULL:2024-01-01:2026-06-20"; do
    name="${w%%:*}"; rest="${w#*:}"; s="${rest%%:*}"; e="${rest#*:}"
    [ $first -eq 0 ] && echo ','; first=0
    printf '"%s":' "$name"
    win "$s" "$e" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(json.dumps({"window":d["window"],"strategy":d["strategy_oos_walk_forward"],"benchmark_all_alts":d["benchmark_always_on_all_alts"],"cost_drag_pct":d["total_cost_drag_pct"]}))'
  done
  echo '}}'
} 
