# Changelog

All notable changes to `federation-dashboard` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Dashboard ships a full favicon set (ICO, multi-size PNG, Apple Touch icon,
  Android Chrome 192/512) and a PWA `site.webmanifest` branded for Agentis
  (`name="Agentis Federation Dashboard"`, `short_name="Agentis"`,
  `theme_color`/`background_color="#0a0a0a"`). The wrapper copies
  `assets/favicon/*` into `$DASH_DIR/` after `mkdir -p` so the static HTTP
  server picks them up at `/favicon.ico`, `/favicon-32x32.png`,
  `/apple-touch-icon.png`, `/android-chrome-{192,512}.png`, and
  `/site.webmanifest`. The HTML template references all six via `<link>` tags
  plus a `<meta name="theme-color">`. Browser tabs and installable PWA cards
  now show the Agentis mark instead of the generic globe
  ([#295](https://github.com/Replikanti/agentis-colonies/issues/295)).

### Fixed

- `tools/test-dashboard-fedpath.sh` no longer fails with `setsid: command
  not found` on stock macOS (Darwin), which does not ship `util-linux`.
  The three `setsid bash …` callsites that boot the dashboard for the
  fixture (cwd-aware, no-cwd, and the Case D mock-`agentis` path) now
  use a portable subshell-detach pattern (`( cd … && bash … >log 2>&1
  < /dev/null ) &`) instead. Cleanup trap already falls back to bare
  pid kills when the pgroup-kill fails, so the loss of the new session
  leader is benign. Linux runs stay green
  ([#273](https://github.com/Replikanti/agentis-colonies/issues/273)).
- Top-line "Agents Running" stat box no longer disagrees with per-agent
  rendering when the daemon registry contains zombie rows (`state=running`
  but the OS PID is gone). The summary counter previously read
  `agents.filter(a => a.state === 'running')`, while every per-agent row
  used `state === 'running' && pid > 0 && !pid_alive` to flag dead PIDs.
  When the federation hit the zombie pattern, the top said `21/21
  running` while every row below it rendered as DEAD. Collector now
  emits a derived `is_running` field (`state == 'running' AND
  pid_alive`) and the template's stats-row counter switches to
  `agents.filter(a => a.is_running)`, so the summary agrees with the
  effective per-agent state
  ([#300](https://github.com/Replikanti/agentis-colonies/issues/300)).
- Auto-promote sidecar card no longer reports false-positive `DEGRADED — silent NNNNm (interval 30m)` for the first 30 min after federation restart. Collector now reads `.agentis/logs/auto-promote.sidecar_started_at` (stamped by `start-federation.sh` at sidecar spawn) and emits `sidecar.in_startup_grace=true` while `now - started_at < interval_s + 120s`; the template's `sidecarSilent` predicate gates DEGRADED on `!in_startup_grace`. Federations on the pre-#274 `start-federation.sh` produce no timestamp file and behave exactly as before ([#274](https://github.com/Replikanti/agentis-colonies/issues/274)).
- Dashboard no longer renders every agent as `state=stopped` /
  `health=unknown` when the wrapper inherits a cwd outside the
  federation root (e.g. `systemd-run --user` defaults cwd to `$HOME`).
  `agentis daemon list --json` and `agentis remediation history`
  invocations are now wrapped in a `(cd "$FED_DIR" && agentis …)`
  subshell so `.agentis/` resolves correctly regardless of the
  wrapper's launch cwd. Operators who launched from the federation
  root were unaffected; everyone else saw a healthy 21-agent
  federation rendered as completely dead
  ([#288](https://github.com/Replikanti/agentis-colonies/issues/288)).
- Dashboard wrapper no longer crashes with `Argument list too long` after
  several hours of accumulated history. `$COLLECTOR_JSON`, `$HISTORY`,
  `$REMEDIATION`, and `$DAEMONS` now travel to the Python helpers via
  temp files (`@<path>` argv prefix) instead of inline argv strings, so
  they do not hit Linux's 128 KB `MAX_ARG_STRLEN` per-argv cap. Renderer
  and collector accept both forms (`@`-prefix reads the file, plain
  string passes through unchanged) — same class of failure as
  [#279](https://github.com/Replikanti/agentis-colonies/issues/279) but
  in a different code path
  ([#293](https://github.com/Replikanti/agentis-colonies/issues/293)).
- `/start` endpoint no longer SIGTERMs `start-federation.sh` (and its 21
  just-spawned agents) when the sidecar loop runs past 60s. Handler now
  detaches the subprocess with `start_new_session=True` and returns 202
  Accepted; operator polls `agentis daemon list` for actual state
  ([#286](https://github.com/Replikanti/agentis-colonies/issues/286)).
- `tools/colony-lint.sh` (the federation lint the dashboard's CI gate
  depends on transitively) no longer fails to parse on stock macOS
  bash 3.2 (`/bin/bash`). The inline `awk '...'` literal at line 179 is
  now sourced from `tools/colony-lint-flag-allowlist.awk` via `awk -f`,
  removing the multi-line single-quoted block that the bash 3.2 parser
  miscompiled near the case-statement at line 202. Same workaround
  pattern already applied to the `auto-promote.sh` family
  ([#245](https://github.com/Replikanti/agentis-colonies/issues/245))
  and the `federation-dashboard-*.py` family
  ([#172](https://github.com/Replikanti/agentis-colonies/issues/172)).
  New smoke harness `tools/test-colony-lint-bash32.sh` enforces
  ([#271](https://github.com/Replikanti/agentis-colonies/issues/271)).

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
