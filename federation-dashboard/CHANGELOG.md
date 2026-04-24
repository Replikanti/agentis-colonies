# Changelog

All notable changes to `federation-dashboard` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `/start` endpoint no longer SIGTERMs `start-federation.sh` (and its 21
  just-spawned agents) when the sidecar loop runs past 60s. Handler now
  detaches the subprocess with `start_new_session=True` and returns 202
  Accepted; operator polls `agentis daemon list` for actual state
  ([#286](https://github.com/Replikanti/agentis-colonies/issues/286)).

## [0.3.0] — 2026-04-24

### Added

- **Forge Rate Limits tile.** New card on the dashboard surfaces each
  colony's remaining forge API budget. Powered by a new collector step
  that loops over the federation's colonies and execs
  `<colony>/scripts/start-colony.sh --rate-limit-status`, parsing the
  JSON contract `{remaining, limit, reset_at}` shipped in
  `dev-apprenticeship` 1.0.0 (PR 7 of #256). Colours: green normally,
  yellow under 25 % budget, red under 10 %, orange "err" badge on
  transport failure (with the failure reason in the tooltip), neutral
  "—" when both fields are null (self-hosted GitLab without
  rate-limiting, or pre-#256 federations). The collector tolerates
  every per-colony failure mode (timeout, non-zero exit, malformed
  JSON) without aborting regen.

### Changed

- `federation-dashboard-collector.py` adds a `forge_rate_limits` key
  (object keyed by colony name) to its JSON output. The previous
  six top-level keys (`agents`, `experience_counts`, `events`,
  `confidence_changes`, `decisions`, `sidecar`) are unchanged.

### Compat floor

- Requires a federation that ships `start-colony.sh --rate-limit-status`
  in every colony. The next `dev-apprenticeship` release (`1.0.1`,
  with `.dashboard-version` bumped to `0.3.0` in lockstep) satisfies
  this. Federations on `dev-apprenticeship <= 1.0.0` will see the tile
  render an orange `err: exit 2` badge per colony (`start-colony.sh`
  exits 2 on the unknown flag) but the rest of the dashboard keeps
  working — pin `federation-dashboard` at `0.2.0` if a clean tile is
  required before upgrading.

## [0.2.0] — 2026-04-23

### Fixed

- `start-colony.sh --restart-agent` now detaches the backgrounded daemon's
  stdio from any inherited pipes (`</dev/null >/dev/null 2>&1`). Without
  this, the dashboard's `subprocess.run(capture_output=True, timeout=15)`
  kept the capture pipes open after the script exited, causing every
  `/restart` to block 15s and report spurious "restart failed". Regression
  test added in `tools/test-start-colony-restart.sh` (Python subprocess
  variant).

### Changed

- Dashboard no longer parses `[gitlab]` from `<colony>/config/colony.toml`
  or composes `GITLAB_*` environment. Restart delegates to each colony's
  `scripts/start-colony.sh --restart-agent <name>`, which owns the
  forge-specific env wiring itself. Decoupling work for
  [#257](https://github.com/Replikanti/agentis-colonies/issues/257).
- `/restart` and `/confidence`-triggered respawns now call
  `start-colony.sh --restart-agent`; the dashboard no longer invokes
  `agentis daemon` directly.
- `build_manual_command()` emits a one-line `start-colony.sh
  --restart-agent <name>` paste instead of a `cd + env + agentis daemon`
  incantation.
- Autonomous-tier promote dialog (`setConfidence`) drops the
  GitLab-specific "merging MRs" language for federation-agnostic
  "merging changes, tagging releases, publishing artifacts".

### Removed

- `parse_toml_section()` and `resolve_tick_interval()` helpers in
  `federation-dashboard-server.py` — orphan after the restart
  delegation. `resolve-tick-interval.py` is still used by
  `tools/auto-promote.sh`; only the dashboard's in-process copy went
  away.

### Compat floor

- Requires a federation that ships `start-colony.sh --restart-agent
  <name>` in every colony. The next `dev-apprenticeship` release (first
  tag containing the flag; `.dashboard-version` bumped to `0.2.0` in
  lockstep) satisfies this. Federations on `dev-apprenticeship <= 0.3.3`
  will see `/restart` return `start-colony.sh exit 2: unknown flag:
  --restart-agent` and should pin `federation-dashboard` at `0.1.0`
  until they upgrade.

## [0.1.0] — 2026-04-23

First release as a standalone component. Code extracted from
`dev-apprenticeship` 0.3.2 ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)).

For history prior to extraction, see
`git log -- tools/federation-dashboard*`.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.3.0...HEAD
[0.3.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.2.0...federation-dashboard-v0.3.0
[0.2.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/federation-dashboard-v0.2.0
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/federation-dashboard-v0.1.0
