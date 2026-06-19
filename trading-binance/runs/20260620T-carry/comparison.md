# Funding-carry backtest — Phase 1 (deterministic, walk-forward) (#1173)

**Window:** BTCUSDT + 17 alts, 2026-03-01 → 2026-06-01 (~276 8h funding events/symbol). **Harvest (OOS):** ~71 days after a 21-day trailing lookback.

## Why carry (the directional dead-end)

Directional prediction of liquid crypto from public candles has **no edge** — confirmed three ways: the #1123 fade (−360 bps), the #1154 momentum (−5252 bps), and the #1166 6-tribe LLM run (net-negative; evolution converged the tribes to **FLAT** — the rational response to a no-edge signal, but not a money-maker). Funding **carry** is a different game: **mechanical, non-predictive** — a delta-neutral position (short perp + long spot) collects the 8h funding rate when funding is positive, with no price-direction bet.

## The carry exists — but only on *persistent-positive* alts

Per-symbol always-on carry over the window (gross, pre-cost):

| Symbol | gross/yr | positive funding events | verdict |
|---|---|---|---|
| LINKUSDT | **+3.65 %** | 204/276 (74 %) | persistent ✅ |
| AVAXUSDT | +2.11 % | 184/276 (67 %) | persistent ✅ |
| DOGE / SUI / NEAR / AAVE / ARB | +1.7…+2.5 % | 60–67 % | persistent ✅ |
| BNBUSDT | +1.86 % | 102/276 (37 %) | **lumpy** (spike-driven) ⚠️ |
| BTC / ETH | ~0 % | ~50 % | arbed flat ❌ |
| SOL / XRP | −1.0…−1.8 % | <48 % | negative ❌ |

BTC/ETH/SOL perp funding **oscillates around zero** (efficiently arbed). The carry lives on **smaller, less-efficient alts** where longs persistently pay shorts.

## Walk-forward OOS result — churn is the killer

Selection on trailing 21-day funding, harvest forward (out-of-sample), equal-weight, 20 bps round-trip cost on turnover:

| Config | OOS annualised | Sharpe | cost drag | verdict |
|---|---|---|---|---|
| top-4, **rebalance 7d** | **−0.94 %/yr** | −2.62 | 0.70 % | ❌ churn cost (~3.6 %/yr) > carry |
| top-6, **rebalance 30d** | **+1.22 %/yr** | **3.01** | 0.28 % | ✅ low-churn wins |
| static hold 8 persistent alts (no rebalance) | **+2.63 %/yr** | — | 0 | ✅ buy-and-hold |
| static LINK+AAVE+AVAX (no rebalance) | **+2.80 %/yr** | — | 0 | ✅ |
| benchmark: always-on **all** alts | +0.29 %/yr | 1.0 | 0 | (dragged by negative alts) |
| benchmark: BTC-only | +0.16 %/yr | 0.29 | | |

**Two findings:**
1. **Carry is a real, positive-expectancy, mechanical edge** — but only ~1.2–2.8 %/yr in this (calm) window, with a **high Sharpe** (it's low-variance funding accrual, not a price bet). This is the **first genuinely positive-expectancy strategy** in the whole exercise.
2. **It's a buy-and-hold game, not a timing game.** Weekly rebalancing chasing trailing funding **loses** (−0.94 %/yr) — transaction costs (~3.6 %/yr of churn) exceed the carry, and trailing funding mean-reverts so selection adds little. Cutting rebalance to 30 days flips it to +1.22 %/yr (Sharpe 3); static hold of the persistent alts gives +2.6–2.8 %/yr.

## Honest verdict

Mechanical funding carry on persistent-positive-funding alts is **real and positive**, but in a calm regime it is **modest (~1.2–2.8 %/yr, ~risk-free-ish) with high Sharpe** — and only if held **low-churn**. It is NOT a "get rich" signal; it is a **steady carry** whose real upside is **regime-amplified**: in bull euphoria, funding on these alts spikes to 0.05–0.1 %/8h (50–100 %/yr). This window's max was ~0.01 %/8h. So carry is a **"hold the persistent basket + scale up when the funding regime is hot"** strategy.

## Caveats

- One window, one (calm) regime. Funding persistence must hold out-of-sample across regimes — that's what the #1167 walk-forward harness tests.
- Sharpe/DD on the static-hold variants is degenerate (few rebalance periods); the +1.22 %/yr / Sharpe-3.01 top-6/30d is on ~3 periods — directionally positive, not statistically robust.
- The backtest models funding accrual − turnover cost; it does **not** model delta-neutral execution risk (basis dislocation, short-leg liquidation/margin, spot custody, rebalance slippage). Real net is **lower**.
- Funding cadence varies (most 8h; TIA ~4h) — realised-funding sums are cadence-correct; the annualisation constant assumes 8h.

## Phase 2 (follow-up, justified)

The LLM-strategist + evolution now has a **real job** (gated by the walk-forward harness): pick the **sticky** persistent-positive basket (low turnover — churn kills it), size by funding magnitude, **avoid lumpy/negative** symbols (BNB/SOL/XRP), and **detect regime** to scale carry up in high-funding periods and to cash when funding goes flat. Carry verifier: PnL = funding collected − costs, delta-neutral.

Reproduce: see `run-meta.json` (raw funding data gitignored).
