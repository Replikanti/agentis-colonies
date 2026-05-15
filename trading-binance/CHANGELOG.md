# Changelog — trading-binance

All notable changes to the `trading-binance/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `trading-binance-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added

- Five tribe colonies under `tribe-{alpha,beta,gamma,delta,epsilon}/`,
  each shipping a `strategist.ag` agent encoding one Ludvik Turek style
  trading setup (volume profile / fibonacci retracement / market
  structure / price action / mean reversion). Mirrors the
  `tribes-bench/tribe-*/` pattern adapted for trading-domain decisions
  (LONG / SHORT / FLAT) and PnL settlement (#573 PR-4).
- `tools/verify-trade.sh` deterministic PnL verifier with realistic
  slippage + funding-cost subtraction; no LLM in the verifier path.
  Mirrors the shell + embedded-Python pattern of
  `tribes-bench/tools/verify-finding-stage2.sh` (#573 PR-4).
- `tools/test-verify-trade.sh` 13-assertion test suite covering LONG /
  SHORT / FLAT directionality, slippage + funding subtraction,
  size-scaling, zero-volume entry candles, and edge cases (overflow,
  missing file, malformed decision JSON) (#573 PR-4).

### Changed

- `tools/run-replay.sh` orchestrator: bootstrap script now spawns one
  source `strategist.ag` daemon per tribe (5 total) and threads
  `VERIFIER_PATH`, `CANDLES_CSV`, `HOLD_PERIOD`, `TRADE_LEDGER`,
  `TRIBE_NAME` into the per-tribe daemon env. The candle CSV produced by
  `load-candles.py` is now mirrored into the container's bind-mounted
  `/run-root/candles.csv` so the verifier resolves it without
  host-path translation (#573 PR-4).

### Deprecated

### Removed

- Placeholder `market/` colony from PR-1. Replaced by the five tribe
  colonies described above (#573 PR-4).

### Fixed

### Security

## [0.1.0] — 2026-05-15

Initial scaffold via `tools/new-federation.sh`. Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.4.1

### Added

- One starter colony: `market/` with placeholder agent slot.
- ADR-0003-compliant `scripts/start-colony.sh` (supports
  `--restart-agent`, `--rate-limit-status`, exit 2 on unknown flag).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/trading-binance-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/trading-binance-v0.1.0
