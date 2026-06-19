# Directional walk-forward run — summary (#1167 harness)

**Run:** `wf-20260619T205055Z` · BTCUSDT 1h · backend claude-p (flat-rate).
**Folds:** fold-1 train 2026-03-01..03-05 → test 03-05..03-09; fold-2 train 03-09..03-13 → test 03-13..03-17 (fold-2 abandoned — see below).

## What this validated

The #1167/#1168 walk-forward harness ran **end-to-end on real flat-rate (claude-p)**: fold-1 completed the full chain — train (M98 evolution fired), **extract** each tribe's evolved prompt, **freeze + seed** it into the test run, **test** on unseen data, **score** OOS. The carry-forward + freeze mechanism works (all 6 tribes adopted their own frozen prompt; 0 parse errors throughout).

## Directional OOS result — no edge (as predicted)

**Fold-1 OOS (test 03-05..03-09): 0 directional trades, 0 expectancy.** The trade ledger was 314 FLAT / 1 SHORT — the evolved directional strategies **sit out** on unseen data. This is the same dynamic the #1166 single-window run showed: evolution, optimising on a train window where directional trades lose, converges the tribes toward **FLAT** (the rational response to a no-edge signal). Out-of-sample they correctly continue to not-trade → ~0 OOS exposure, 0 expectancy.

Fold-2 was **abandoned** (the run was killed after ~2.7h): fold-1 is conclusive, and three prior measurements (#1123 fade, #1154 momentum, #1166 6-tribe) already established that directional prediction of liquid BTC from public candles has no edge. Re-confirming via fold-2 added no information.

## Why this matters

This is the honest no-edge confirmation that **motivated the pivot to funding carry** (#1173/#1174/#1175), which DID find a real, positive-expectancy mechanical edge (~1.2–2.8 %/yr low-churn carry; the LLM basket selector beats a naive rank rule out-of-sample). The walk-forward harness built here is reused as the OOS gate for the carry strategy.

Raw ledgers/logs gitignored; reproducible via the #1167 harness with the documented fold spec.
