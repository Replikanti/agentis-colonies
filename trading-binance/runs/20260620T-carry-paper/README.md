# Carry paper-trade harness (#1190)

`tools/carry-paper.py` — the last gate before real money. Run it periodically
(e.g. daily via cron); each run appends one snapshot to a JSON-lines ledger,
accumulating a **live, forward, out-of-sample** record of what the regime-gated,
unlevered delta-neutral funding-carry book would do, marked by the deterministic
`carry-verify.sh` (#1175 M1).

Each snapshot: score trailing funding → select the persistent-positive basket
(top-K, mean>0 & pos-ratio≥0.55, the #1174 rule) → **regime-gate** (deploy only
if expected annualised carry clears the cost hurdle, else CASH — #1184) →
**unlevered** 1:1 (no short-leg leverage, #1188) → settle the prior snapshot's
basket against the funding accrued since, minus turnover cost, append the period
net + cumulative.

## Run

```sh
python3 tools/funding-download.py --symbols <universe> --start <recent> --end <today>
python3 tools/carry-paper.py --universe <universe> \
  --funding-dir trading-binance/data/funding \
  --ledger trading-binance/runs/carry-paper-live/ledger.jsonl \
  --verifier trading-binance/tools/carry-verify.sh \
  --top-k 6 --lookback-days 21 --min-pos-ratio 0.55 \
  --cost-bps-roundtrip 40 --min-annual-carry-pct 3
```

The ledger (`runs/carry-paper-live/`) is gitignored — it is runtime state that
accumulates forward. After a real out-of-sample stretch, compare the ledger's
realised cumulative net carry against the ~5 %/yr backtest expectation; that is
the honest live validation no backtest can give.

## First live snapshot (seed)

At seed time the current funding regime was **calm**: expected annualised carry
~2.4 %/yr, below the 3 % deploy hurdle → the harness correctly chose **CASH**
(don't pay ~40 bps round-trip to harvest thin carry — the #1184 regime-gate
lesson in action). It deploys the basket only when funding is hot enough to
clear costs.

`tools/test-carry-paper.sh`: 12 cases (DEPLOY/CASH selection, regime gate,
prior-snapshot settlement, cumulative accounting, negative-universe → cash,
missing-data exit).
