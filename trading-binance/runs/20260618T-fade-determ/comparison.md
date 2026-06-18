# tribe-zeta volume-divergence fade — backtest (#1123)

**Run:** `20260618T-fade-determ` · **Symbol:** BTCUSDT · **Timeframe:** 1h ·
**Window:** 2026-03-01 → 2026-05-31 (2208 candles, real Binance USDT-M klines)

## What this is (and is not)

This is the honest **"does the signal even work"** gate for Dr. David Paul's
volume-divergence **fade** thesis (the `tribe-zeta` hypothesis from #1121).

- It is a **deterministic reference implementation** of the fade signal —
  the exact rules encoded in `tribe-zeta/agents/strategist.ag`'s seed prompt,
  expressed as mechanical code. It is **not** the LLM strategist's realised
  behaviour, and it does **not** run the other five tribes.
- Decisions are settled by the repo's own ground-truth verifier
  (`tools/verify-trade.sh`) — the exact settler the live replay uses — so the
  PnL numbers are what a replay would record for these same decisions
  (slippage 5 bps/side, funding 1 bps/8h, `HOLD_PERIOD=8`, `TIMEFRAME_MINUTES=60`).
- The full **6-tribe LLM replay** (tribe-zeta vs alpha…epsilon, the literal
  scope of #1123) is **deferred** — see "Deferred" below.

## Signal (deterministic, faithful to the seed prompt)

Per candle `i`, with `volMA = SMA(volume, 20)` and a local-extreme lookback `L`:

| Condition | Action |
|-----------|--------|
| new `L`-bar high (`high[i] > max(high[i-L..i-1])`) **and** `volume[i] <= volMA` | **SHORT** (fade unconfirmed breakout) |
| new `L`-bar low (`low[i] < min(low[i-L..i-1])`) **and** `volume[i] <= volMA` | **LONG** (fade unconfirmed breakdown) |
| otherwise (incl. "volume confirms": at an extreme but `volume[i] > volMA`) | **FLAT** |

Size fixed at `1.0`; no indicators beyond raw OHLCV + volMA(20).

## Results (lookback sweep)

Baseline for the verdict is **FLAT = 0 bps** (no trades, no costs).
Buy-and-hold over the window (LONG, size 1.0, net of one round trip + funding):
**+757.01 bps** (raw price move +1043 bps ≈ +10.4%). The window was a clear
**uptrend**.

| Lookback `L` | Trades | Long / Short | Win rate | Total PnL (bps) | Mean PnL/trade (bps) | Max drawdown (bps) | Per-trade Sharpe |
|---|---|---|---|---|---|---|---|
| 20  | 64 | 39 / 25 | 46.9 % | **−360.02** | −5.625  | 646.63 | −0.0763 |
| 50  | 24 | 13 / 11 | 41.7 % | **−323.53** | −13.480 | 566.55 | −0.2028 |
| 100 | 16 | 7 / 9   | 37.5 % | **−424.02** | −26.501 | 653.11 | −0.3544 |

(Full machine-readable output: [`results.json`](./results.json).)

## Verdict — honest, and negative

**No. On this window the deterministic volume-divergence fade signal does not
beat FLAT, and it does not beat buy-and-hold.** It loses money at every
lookback tested: total PnL is negative (−324 to −424 bps), win rate is below
50 % everywhere, and per-trade Sharpe is negative. The effect **worsens** as
the lookback lengthens (more "decisive" extremes → larger average loss).

The mechanism is intuitive: BTCUSDT trended **up** ~10 % over this window, so
fading new highs with a SHORT is systematically the wrong side of a trend.
A fade-the-extremes heuristic is structurally counter-trend, and this window
was strongly trending — exactly the regime where a naive fade bleeds. This is
a useful negative result: the fade thesis is a heuristic, not a law, and on a
single trending window the mechanical version of it has **no edge**.

## Validation caveats

- **Single window, in-sample.** One 90-day window is not robust. No
  walk-forward, no out-of-sample, no multiple regimes (the result might differ
  in a ranging or mean-reverting regime, which is where fades are supposed to
  work).
- **Deterministic signal ≠ LLM strategist.** The live `tribe-zeta` strategist
  is an LLM that can read context the mechanical rule cannot (regime, structure,
  rationale) and whose prompt evolves (M98 v3). This backtest bounds the *raw
  signal*, not the tribe's realised behaviour.
- **No cross-tribe comparison yet.** "Beats the other five tribes?" is
  unanswered here — that needs the LLM replay.
- Fixed size 1.0 and the verifier's flat cost model (5 bps slippage, 1 bps/8h
  funding) — not a live-fill model.

## Deferred — the 6-tribe LLM replay

The literal #1123 scope ("run `tools/run-replay.sh` with all six tribes,
compare tribe-zeta vs the other five") requires an LLM backend.
`tools/run-replay.sh` defaults to `llm.backend=openai` and **hard-fails
without `OPENROUTER_API_KEY`**; the `claude`/`cli` backend is not yet wired
into the replay container (`tools/Containerfile.replay`: "Future replay-side
claude backend support …"). The 6-tribe replay is therefore deferred and is
**operator-reproducible** with a key:

```bash
export OPENROUTER_API_KEY=...                      # cheap Qwen path
python3 trading-binance/tools/binance-feed-download.py \
  --symbol BTCUSDT --timeframe 1h --start 2026-03-01 --end 2026-05-31
REPLAY_SYMBOL=BTCUSDT REPLAY_TIMEFRAME=1h bash trading-binance/tools/run-replay.sh
# then read tribe-zeta's trade-ledger.jsonl + experience rows and compare to the other five.
```

#1123 remains **open** for that step.

## Reproduce this deterministic backtest

See [`run-meta.json`](./run-meta.json) for exact parameters and the
download/regenerate command (raw market-data shards and the unified
`candles.csv` are intentionally not committed).
