# Intraday cross-sectional reversal (hourly) — strong signal, dies on cost (#1201)

The intraday counterpart to the daily cross-sectional momentum (#1194): at short horizons crypto's documented cross-sectional edge flips to **reversal** (overreaction snapback). Rank 18 alts by trailing L-hour return, **long the losers / short the winners**, hold H hours, rebalance, walk-forward. 2025-09 → 2026-06, ~7000 hourly bars.

## There IS a strong raw intraday reversal signal (0 bps)

| signal | lookback | hold | ann/yr | Sharpe | per-rebalance |
|---|---|---|---|---|---|
| **reversal** | 4 h | 4 h | +126 % | **2.92** | +5.75 bps |
| reversal | 4 h | 1 h | +136 % | 2.86 | +1.56 bps |
| reversal | 4 h | 2 h | +116 % | 2.47 | +2.65 bps |
| reversal | 6 h | 1 h | +102 % | 2.16 | +1.17 bps |

**Reversal dominates** — every top config is reversal, none is momentum, confirming the short-horizon sign flip vs the daily-momentum edge. The market over-reacts intraday and snaps back. Gross Sharpe ~2.9 is real.

## …but it does NOT survive realistic cost

| cost (round-trip) | best config | result | configs still positive |
|---|---|---|---|
| 0 bps | reversal 4h/4h | +126 %/yr, Sharpe 2.92 | 12 / 24 (11 of 12 reversal; momentum mirror negative) |
| **8 bps** (liquid perp taker) | reversal 4h/6h | **−9.3 %/yr, Sharpe −0.21** | **0 / 24** |
| 12 bps (thin alts) | reversal 4h/6h | −54 %/yr | 0 / 24 |

At 8 bps round-trip, **every one of 24 configs is negative.** The best gross edge was ~+5.75 bps per rebalance; the cost of capturing it (≈ cost × turnover ≈ 8 bps × ~0.7) is larger. The signal is real but **smaller than the cost of trading it as a taker.**

## Why — the edge is the liquidity provider's, not the taker's

The intraday reversal you measure IS the overreaction-and-snapback. But to capture it you must **cross the spread as a taker** at entry and exit — and the spread/fee you pay is essentially the same overreaction you are trying to harvest. The edge is the compensation a **market maker** earns for providing liquidity into the overreaction (posting limit orders, earning the spread/rebate). As a taker you pay exactly that. This is why intraday is dominated by makers with fee rebates and latency, and why a retail taker nets negative.

## The dividing line — per-trade edge vs per-trade cost

This sharpens the whole effort: a cross-sectional strategy wins iff **per-trade edge > per-trade cost.**
- **Daily/weekly momentum (#1194)** wins: the edge per rebalance is large and you trade rarely (weekly) — cost is a small fraction.
- **Intraday reversal** loses (as a taker): the edge per rebalance is a few bps and you trade many times a day — cost dominates.

## Verdict

Intraday cross-sectional reversal on hourly bars has a **strong, real raw signal (gross Sharpe ~2.9)** but **does not survive realistic taker costs — 0 of 24 configs positive at 8 bps.** For a retail taker on klines, intraday here is a net loser; the edge belongs to the liquidity provider. Capturing it would require **maker execution** (limit orders, rebates, queue management — a market-making problem, not a signal problem) and/or finer tick/order-book data + latency, which is a different and far harder game. The honest, deployable cross-sectional edge remains the **daily/weekly** one (#1194/#1197).

Reproduce: `run-meta.json` (hourly klines fetched live; not committed).
