# Changelog — math-foundry

All notable changes to the `math-foundry/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `math-foundry-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [0.1.1] — 2026-05-18

Merged into `research-foundry/`. See `research-foundry/CHANGELOG.md` (#638).

## [Unreleased]

### Added

- Five colonies wired end-to-end for compute-first novelty discovery
  (#592): `explorer/`, `noticer/`, `formulator/`, `verifier/`,
  `novelty/`. Each ships one `.ag` agent with the standard ADR-0001
  tier-branch shape; the explorer additionally implements M98 v3
  prompt evolution + M2-Malthusian replication mirroring the
  `trading-binance/tribe-alpha/agents/strategist.ag` pattern.
- `tools/run-foundry.sh` orchestrator with the standard hermetic
  config block (experience.enabled, telemetry.enabled,
  daemon.cb_per_tick=2000 per trading-binance #579,
  daemon.heartbeat_interval_ms=1800000 per #583, pii_transmit=allow
  per #581, memo.max_keys=50000 per #587, llm.openai.*) and
  `--replace` podman idiom per #585. Topic + paper-pair rotation
  loop seeds memo keys (`replay:current_tick`,
  `replay:current_topic`, `replay:current_paper_a/b_*`) consumed
  by `explorer.ag`.
- `tools/Containerfile.foundry` base image: agentis + Python +
  sympy + numpy + networkx, claude CLI for optional claude-backend
  use.
- `tools/fetch-papers.py` one-time arxiv corpus bootstrap helper
  (uses the `arxiv` Python package; emits per-topic JSON files
  matching the corpus schema consumed by the orchestrator).
- `tools/test-run-foundry.sh` -- 23 dry-run smoke assertions.
- `tools/test-fetch-papers.py` -- 6 unittest assertions with
  synthetic arxiv fixtures.
- `data/papers/README.md` -- corpus layout + populate-from-arxiv
  instructions.
- [ADR-0008](../doc/adr/ADR-0008-compute-first-novelty.md) -- codifies
  compute-first novelty as the canonical pattern for novelty-
  requiring Agentis federations. Status: Proposed.

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.0] — 2026-05-16

Initial scaffold via `tools/new-federation.sh`. Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.4.1

### Added

- One starter colony: `explorer/` with placeholder agent slot.
- ADR-0003-compliant `scripts/start-colony.sh` (supports
  `--restart-agent`, `--rate-limit-status`, exit 2 on unknown flag).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/math-foundry-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/math-foundry-v0.1.0
