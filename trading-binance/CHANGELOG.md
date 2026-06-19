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

### Fixed

- The 6 replay strategists (`tribe-{alpha,beta,gamma,delta,epsilon,zeta}/agents/strategist.ag`)
  now append a strict JSON-only output directive (`_output_format_directive()`)
  at the `prompt() -> Decision` call site, OUTSIDE the evolvable prompt body so
  M98 prompt-evolution cannot drop it. On the flat-rate flat-cyborg path claude
  was writing verbose analysis prose before any JSON, so the Decision reply
  failed to parse with `unexpected character N`. The shared
  `tools/flat-cyborg-claude.sh` wrapper additionally post-processes JSON-shaped
  replies through `tools/flat-cyborg-unwrap.py`: when a reply is a single
  `{…}` object it collapses the soft-wrap whitespace that
  `--extract-structural`'s TUI screen-scrape injects INSIDE the JSON string
  (newline+indent from line-wrapping), so the JSON parses again; prose/code
  replies pass through byte-for-byte. `tools/test-flat-cyborg-claude.sh` covers
  the unwrap logic (#1163).
- `tools/run-replay.sh` container flat-cyborg path now bind-mounts the
  host-level `~/.claude.json` (onboarding/oauth state) into
  `/root/.claude.json` alongside the existing `~/.claude` dir, and routes
  through the `tools/flat-cyborg-claude.sh` wrapper
  (`flat-cyborg --extract --extract-structural -- claude`) under agentis's
  `claude` backend instead of the native bare-`--extract` `flat-cyborg`
  backend. Without the `.claude.json` mount the container `claude` sat on the
  login menu and never replied; the bare `--extract` intermittently timed out
  on a missing reply sentinel — together they produced zero-decision replay
  runs failing every tick with `flat-cyborg exited with exit status: 124:
  --extract found no fenced reply`. `tools/test-run-replay.sh` asserts the
  wrapper wiring + the `/root/.claude.json` mount on the flat-cyborg path and
  its absence on the openai path (#1161).
- `tools/run-replay.sh` now adds the `:z` SELinux relabel suffix to the
  `/repo` and `/run-root` bind mounts (the `~/.claude` mount already had it).
  Without it, on an SELinux-enforcing host (Fedora/RHEL) the `replay-laptop`
  container cannot read the bind-mounted `bootstrap.sh` / `candles.csv` and
  dies at boot with `Permission denied` (exit 126); the orchestrator then
  loops `can only create exec sessions on running containers`. `:z` is a
  no-op on SELinux-disabled hosts. `tools/test-run-replay.sh` asserts both
  mounts carry `:z` (#1159).

### Added

- Deterministic **momentum/breakout** backtest under the #1148 R-multiple
  exits over the real 90-day BTCUSDT 1h window (2026-03-01 → 2026-05-31),
  recorded under `runs/20260619T-momentum-rmultiple/`
  (`backtest-momentum-rmultiple.py`, `comparison.md`, `results.json`,
  `run-meta.json`). Tests whether asymmetric payoff (small stop, larger
  target) produces a positive expectancy where the #1123 fade lost.
  **Honest verdict: no — momentum + R-multiple loses worse than the fade**
  and worse as the target widens (1R/2R/3R: total −5252/−6443/−7090 bps,
  win rate < 44 %, profit factor < 1, expectancy negative); the wider target
  almost never hits (119 → 41 → 17 targets of 341), because most 1h BTCUSDT
  breakouts are false on this window. The R-multiple **lever is validated
  mechanically** (exit_reason stop/target/time distributes as the geometry
  predicts, funding over the actual hold) — but asymmetric payoff alone
  doesn't create an edge: both deterministic signals (fade AND momentum) lose
  on this window. Selection metric is expectancy + profit factor, not win
  rate. Single in-sample window; deterministic signal ≠ LLM strategist;
  no walk-forward (#1154).
- `tools/verify-trade.sh` optional R-multiple stop-loss / take-profit
  settlement via two new env knobs `STOP_BPS` / `TARGET_BPS` (both bps of
  the entry price, default `0` = disabled). When either is `> 0`, the
  verifier scans the forward candles intrabar (`low` / `high`) for the
  first stop / target touch and exits there; a same-candle tie resolves
  pessimistically to the stop; with no touch it falls back to the legacy
  fixed-time open exit. On this path funding accrues over the ACTUAL hold
  (exit candle − entry candle) and the verdict carries an additional
  `exit_reason` field (`"stop"` | `"target"` | `"time"`). **Fully
  backward-compatible**: with both knobs unset / `0` the behaviour AND
  output JSON are byte-identical to the prior fixed-time path (no
  `exit_reason` key) — `run-replay.sh` never sets these knobs, so the live
  settlement is unaffected. `tools/test-verify-trade.sh` grows from 13 to
  31 assertions covering stop-first, target-first, time-fallback,
  same-candle tie, SHORT mirror, funding-over-actual-hold, and a
  byte-identical disabled-path regression (#1148).
- Deterministic reference backtest of the `tribe-zeta` volume-divergence
  **fade** signal over a real 90-day BTCUSDT 1h window (2026-03-01 →
  2026-05-31), recorded under `runs/20260618T-fade-determ/`
  (`backtest-fade-signal.py`, `comparison.md`, `results.json`,
  `run-meta.json`). Decisions are settled by the repo's own ground-truth
  verifier (`tools/verify-trade.sh`). **Honest verdict: the mechanical fade
  signal has no edge on this window** — it loses at every lookback tested
  (20 / 50 / 100 bars: total −360 / −324 / −424 bps, win rate < 50 %,
  negative per-trade Sharpe) and beats neither FLAT (0 bps) nor buy-and-hold
  (+757 bps); the window trended up, so fading new highs is the wrong side of
  a trend. The full 6-tribe LLM replay (tribe-zeta vs the other five) is
  deferred — it needs `OPENROUTER_API_KEY` (the replay's `openai` backend
  hard-fails without it; the `claude`/`cli` backend is not yet wired into the
  replay container), so #1123 stays open for that step (#1123).
- `.gitignore` for the federation: downloaded market-data shards under
  `data/` are not committed (mounted at runtime / re-downloadable), keeping
  `data/.gitkeep` present.
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
- `tools/run-replay.sh` now defaults `REPLAY_LLM_BACKEND` to `flat-cyborg` (flat-rate Claude subscription via the flat-cyborg PTY wrapper) instead of `openai`, so the replay no longer requires `OPENROUTER_API_KEY` out of the box; on the flat-cyborg path the orchestrator bind-mounts the host `~/.claude` into the container at `/root/.claude:rw,z` (#535/#537 precedent; `:z` SELinux relabel for Fedora/RHEL); `Containerfile.replay` installs the flat-cyborg binary; the metered `openai` backend stays as an opt-in fallback (`REPLAY_LLM_BACKEND=openai`) which still injects `[llm.openai]` and still enforces the key; new knobs `REPLAY_FLAT_CYBORG_MODEL` / `REPLAY_FLAT_CYBORG_IDLE_MS` / `REPLAY_HOST_CLAUDE_DIR`; the 6 tribe colonies' `[llm]` backend flipped `cli` → `flat-cyborg`; note the `--extract` TUI screen-scrape fidelity caveat and flat-rate cost (usage=None); requires a flat-cyborg >= 0.9.0 binary with `--no-jitter` on PATH. (#1133, part of #1132)
- `tools/Containerfile.replay` bumps `ARG AGENTIS_VERSION` `v1.7.12` → `v1.19.0` — the
  agentis-core release that introduced the native `flat-cyborg` backend. The #1133 default
  (`llm.backend = flat-cyborg`) is a v1.19.0 feature; the prior pin would reject it at real
  container runtime (dry-run/CI never executes agentis, so it was latent). The `.sha256` is
  fetched from the same release tag, so the integrity check self-verifies. (#1141, part of #1132)

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
