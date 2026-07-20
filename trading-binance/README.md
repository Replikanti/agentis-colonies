# Trading Binance

![Version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue) ![Status: Alpha](https://img.shields.io/badge/status-alpha-orange)

**Version:** `0.1.0` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.4.1`

Federation that hunts profitable USDT-M perpetual-futures trade setups
on Binance via six competing tribe colonies, each encoding a
different Ludvik Turek style trading hypothesis (volume profile /
fibonacci retracement / market structure / price action / mean
reversion / volume-divergence fade). Strategy decisions settle through a deterministic PnL
verifier (`tools/verify-trade.sh`) — no LLM in the verifier path — and
feed back into per-tribe fitness, M98 v3 prompt evolution, and the
M2-Malthusian replicate gate borrowed from `tribes-bench/`.

This federation was scaffolded via
[`tools/new-federation.sh`](../tools/new-federation.sh) and conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md). See
[`doc/federation-patterns.md`](../doc/federation-patterns.md) for example
federation shapes.

## Colonies

| Colony | Description | Agents |
|--------|-------------|--------|
| [tribe-alpha](./tribe-alpha/) | Volume profile (POC / VAH / VAL) | 1 |
| [tribe-beta](./tribe-beta/) | Fibonacci retracement (38.2 / 50 / 61.8) | 1 |
| [tribe-gamma](./tribe-gamma/) | Market structure (BOS / CHoCH) | 1 |
| [tribe-delta](./tribe-delta/) | Price action (engulfings / pin bars / momentum) | 1 |
| [tribe-epsilon](./tribe-epsilon/) | Mean reversion (50-bar median, 2-stddev band) | 1 |
| [tribe-zeta](./tribe-zeta/) | Volume-divergence fade (unconfirmed new high/low vs volumeMA(20)) | 1 |

## Quickstart

```bash
./install.sh                                  # interactive setup
python3 tools/binance-feed-download.py --help # PR-2: download historical klines
bash tools/run-replay.sh --dry-run            # PR-3: orchestrator dry-run
bash tools/run-replay.sh                      # real run — spawns 6 tribes in podman
```

## Tier contract

Every agent in this federation gates its behaviour on the four-tier
confidence ladder defined in
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md):

- `shadow` — observe + memo, no emit, no external write
- `propose` — emit on bus + draft external writes
- `review-gated` — direct external writes (non-terminal)
- `autonomous` — terminal external writes (merge, tag, ack alert, post reply, …)

## Environmental invariants

This federation adopted [ADR-0009](../doc/adr/ADR-0009-environmental-invariants.md)'s
optional invariants surface: two content-addressed `forbidden_callee`
modules under [`config/invariants/`](./config/invariants/) that state
the "backtest-only" law as an auditable predicate rather than an
implicit assumption:

- `no-order-placement.inv` — denies `place_order` / `cancel_order` /
  `submit_order` / `new_order`.
- `no-network-egress.inv` — denies `http_get` / `http_post` /
  `use_tool` / `smtp_send`.

`tools/run-replay.sh` stages the module set and emits
`evolution.invariants_dir` into the hermetic `.agentis/config` (gated
by `REPLAY_INVARIANTS`, default on; `=0` leaves the key entirely
unset). Requires agentis **>= v1.25.0** (the `forbidden_callee`
source-shape payload).

**Be precise about what this gates.** This is a **CLI-forensic,
observe-only** surface — `agentis invariant check` is run as a
host-side probe (recorded into `run-meta.json`'s `invariant_set_hash`),
not as a live daemon gate. `trading-binance`'s `replicate()` growth
happens entirely inside the daemon with no external pre-spawn
checkpoint to hook, so adopting this surface does **not** gate live
daemon admission for this federation (contrast `tribes-bench`, which
wires the same core surface into real replicate-admission + self-cull).
