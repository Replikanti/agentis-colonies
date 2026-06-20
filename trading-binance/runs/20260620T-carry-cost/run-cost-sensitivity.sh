#!/usr/bin/env bash
# run-cost-sensitivity.sh -- sweep the merged walk-forward carry backtest
# (runs/20260620T-carry/backtest-carry.py) across all-in round-trip costs,
# full span + key regimes, to find the breakeven cost and the honest net at
# realistic levels (#1183). Emits results.json.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
BT="$REPO/trading-binance/runs/20260620T-carry/backtest-carry.py"
FUNDING="${FUNDING_DIR:-$REPO/trading-binance/data/funding}"
UNIV="BTCUSDT,ETHUSDT,SOLUSDT,BNBUSDT,XRPUSDT,DOGEUSDT,AVAXUSDT,LINKUSDT,SUIUSDT,ADAUSDT,LTCUSDT,NEARUSDT,APTUSDT,ARBUSDT,OPUSDT,INJUSDT,TIAUSDT,AAVEUSDT"
COSTS="20 40 60 80 100 120"
ann() { python3 "$BT" --funding-dir "$FUNDING" --symbols "$UNIV" --start "$1" --end "$2" \
  --rebalance-days 30 --lookback-days 21 --top-k 6 --min-pos-ratio 0.55 --cost-bps-roundtrip "$3" 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["strategy_oos_walk_forward"]["annualised_pct"])'; }
{
  printf '{"costs_bps":[%s],"net_annualised_pct_by_regime":{' "$(echo $COSTS | tr ' ' ',')"
  first=1
  for r in "FULL:2024-01-01:2026-06-20" "2024H1:2024-01-01:2024-07-01" \
           "2024H2:2024-07-01:2025-01-01" "2025H1:2025-01-01:2025-07-01" \
           "2025H2:2025-07-01:2026-01-01" "2026H1:2026-01-01:2026-06-20"; do
    name="${r%%:*}"; rest="${r#*:}"; s="${rest%%:*}"; e="${rest#*:}"
    [ $first -eq 0 ] && printf ','; first=0
    printf '"%s":[' "$name"; fc=1
    for c in $COSTS; do [ $fc -eq 0 ] && printf ','; fc=0; printf '%s' "$(ann "$s" "$e" "$c")"; done
    printf ']'
  done
  printf '}}'
}
