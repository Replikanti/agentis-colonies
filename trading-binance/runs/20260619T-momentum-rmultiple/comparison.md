# Momentum + R-multiple backtest (#1154)

**Run:** `20260619T-momentum-rmultiple` · **Symbol:** BTCUSDT · **Timeframe:** 1h ·
**Window:** 2026-03-01 → 2026-05-31 (2208 candles, real Binance USDT-M klines)

## What this tests

The honest **"does the lever move the goal"** gate. #1148 added an R-multiple
(stop/target) exit model to `tools/verify-trade.sh` — the structural lever for
**profitable trades with a low win rate but a higher net return** (asymmetric
payoff: small stop, larger target). This run pairs that lever with a
positive-skew **momentum / breakout** signal (the inverse of the #1123 fade)
and asks: does asymmetric payoff produce a **positive expectancy** where the
fade (negative skew, fixed-time exit) lost (−360 bps)?

- **Deterministic** reference signal, **not** the LLM strategist; decisions
  settled by the repo's own R-multiple verifier (`tools/verify-trade.sh`,
  slippage 5 bps/side, funding 1 bps/8h over the *actual* hold, `HOLD_PERIOD=8`,
  `TIMEFRAME_MINUTES=60`).
- Signal: `volMA = SMA(volume, 20)`, lookback `L=20`. New `L`-bar high on
  **confirming** volume (`volume ≥ volMA`) → **LONG**; new `L`-bar low on
  confirming volume → **SHORT**; else **FLAT**. Enter *with* the move; ride to
  the target or get cut at the stop.

## Results (R-multiple sweep, 341 entries each)

Selection metric is **expectancy** (mean PnL bps/trade) + **profit factor**
(gross win / gross loss), not win rate. Baselines: FLAT **0 bps**; #1123 fade
**−360 bps**; buy-and-hold **+757 bps**.

| Config | Win rate | Total PnL (bps) | Expectancy (bps/trade) | Profit factor | Max DD (bps) | stop / target / time |
|---|---|---|---|---|---|---|
| 1R (stop 100 / target 100) | 43.1 % | **−5252** | −15.40 | 0.68 | 5450 | 132 / 119 / 90 |
| 2R (stop 100 / target 200) | 36.1 % | **−6443** | −18.89 | 0.64 | 6780 | 143 / 41 / 157 |
| 3R (stop 100 / target 300) | 34.9 % | **−7090** | −20.79 | 0.62 | 7722 | 146 / 17 / 178 |

(Full machine-readable output: [`results.json`](./results.json).)

## Verdict — honest, and negative (worse than the fade)

**No.** On this window the momentum/breakout signal under R-multiple exits is
**not profitable** — it loses at every R-multiple, **more** than the #1123 fade
(−360 bps), and it gets **worse as the target widens** (1R −5252 → 3R −7090 bps).
Profit factor is below 1.0 everywhere, expectancy is negative, and every config
beats neither FLAT nor buy-and-hold.

The mechanism is clear in the `exit_reason` breakdown: the wider the target, the
**rarer** a target hit (119 → 41 → **17** of 341) while stops/time-exits pile up.
On this 1h BTCUSDT window most breakouts are **false** — price prints a new
extreme on volume, then reverts into the stop. A 3R target almost never reaches;
the asymmetric payoff has nothing to pay out on.

## What this means (the useful part)

1. **The R-multiple lever works mechanically.** The exit fires correctly: a
   tighter target hits more often, funding accrues over the *actual* hold, and
   the stop/target/time mix shifts exactly as the geometry predicts. The #1148
   change is validated on real data.
2. **Asymmetric payoff alone does not create an edge.** Both deterministic
   signals now lose on this window — the **fade** (negative skew, fixed-time)
   AND the **momentum** (positive skew, R-multiple). The exit model is
   **necessary but not sufficient**; it only amplifies whatever edge the signal
   has, and a 1h breakout signal has **negative** edge here (the window is a
   choppy +10 % grind that punishes both fading extremes and chasing them).
3. For the goal (*low win rate, high return*), the next lever is the **signal**,
   not the exit: a signal with genuine positive expectancy, found by searching
   the strategy space (the substrate / evolution) and/or a regime filter that
   only trades breakouts when follow-through is likely — validated walk-forward,
   not on one window. The verifier did its job: it refused to let either
   mechanical hypothesis look profitable when it isn't.

## Validation caveats

- **Single in-sample window**, no walk-forward / out-of-sample. One 90-day 1h
  window is not robust; a trend-following signal can flip sign in a trending vs
  ranging regime.
- **Deterministic signal ≠ LLM strategist** — bounds the raw signal, not the
  tribe's realised behaviour.
- **Static R-multiple** (fixed stop/target in bps), not an ATR-scaled or
  trailing stop; fixed size 1.0; the verifier's flat cost model.

## Reproduce

See [`run-meta.json`](./run-meta.json) for exact parameters and the
download/regenerate command (raw shards + unified `candles.csv` not committed).
