# Carry robustness across regimes (#1175)

Does the funding-carry edge hold **out-of-sample across market regimes**, or is the ~1–3 %/yr from the single calm 2026 window (#1174) a one-window artifact? Walk-forward deterministic carry (top-6 basket, 30-day rebalance, 21-day trailing selection, 20 bps cost) over **2.5 years** (2024-01 → 2026-06, 18 alts, 51 357 funding events), per half-year + full span.

## Result — the edge holds in every regime

| Window | Carry OOS (annualised) | Sharpe | max DD | naive all-alts | cost drag |
|---|---|---|---|---|---|
| 2024 H1 (bull / high funding) | **+20.44 %/yr** | 3.60 | 0.00 % | +17.63 % | 0.40 % |
| 2024 H2 | **+7.50 %/yr** | 3.44 | 0.00 % | +5.91 % | 0.80 % |
| 2025 H1 | **+2.55 %/yr** | 5.69 | 0.00 % | +1.14 % | 0.47 % |
| 2025 H2 | **+3.71 %/yr** | 5.26 | 0.00 % | +0.81 % | 0.60 % |
| 2026 H1 (calm) | **+0.19 %/yr** | 0.45 | 0.09 % | **−1.82 %** | 0.52 % |
| **FULL 2.5 y** | **+7.11 %/yr** | **2.33** | **0.32 %** | +4.89 % | 2.98 % |

## Findings

1. **Positive in every half-year — never negative.** The persistent-positive-funding basket carry stayed positive across all five regimes (+0.19 % to +20.44 %/yr). The edge is **not a one-window artifact**: the full-2.5y OOS carry is **+7.11 %/yr at Sharpe 2.33, max drawdown 0.32 %** — a genuinely good risk-adjusted return (low-variance funding accrual, not a price bet).
2. **Strongly regime-amplified.** Big in high-funding bull periods (2024 H1 **+20 %/yr**), thin in calm ones (2026 H1 +0.19 %). Carry is a *baseline + bull-amplified* income, exactly as Phase 1 predicted; the single calm 2026 window understated it ~6×.
3. **The trailing-funding filter protects in weak regimes.** The top-6 selection beats naive always-on-all-alts in **every** window — decisively when it matters: in 2026 H1 the filter is **+0.19 %** while all-alts is **−1.82 %** (the filter drops symbols whose funding turned negative and rotates to cash). Selection adds the most value precisely when the regime is hostile.

## Honest caveats

- The backtest models **funding accrual − turnover cost only**. It does NOT model delta-neutral execution risk (basis dislocation, short-leg liquidation/margin, spot custody, rebalance slippage). **Real net is lower** — and during a violent regime transition (funding flips hard negative + basis blows out), a delta-neutral book can take a real hit the funding-only model doesn't see. The 2.5y Sharpe 2.33 is an upper-ish bound.
- Sub-window "0.00 % max DD" is degenerate (few rebalance periods inside a half-year); the **full-span** DD 0.32 % / Sharpe 2.33 are the meaningful figures.
- 30-day rebalance cost (~1.2 %/yr over the full span) is a real drag the carry exceeds; tighter rebalancing would lose (Phase 1 #1174).
- Survivorship: the 18-symbol universe is today's liquid set; some weren't liquid early in 2024.

## Verdict

The funding-carry edge is **robust across regimes** — positive every half-year, **+7.11 %/yr / Sharpe 2.33** over 2.5 years, with the trailing filter protecting against negative-funding drift. This is a real, deployable mechanical edge (modulo unmodelled execution risk), strongly amplified in high-funding bull regimes. It is **the first strategy in this whole effort with a robust, multi-regime, positive-expectancy out-of-sample record** — unlike every directional approach (which had no edge and evolved to FLAT). Next: model real delta-neutral execution + a paper-trading harness (operationalise), and/or the M3 substrate carry-strategist to sharpen selection.

Reproduce: `run-meta.json` (funding data gitignored).
