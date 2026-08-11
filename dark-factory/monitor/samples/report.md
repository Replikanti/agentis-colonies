# Monitor — sample periodic summary

> **Illustrative, NOT auto-generated.** The monitor colony has **no periodic-report
> generator** — this file is a hand-authored example of what an operator-side
> weekly rollup of the colony's delivered pages + heartbeats *could* look like, so
> the outreach material has a concrete artifact to show. It uses the same
> watcher / verdict / severity vocabulary the live agents emit (see
> [`alert.json`](./alert.json) and [`heartbeat.json`](./heartbeat.json)), over a
> generic example target. No real client, protocol, or endpoint is named.

**Target:** `ExampleVault` (`0x1111111111111111111111111111111111111111`)
**Window:** 7 days (illustrative)
**Watch-spec:** 1 invariant — `totalSupply() <= totalAssets()` (solvency, `rel = le`)

## Liveness

| Signal | Count | Notes |
|--------|-------|-------|
| Heartbeats delivered | 7 / 7 | daily `notifier` heartbeat (severity `low`, verdict `ok`) — no silent gap |
| Dead-man's-switch trips | 0 | no `liveness` meta-alert; the colony never went blind for `MONITOR_DEADMAN_WINDOW_S` |

Silence is meaningful: a missing heartbeat is itself a page, so 7/7 delivered is
the "still watching, all green" proof for the window.

## Pages delivered

| When (illustrative) | Watcher | Invariant / signal | Verdict | Severity | Delivered |
|---------------------|---------|--------------------|---------|----------|-----------|
| Day 3, 14:02 UTC | `invariant` | `totalSupply() <= totalAssets()` | `violated` | `high` | webhook (HTTP 2xx) |
| Day 3, 14:02 UTC | `invariant` | `totalSupply() <= totalAssets()` | `violated` | `high` | deduped (sink-side cooldown) |

- **1 distinct incident**, paged once and then suppressed by `notify.sh`'s
  sink-side dedup (same `severity|kind|verdict` signature within the cooldown) —
  one page, not a storm.
- **0 false pages** across the rest of the window (every other tick read `ok`).

## Verdict distribution (all ticks)

| Verdict | Share | Meaning |
|---------|-------|---------|
| `ok` | 99.9 % | invariant held comfortably |
| `violated` | < 0.1 % | the Day-3 solvency break |
| `margin` | 0 % | no thin-margin warnings configured this window |
| `no-read` | 0 % | RPC reachable throughout (no blind ticks) |

_Vocabulary note: `verdict` in {ok, violated, margin, no-read} and `severity` in
{low, warn, high} are exactly the tokens the `invariant-watcher` and `notifier`
agents emit — this summary only aggregates them; it invents no new fields._
