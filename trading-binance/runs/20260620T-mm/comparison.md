# Market-making feasibility — can a maker capture the intraday reversal edge? (#1205)

#1202 showed the intraday reversal edge is the liquidity **provider's**, not the taker's. This tests whether a simple symmetric market-maker is net-positive after maker fees + adverse selection. LINKUSDT, 3 days of aggTrades (~181k trades).

## ⚠️ Read first — the fill model is OPTIMISTIC

A resting quote here fills when a trade **touches** it, assuming **front-of-queue, no cancel latency, no partial-fill competition**. That OVERSTATES a real maker's fills. **A positive result is an UPPER BOUND; a negative result is decisive.** True MM fills are a queue-position-and-latency-dependent, adversely-selected subset that needs L2/L3 book data + latency modelling — not available here.

## Result — it hinges entirely on fair-value responsiveness

The maker quotes bid/ask around a fair value = trailing EMA of price. The EMA's responsiveness (`alpha`) is decisive:

| fair-value EMA `alpha` | configs positive | best PnL (3 d, $5k cap) |
|---|---|---|
| 0.02 (slow / lagging) | 6 / 18 | +$295 |
| 0.1 (medium) | 12 / 18 | +$409 |
| **0.3 (fast / responsive)** | **18 / 18** | +$370 |

- **A naive lagging-fair maker mostly LOSES** — at the slowest setting (alpha 0.02) only 6/18 configs are positive, and they are the *widest* spreads (15 bps) where the spread is fat enough to overcome adverse selection even with a stale fair; every tighter-spread lagging config is negative — the stale quotes get **run over** on every move (you keep buying as price falls) and adverse selection dominates the spread. This is the textbook naive-MM failure: a lagging fair forces you to quote wide to survive, which kills fill rate.
- **A responsive-fair maker is POSITIVE** (under the optimistic fill) across the board at `alpha=0.3`. With quotes that track price quickly, the spread earned exceeds the adverse selection. So the MM economics are **not impossible** — the spread CAN beat adverse selection, IF your fair value is good enough.
- Rebate helps but isn't required at `alpha=0.3` (positive even at 0 maker fee); a lagging fair can't be rescued by a rebate.

(The ROC figures the sweep prints — 700–1000 %/yr on the $5k capital — are an artifact of the tiny capital base **and** the optimistic fill; they are NOT a real expected return and are not quoted as one.)

## What this actually means — feasible in principle, an infrastructure race in practice

The positive result **moves the question, it does not settle it.** Under a perfect fill you capture the spread; in reality you get only the subset of touches where you **won the queue/latency race** — and you tend to win exactly when the flow is informed (adverse selection). Whether the real, adversely-selected fill subset is still net-positive depends on:

- **Fair-value quality** — a microprice / order-book-imbalance estimate (needs L2), not a trade-EMA.
- **Queue position + latency** — colocation, fast cancel/replace, to be near front-of-queue.
- **Inventory + risk control** under real fills.

None of these is a *signal* problem; they are **execution-infrastructure** problems. This backtest cannot validate the real edge because **the fill model is the entire game**, and the honest model needs data + latency we don't have.

## Verdict

Market-making is **not economically dead** (unlike the taker path #1202, and unlike a naive lagging-fair maker): a responsive-fair symmetric maker is net-positive **under an optimistic touch-fill**, so the spread can exceed adverse selection. **But realizing it is an HFT-grade latency/queue race against colocated market makers — a fundamentally different, infrastructure-heavy operation whose true edge this trade-tick backtest cannot validate.** For this effort, market-making is a **capability gate** (latency, L2/L3 data, colocation), not a signal we can confirm and deploy like the daily/weekly cross-sectional momentum (#1194/#1197). Honest recommendation: MM is a real but separate, infra-bound venture; the deployable, validated edge remains daily/weekly.

Single symbol, 3 days — a feasibility probe, not a strategy. Reproduce: `run-meta.json` (tick data fetched live; not committed).
