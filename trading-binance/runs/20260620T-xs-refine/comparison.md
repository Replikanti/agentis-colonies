# Cross-sectional momentum — sweep + drawdown-aware sizing (#1197)

Refining the trading edge from #1194 (~+43 %/yr @60 bps, but **max DD 30–35 %**). Two questions: is weekly/top-4 the best config, and can the scary drawdown be tamed by sizing? 18 alts, 2024-01 → 2026-06, daily klines, 60 bps, walk-forward, momentum.

## 1. Config sweep (rebalance × top-K × lookback), ranked by sized Sharpe

| reb | K | lookback | RAW ann | RAW Sharpe | RAW vol | RAW DD | SIZED ann | SIZED Sharpe | SIZED DD | turnover |
|---|---|---|---|---|---|---|---|---|---|---|
| **7 d** | **4** | **30 d** | +43.0 % | 0.93 | 47 % | 32.6 % | **+19.5 %** | **0.81** | **18.0 %** | 0.36 |
| 7 d | 4 | 14 d | +41.2 % | 0.84 | 49 % | 51.4 % | +23.6 % | 0.79 | 30.9 % | 0.52 |
| 14 d | 4 | 14 d | +44.7 % | 0.82 | 55 % | 43.8 % | +29.0 % | 0.69 | 28.2 % | 0.71 |
| 7 d | 6 | 30 d | +34.3 % | 0.82 | 42 % | 26.8 % | +14.9 % | 0.60 | 16.7 % | 0.30 |
| 7 d | 3 | 30 d | +56.6 % | 0.98 | 58 % | 45.4 % | +14.8 % | 0.56 | 21.2 % | 0.42 |

(18 configs swept; bottom ones — 3-day rebalance, K=6, 14-day lookback — degrade to single-digit or negative sized return on turnover + dilution.)

**The original #1194 config (weekly / top-4 / 30-day) is the best risk-adjusted choice** — confirmed as the sweet spot, not a lucky first pick. Higher frequency (3-day) burns turnover; wider K (6) dilutes the signal; shorter lookback (14-day) raises DD. The raw +56.6 % (7d/K3/30d) is tempting but rides 58 % vol / 45 % DD and a thin 3-name book — its sized return collapses to +14.8 %.

## 2. Drawdown-aware sizing (trailing-vol target 20 %, 3× cap, no look-ahead)

For the best config (7d / K4 / 30d):

| | RAW gross book | SIZED to 20 % vol |
|---|---|---|
| annualised | +43.0 % | **+19.5 %** |
| Sharpe | 0.93 | 0.81 |
| annualised vol | 47 % | 24 % |
| max drawdown | 32.6 % | **18.0 %** |

The headline +43 %/yr is **high-octane** — 47 % annualised vol, un-sizable for most. Vol-targeting deleverages it (the raw vol is ~2.3× the 20 % target, so exposure scales to ~0.4×): the deployable profile is **~+20 %/yr at ~18 % max DD, Sharpe ~0.8.** Return is a **dial** — set a higher target vol for more return and proportionally more drawdown.

## Verdict

The refinement sharpens the honest picture: the deployable cross-sectional-momentum strategy is **weekly / top-4 / 30-day lookback, vol-targeted to a chosen risk level — ~+20 %/yr at ~18 % max DD (Sharpe ~0.8) at a 20 % vol target.** Still an excellent active-trading return, now risk-controlled rather than the raw +43 %/33 %-DD high-octane number.

## Honest caveats

- **Sizing controls risk, it does not add alpha.** Sized Sharpe (0.81) is slightly *below* raw (0.93) — trailing-vol estimation lags, costing a little. Vol-targeting is a risk dial, not an edge.
- **The deployable number is ~half the headline.** ~20 %/yr (sized) vs +43 %/yr (raw) — the difference is the risk you choose not to take.
- All #1194 caveats still hold: single 2.5-y path, factor decay as it crowds, thin-alt slippage that 60 bps may under-state, daily-close execution.
- The 3× leverage cap matters: vol-targeting in calm stretches would otherwise demand more leverage (= liquidation risk, #1188); the cap binds rarely here but is a deliberate guard.

## Next

Long-short paper-trade harness (carry-paper.py pattern) on this config — periodic snapshot ranks trailing returns, picks the vol-targeted long-K/short-K book, settles the prior against realised forward, accumulates a live forward record before any real size.

Reproduce: `run-meta.json` (daily klines fetched live; not committed).
