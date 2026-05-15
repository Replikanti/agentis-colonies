# Trading Binance

![Version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue) ![Status: Alpha](https://img.shields.io/badge/status-alpha-orange)

**Version:** `0.1.0` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.4.1`

> One-paragraph description of what real-world workflow this federation
> learns. Replace this stub with the federation's domain identity (the
> top-level `README.md` and `doc/federation-patterns.md` cross-link to
> this paragraph).

This federation was scaffolded via
[`tools/new-federation.sh`](../tools/new-federation.sh) and conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md). See
[`doc/federation-patterns.md`](../doc/federation-patterns.md) for example
federation shapes.

## Colonies

| Colony | Description | Agents |
|--------|-------------|--------|
| [market](./market/) | <!-- TODO: describe what this colony does --> | 0 |

## Quickstart

```bash
./install.sh             # interactive setup
./market/scripts/start-colony.sh
```

## Tier contract

Every agent in this federation gates its behaviour on the four-tier
confidence ladder defined in
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md):

- `shadow` — observe + memo, no emit, no external write
- `propose` — emit on bus + draft external writes
- `review-gated` — direct external writes (non-terminal)
- `autonomous` — terminal external writes (merge, tag, ack alert, post reply, …)
