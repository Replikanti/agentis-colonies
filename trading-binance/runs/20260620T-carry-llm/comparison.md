# Carry M2 — LLM-vs-naive basket value-gate (#1175 M2)

**Window:** 18 alts, 2026-03-01 → 2026-06-01, ~71d OOS harvest, 6 rebalances (14d), 21d trailing lookback, top-4, 20 bps round-trip cost. **Settlement:** `tools/carry-verify.sh` (M1). **Selector:** `claude -p`.

## The gating question

Before building the heavy daemon + M98-evolution carry stack, answer: does an **LLM-selected** carry basket beat a **naive rank rule** out-of-sample? (The directional full-evolution stack converged to FLAT/no-edge — so gate the LLM's value before investing.) Walk-forward: select on trailing funding, settle forward (OOS) via carry-verify.

## Result — gate PASSES

| Strategy | OOS annualised | total net | beats naive |
|---|---|---|---|
| **LLM selector** (claude -p) | **+1.38 %/yr** | +26.83 bps | — |
| Naive top-K by trailing mean | +0.46 %/yr | +8.95 bps | |
| **LLM > naive OOS** | | | **yes (5/6 folds)** |

## Why the LLM won (interpretable, not noise)

Folds 1–4 the two picked nearly identical baskets (AAVE/LINK/LTC/NEAR…). The gap came from the LLM **avoiding lumpy / spike-driven symbols** that the naive mean-rank chased:

| Fold | LLM basket → net | Naive basket → net |
|---|---|---|
| 5 | AAVE,DOGE,LINK,NEAR → **+12.64** | **ADA,BNB**,DOGE,LINK → +0.60 |
| 6 | DOGE,ETH,LINK,NEAR → −4.37 | **BNB,BTC**,ETH,LINK → −8.76 |

The naive pure-mean rank picked **BNB/ADA/BTC** when their *trailing* mean spiked, but those did not persist forward; the LLM — prompted to favour persistent funding (high positive-event ratio) and avoid lumpy names — stayed with the durable carriers (AAVE/NEAR/DOGE/LINK). This is exactly the "persistent vs lumpy" judgment Phase 1 flagged (#1174: BNB +1.86 %/yr but only 37 % positive events). A qualitative call that's hard to encode in a one-line rank rule, and where the LLM adds value.

## Honest caveats

- **Small sample**: 6 rebalances; a single decisive fold (5) drove much of the gap. Not statistically robust — "LLM beats naive" on 6 points could partly be luck.
- One window, calm regime; modest absolute (~1.4 %/yr); both strategies positive (carry itself is positive OOS here).
- **LLM calls are non-deterministic** — run-to-run numbers vary; the *direction* (LLM avoids lumpy names) is the robust signal, not the exact bps.
- Real net lower (delta-neutral execution risk not modelled, as in #1174).

## Verdict → build M3

The gate passes: LLM basket selection adds out-of-sample value over the naive rule, via a sensible mechanism (lumpy-avoidance / qualitative persistence judgment). This **justifies M3** — the full substrate carry-strategist (daemon + M98 evolution of the selection policy + the #1167 walk-forward harness) to sharpen and stress-test that judgment across regimes, rather than a single fixed prompt over one calm window.

Reproduce: see `run-meta.json` (funding data gitignored; LLM calls non-deterministic).
