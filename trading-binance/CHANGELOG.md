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

- Sixth tribe colony `tribe-zeta/` shipping a `strategist.ag` agent that encodes Dr. David Paul's volume-divergence **fade** setup: SHORT an unconfirmed new local high (volume <= volumeMA(20)), LONG an unconfirmed new local low, FLAT when volume confirms the move. Mirrors the `tribe-alpha/` structure exactly (M98 v3 prompt evolution, M106 hash-pointer inheritance, M2-Malthusian replicate, tier-gated settlement via the shared verifier); `setup` is `"volume_divergence"`. Self-contained and inert — not yet wired into `tools/run-replay.sh` or `BUNDLE.manifest` (#1121, follow-ups #1122/#1123).
- `tools/run-ab-experiment.sh` A/B emergence experiment harness:
  runs N paired replicates x 2 arms (control =
  `REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999` / evolution off,
  treatment = `=3` / evolution on) against
  `tools/run-replay.sh`, writes a per-experiment
  `experiment-manifest.json` mapping every run dir to its arm, then
  invokes the analyser. Knobs: `AB_N_REPLICATES`, `AB_SYMBOL`,
  `AB_TIMEFRAME`, `AB_START`, `AB_END`, `AB_SPEED`, `AB_DRY_RUN`
  (#573 PR-5).
- `tools/analyze-ab-results.py` stdlib analyser: walks the experiment
  dir, parses per-run `trade-ledger.jsonl` + `.agentis/experience/*.jsonl`
  + `.agentis/memo*.jsonl`, computes per-(arm, tribe) PnL bps, win
  rate, total trades, max drawdown, per-trade Sharpe, and two mutation
  surrogates (distinct prompt-body SHAs + `strategist_prompt_evolve`
  rewrite rows). Emits `comparison.md` with run -> arm header table,
  per-tribe arm-vs-arm tables, a federation aggregate, and the
  honest-caveats section. Refuses to emit when any run dir cannot be
  unambiguously mapped via `experiment-manifest.json` (#573 PR-5).
- `tools/test-run-ab-experiment.sh` 8-assertion dry-run smoke test
  covering `--help`, replicate count, per-arm threshold, dir naming,
  manifest path, analyser invocation, and unknown-flag exit code
  (#573 PR-5).
- `tools/test-analyze-ab-results.py` 6-case `unittest` suite covering
  PnL aggregation, win-rate FLAT exclusion, chronological max
  drawdown, mutation-rate control/treatment asymmetry, missing
  experience dir graceful, and run -> arm header table presence
  (#573 PR-5).
- `data/.gitkeep` placeholder: the Binance candle data tree is NOT
  committed (~tens of MB per symbol/timeframe). Operator must run
  `tools/binance-feed-download.py --symbol BTCUSDT --timeframe 1h
  --start <YYYY-MM-DD> --end <YYYY-MM-DD>` before invoking the A/B
  harness (#573 PR-5).
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
- `tools/run-replay.sh` env passthrough: now threads
  `STRATEGIST_PROMPT_EVOLUTION_THRESHOLD` (the A/B emergence
  experiment's primary lever) plus five forward-compat strategist
  knobs (`STRATEGIST_PROMPT_GEN_CAP`, `STRATEGIST_PROMPT_MAX_BYTES`,
  `STRATEGIST_PROMPT_LEVENSHTEIN_FLOOR`,
  `STRATEGIST_FITNESS_REWARD_WIN_PER_BPS`,
  `STRATEGIST_FITNESS_PENALTY_LOSS_PER_BPS`) into the per-tribe daemon
  env via `exec.env_passthrough` + the daemon-spawn `printf` block.
  Defaults match the strategist.ag in-agent defaults so existing
  PR-3 / PR-4 behaviour is preserved when the new knobs are unset
  (#573 PR-5).
- `tools/run-replay.sh` orchestrator now wires the sixth tribe `tribe-zeta` into the replay run — the copy-into-container, confidence-seed, and source `strategist.ag` daemon-spawn loops enumerate `alpha beta gamma delta epsilon zeta` (6 daemons, was 5). The new daemon inherits the identical per-tribe env (`TRIBE_NAME=tribe-zeta`, `VERIFIER_PATH`, `CANDLES_CSV`, `HOLD_PERIOD`, `TRADE_LEDGER`, plus the six `STRATEGIST_*` prompt-evolution/fitness knobs); the existing five tribes' spawn and env are byte-identical. `REPLAY_DAEMON_COUNT` default bumped 5 → 6. The A/B harness (`tools/run-ab-experiment.sh`) covers all six tribes automatically since it forwards to run-replay.sh. `tribe-zeta/` added to `BUNDLE.manifest`. (#1122)

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
