# Cross-sectional long-short paper-trade harness (#1197)

`tools/xsectional-paper.py` — the live forward gate for the cross-sectional
momentum trading strategy, the long-short analogue of `carry-paper.py`. Run it
periodically (weekly via cron) on the #1194/#1197 winning config (top-4 / 30-day
lookback / vol-targeted to 20 %); each run appends one snapshot to a JSON-lines
ledger, accumulating a **live, forward, out-of-sample** record of what the
vol-targeted long-short book would do, marked by realised price returns.

Each snapshot: rank the universe by trailing 30-day return → **long top-4 /
short bottom-4** (dollar-neutral) → **settle** the prior snapshot's basket
against its realised forward return ([prior_ts, now], mean longs − mean shorts),
times the prior leverage, minus turnover cost → **size** the new book by
**trailing-vol targeting** (leverage = target / trailing realised vol, PAST-only,
capped at 3×, #1197). Append period net + cumulative.

## Run

```sh
python3 tools/xsectional-paper.py \
  --symbols <universe> \
  --ledger trading-binance/runs/xsectional-paper-live/ledger.jsonl \
  --top-k 4 --lookback-days 30 --cost-bps-roundtrip 60 --rebalance-days 7 \
  --target-vol-pct 20 --vol-window 8 --max-leverage 3
```

The ledger (`runs/xsectional-paper-live/`) is gitignored — runtime state that
accumulates forward. After a real out-of-sample stretch, compare the ledger's
cumulative net against the ~+20 %/yr (vol-targeted) backtest expectation; that is
the honest live validation no backtest can give.

## First live snapshot (seed)

Longs = the 30-day winners, shorts = the 30-day laggards, leverage 1.0 (no return
history yet to vol-target on); cumulative 0 (no prior to settle). Subsequent runs
settle the prior basket against realised forward returns and begin vol-targeting
once ≥2 periods of history exist.

`tools/test-xsectional-paper.sh`: 10 cases (ranking, prior-snapshot settlement,
realised forward return, turnover cost makes net<gross, leverage default,
cumulative accounting, too-few-symbols exit) — no network, fixture klines.
