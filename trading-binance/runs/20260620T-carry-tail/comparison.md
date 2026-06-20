# Carry tail-risk — does one event wipe the year? (#1188)

The carry backtests model funding accrual − cost only. They cannot see the tails that wipe a delta-neutral book in one event. Measured over **2.5 years** (2024-01 → 2026-06, daily) for the persistent-positive carry basket (LINK/AVAX/DOGE/SUI/NEAR/AAVE/ARB), using perp + spot klines + funding.

## The three tails

| Symbol | max basis (perp−spot) | worst adverse up-day | max safe leverage | worst sustained −funding run |
|---|---|---|---|---|
| LINKUSDT | +0.18 % / −0.20 % | +42.2 % | 2.4× | −15 bps |
| AVAXUSDT | +0.21 % / −0.35 % | +21.8 % | 4.6× | **−84 bps** |
| DOGEUSDT | +0.20 % / −0.19 % | +36.1 % | 2.8× | −13 bps |
| SUIUSDT | +0.17 % / −0.31 % | +39.9 % | 2.5× | −47 bps |
| NEARUSDT | +0.16 % / −0.22 % | +41.5 % | 2.4× | −21 bps |
| AAVEUSDT | +0.21 % / −0.23 % | +30.0 % | 3.3× | −16 bps |
| ARBUSDT | +0.19 % / −0.25 % | +31.3 % | 3.2× | −12 bps |
| **basket** | **worst 0.35 %, mean 0.25 %** | up to +42 % | **min 2.4×** | worst −84, mean −30 bps |

## Findings

1. **Basis blowout — negligible.** The perp–spot basis never widened beyond ~**0.35 %** over 2.5 years *including* every crash and squeeze — these are liquid alts with a tight perp/spot peg. A forced unwind at the worst basis costs ~0.2–0.35 %.
2. **Funding sign-flip — small.** The worst sustained negative-funding run was **−84 bps** (AVAX), mean ~−30 bps. A slow-rotating book pays ~0.3–0.8 % through a regime flip before the trailing filter rotates to cash.
3. **Leverage is the killer.** The worst adverse up-day was **+22 % to +42 %**. Any short-leg leverage above ~**2.4×** would have been **liquidated** at least once in 2.5 years. Fully-funded (1:1, unlevered) there is no liquidation and the directional move cancels.

## Verdict — the tail does NOT wipe the year, *if run unlevered*

- **Fully-funded 1:1 (no leverage): the residual tail is ~0.55 % (mean), ~1.2 % (worst symbol)** — basis (~0.25 %) + funding-flip (~0.30 %). Against ~5 %/yr carry that is **~6 weeks (mean) to ~3 months (worst) of carry — not a year-wiper.** The ~5 %/yr carry **survives the observed tail comfortably**, because the basis is tight and the funding-flip cost is small relative to a year of accrual.
- **The binding constraint is leverage.** The +22–42 % adverse spikes mean the short leg **must be unlevered** (≤ ~2.4× is the empirical liquidation floor, and that's cutting it fine). Unlevered means **full capital on both legs** (the ~5 %/yr is on 100 % capital, not amplified) — no capital efficiency, but a benign tail.

## Remaining real-world unknowns (NOT in this analysis)

- **Execution slippage** on the thinner alts (SUI/ARB/NEAR) at entry/exit — the cost-realism study (#1184) used 40 bps; thin-alt reality is the 80–150 bps end, which is where the survivorship caveat (#1180) bites.
- Exchange/custody/counterparty risk (holding spot + a short perp on a venue).
- This is daily-bar data; an intraday flash-squeeze + liquidation cascade can be worse than the daily high captures.

## Conclusion

The tail-risk gate **passes for an unlevered, fully-funded delta-neutral carry**: no single basis/funding event in 2.5 years would have wiped more than ~3 months of carry, and the basis peg held tight even through crashes. The ~5 %/yr (regime-gated, liquid-name) carry is a **real, deployable, modest yield** — provided it is run **unlevered** and the operator accepts the capital-intensity. The honest next gate is no longer analysis but a **paper-trade on the live funding feed** (to measure real entry slippage + the operational reality), then tiny real size.

Reproduce: `run-meta.json` (price/funding data gitignored).
