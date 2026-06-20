# Carry operationalisation — cost-realism sensitivity (#1183)

The robustness study (#1180) reported **+7.11 %/yr Sharpe 2.33** over 2.5 years — but used an **optimistic flat 20 bps** round-trip turnover cost. A real delta-neutral round-trip is **4 fills** (enter: buy spot + short perp; exit: sell spot + cover perp), each paying taker fee + spread, plus basis crossing. Realistic all-in: ~**40–60 bps** on liquid alts, **80–150 bps** on thin ones. Does the edge survive?

Net annualised carry (top-6 basket, 30-day rebalance) vs all-in round-trip cost:

| Window | 20 bps (ideal) | **40 bps** | **60 bps** | 80 bps | 100 bps | 120 bps |
|---|---|---|---|---|---|---|
| **FULL 2.5 y** | +7.11 % | **+5.88 %** | +4.64 % | +3.40 % | +2.16 % | +0.93 % |
| 2024 H1 (bull) | +20.44 % | +19.54 % | +18.63 % | +17.72 % | +16.82 % | +15.91 % |
| 2024 H2 | +7.50 % | +5.71 % | +3.92 % | +2.13 % | +0.34 % | −1.46 % |
| 2025 H1 | +2.55 % | +1.48 % | +0.42 % | −0.65 % | −1.71 % | −2.77 % |
| 2025 H2 | +3.71 % | +2.37 % | +1.02 % | −0.32 % | −1.66 % | −3.01 % |
| 2026 H1 (calm) | +0.19 % | **−1.07 %** | −2.34 % | −3.61 % | −4.87 % | −6.14 % |

## Findings

1. **In aggregate the edge survives realistic costs.** Full-span net at the realistic **40 bps is +5.88 %/yr**, at 60 bps +4.64 %/yr; breakeven only at ~140 bps. So a *blended* 2.5-year carry book clears real liquid-alt costs comfortably.
2. **High-funding (bull) regimes are cost-insensitive.** 2024 H1 stays **+15.9 %/yr even at 120 bps** — funding was so high the 4-fill cost barely dents it. When funding is hot, carry survives any realistic cost.
3. **Calm regimes die at low cost.** 2026 H1 (calm) is already **negative at 40 bps** (breakeven ~23 bps); 2025 H1 breaks even ~68 bps, 2025 H2 ~75 bps. The thin carry in quiet markets **cannot cover the 4-fill execution** — harvesting it then loses money.

## The operational consequence — carry is REGIME-GATED, not always-on

The aggregate +5.88 %/yr at 40 bps **blends** hot regimes (where carry is huge and cost-proof) with calm ones (where always-on harvesting loses). The right strategy is therefore **not** to run carry continuously, but to **gate on the funding regime**: deploy the delta-neutral basket only when expected forward carry clears the cost threshold (bull / elevated funding), and sit in **cash** when funding is calm (don't pay ~40 bps to harvest ~19 bps). A regime-gated book would *beat* the always-on +5.88 % by cutting the calm-regime losses.

This is exactly the job an LLM / evolved carry-strategist (M2 #1178 / M3) is suited to: M2 already showed the LLM avoids lumpy symbols out-of-sample; a regime-aware version would also avoid *deploying at all* when funding is too thin to clear costs.

## Honest net, deployable

- **Realistic blended net: ~5–6 %/yr at 40 bps** over the full 2.5 y — but lumpy: most of it earned in a few high-funding stretches, ~cash-to-negative in calm ones.
- **Regime-gated** (cash in calm) would lift the realised net by removing the calm-regime drag.
- Still excludes the tail (short-leg liquidation / basis blowout during violent moves) and the survivorship/executability caveat (#1180: the biggest numbers ride on the thinnest alts, where real costs are at the 80–150 bps end, not 40).

## Verdict

The funding-carry edge **survives realistic costs in aggregate (~5–6 %/yr at 40 bps) and decisively in high-funding regimes**, but **must be regime-gated** — harvested when funding is hot, parked in cash when calm. This is a real, deployable mechanical edge with a clear operational rule, not an always-on free lunch. Next: tail-risk (short-leg adverse-move stress from perp klines) and a regime-gated paper-trading harness on the live funding feed.

Reproduce: `run-meta.json` (funding data gitignored).
