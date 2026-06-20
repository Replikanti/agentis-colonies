# Cross-sectional long-short — relative-value TRADING (#1193)

A genuine **active trading** test (not yield): rank 18 alts by trailing return, **LONG the top-4 / SHORT the bottom-4**, dollar-neutral equal-weight, **rebalance weekly**, hold forward (out-of-sample). 2024-01 → 2026-06, daily perp klines. We proved *absolute* directional prediction has no edge (#1123/#1154/#1166/#1167); this tests *relative* (cross-sectional) performance — a less-efficient, documented factor.

## Signal sweep (weekly, top-4, realistic 60 bps round-trip)

| Signal | lookback | net annualised | Sharpe | max DD |
|---|---|---|---|---|
| **momentum** | **30 d** | **+43.0 %/yr** | **0.93** | 32.6 % |
| momentum | 14 d | +41.2 %/yr | 0.84 | 51.4 % |
| momentum | 7 d | −27.8 %/yr | −0.54 | (blows up, 128 %) |
| reversal | 7/14/30 d | −19.8 / −73.6 / −65.8 %/yr | <0 | huge (124–187 %) |

**Cross-sectional MOMENTUM at a medium (14–30-day) lookback works** — long the alts that outperformed over the last month, short the laggards. Short-term (7 d) momentum and all reversal variants lose. (Note: *absolute* momentum lost — #1154; the edge is in the **relative** ranking, dollar-neutral, which captures winner-vs-loser dispersion and hedges market beta.)

## Pressure tests (momentum 30 d)

**Cost sensitivity (full 2.5 y):**

| cost (bps RT) | 20 | 40 | **60** | 80 | 100 | 150 |
|---|---|---|---|---|---|---|
| net annualised | +50.6 | +46.8 | **+43.0** | +39.3 | +35.5 | +26.0 |
| Sharpe | 1.09 | 1.01 | **0.93** | 0.84 | 0.76 | 0.56 |

Gentle cost slope (~3.8 %/yr per 20 bps); **breakeven ~280 bps** — NOT cost-fragile despite the weekly turnover.

**Per-year robustness (60 bps):**

| | 2024 | 2025 | 2026 H1 |
|---|---|---|---|
| net annualised | +57.7 % | +30.9 % | +87.7 % |
| Sharpe | 0.98 | 0.81 | 1.89 |
| max DD | 32.6 % | 22.0 % | 11.2 % |

**Positive every year** (+31 % to +88 %/yr), across a bull year, a mixed year, and the recent stretch — not one-regime luck.

## Verdict — a real trading edge, with real drawdowns

Cross-sectional momentum is the **strongest, most robust result of the whole effort**: **~40 %/yr at a realistic 60 bps, positive every year, breakeven cost ~280 bps, Sharpe ~0.9.** It is genuine **active trading** (weekly long-short rotation), and it survives the scrutiny that killed everything directional. The **price is drawdown**: max DD **30–35 %** — an order of magnitude worse than the carry yield (0.3 %). This is trading return for trading risk: high return, scary equity-curve dips, requires position sizing and the stomach for −30 %.

## Honest caveats

- **Drawdown is the binding risk**: 30–35 % peak-to-trough. Sizing must assume it; the headline % is on the gross long-short book.
- **Survivorship / executability**: the 18-symbol universe is today's liquid set; some (ARB/OP/SUI/TIA) were thin/new early in the span — weekly rotation of a long-short book on thin alts has slippage the 60 bps may under-state (cf. #1180/#1184). The biggest per-year number (2026 H1 +88 %) leans on fewer, more recent names.
- **One backtest, ~130 weekly rebalances**: walk-forward (selection on past, return forward) so it is OOS, but a single 2.5-y path; crypto factor edges decay as they get crowded.
- **Shorting**: done via perp shorts (easy, liquid); the short leg's funding is a small ignored tailwind (conservative). Real borrow/liquidation on a leveraged book adds tail risk (cf. #1188).
- Daily-close execution assumed; real fills differ.

## Next

Same gates the carry got: a **walk-forward across more sub-periods + a cost/turnover-vs-rebalance-frequency sweep** (weekly may not be optimal), **drawdown-aware sizing**, then a **paper-trade** on the live feed (the carry-paper.py pattern, adapted to long-short) before any real size. This is the trading strategy to develop.

Reproduce: `run-meta.json` (daily klines fetched live; not committed).
