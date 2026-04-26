# Changelog

All notable changes to `federation-dashboard` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Live tile updates via Server-Sent Events** — IIFE → `renderXxx(data)`
  refactor that closes [#313](https://github.com/Replikanti/agentis-colonies/issues/313)
  (PR 2 of 2). Combined with PR 1 (server-side `/events` plumbing,
  `ThreadingHTTPServer` upgrade, snapshot-watcher thread, atomic
  `snapshot.json` writer, browser `EventSource` consumer dispatching
  `agentis:snapshot` CustomEvents) the SSE story is complete: each regen
  tick the dashboard's tiles refresh in place without `location.reload()`,
  inside ~1s of the snapshot landing on disk. PR 2 converts the eleven
  data-driven IIFE renderers in `federation-dashboard.html.template` into
  named `renderXxx(data)` functions wired to `agentis:snapshot`: Federation
  Down / Federation Health banners, Stats Row, Agent Table, Phase Readiness,
  Forge Rate Limits, LLM Cost, Cost Cap, Promote Candidates, Event Timeline,
  Experience Growth, Confidence Trend. A new `rerender(snap)` entry point
  re-derives the data shorthands (`agents`, `events`, `decisions`,
  `sidecar`, `history`, `nowEpoch`) from the freshest snapshot via
  `extractRefs(snap)` and invokes every renderer in sequence; total
  per-snapshot wall-clock budget stays well below the 500ms target on
  typical federations. DOM-state preservation: the agent-table sort
  column + direction (`sortCol` / `sortDir`) survive across re-renders
  because the renderers read them rather than reset them; the open/closed
  state of the "Skipped candidates" `<details>` panel in Promote Candidates
  is captured before the rebuild and restored after; Event Timeline's
  `scrollTop` is preserved so a long inspection doesn't snap to the top
  mid-snapshot; the agent-detail modal is never touched by any renderer
  so it stays open across pushes (re-clicking still picks up fresh data
  because `openDetail()` reads `agents` lazily). The static `{{COLLECTOR_JSON}}`
  first-paint contract is unchanged — `curl /` still returns a fully
  rendered HTML page, and browsers without `EventSource` fall back to the
  existing 60s `meta http-equiv="refresh"` cadence. New tests in
  `tools/test-sse-stream.sh` (t6 / t7 / t8) assert the refactored shape:
  every renderer is present, the bootstrap is a single
  `rerender(window.__data)` call, and `tools/test-timeline-rendering.sh`
  stays green at 29 / 0 under the refactor.

- **Per-agent unified timeline modal section** — collector + UI plumbing
  ([#315](https://github.com/Replikanti/agentis-colonies/issues/315) PR 1 of 2).
  The agent-detail modal now ships a "Timeline (last 50)" section between
  "Recent Experience" and "LLM Cost" that merges four on-disk JSONL streams
  into a single chronological feed: experience entries (kind=learn), spend
  rows (kind=prompt), confidence-log entries (kind=confidence_change), and
  daemon lifecycle events (kind=lifecycle). The collector reads each source
  at most once per regen — lifecycle and confidence-log are bucketed by
  `agent_id` up-front so the per-agent slice is O(1) rather than re-reading
  the ~12k-line lifecycle file for every agent. All four sources tolerate
  missing files / malformed lines silently. Timestamps are normalized to
  epoch-ms regardless of source convention (experience writes seconds,
  spend writes ms, lifecycle writes seconds). Each row carries a
  `{ts, agent_id, kind, payload, severity}` envelope; `severity` escalates
  to `warning` on quarantine / restart / health-degradation lifecycle
  events and to `error` on `outcome=failure` learn rows or `ok=false`
  prompt rows. The renderer reuses the existing `timeline-entry` /
  `timeline-ts` / `timeline-type` CSS so colour cues match the
  federation-wide tile palette. PR 2 will land the federation-wide
  Timeline tile expansion + a `/timeline?since=<ts>` HTTP endpoint with
  pagination; this PR is additive and ships per-agent only.

- **Server-Sent Events (SSE) live snapshot stream** — server-side plumbing
  ([#313](https://github.com/Replikanti/agentis-colonies/issues/313) PR 1).
  The dashboard server now exposes `GET /events` (text/event-stream); each
  regen tick the wrapper writes the freshly-collected `COLLECTOR_JSON` to
  `<dash-dir>/snapshot.json` atomically (temp + rename). A daemon thread
  inside the server polls the snapshot file's mtime every 250ms and
  `notify_all()`s a `threading.Condition`; every connected `/events`
  handler then writes one `event: snapshot\ndata: <bytes>\n\n` frame.
  Idle keepalive (`: keepalive\n\n`) every 30s so proxies / browsers
  don't time the stream out. The HTTP server upgrades from
  `HTTPServer` to `ThreadingHTTPServer` so SSE handlers don't block
  the existing endpoints (`/refresh`, `/confidence`, `/restart`,
  `/quarantine`, `/evolve`, `/cleanup`, `/start`, `/kill`,
  `/cost-cap/override`). Each pushed payload carries an 8-char
  `__hash` field (server-side sha256 of canonical JSON) so the
  browser dedupes identical pushes. The HTML template ships a
  minimal `EventSource('/events')` consumer that re-emits each
  snapshot as a DOM `agentis:snapshot` CustomEvent — PR 2 (above)
  refactors the per-tile IIFE renderers into `renderXxx(data)`
  callbacks listening on this event to update the DOM in-place
  without `location.reload()`. Static first paint of `/` is
  unchanged; SSE is purely additive — older browsers without
  `EventSource` keep using the existing 60s background regen path.

## [0.5.0] — 2026-04-26

Cost Cap tile + Federation Health Banner cost-cap state, paired with the
`dev-apprenticeship/tools/cost-cap.sh` sidecar that landed in `dev-apprenticeship`
v1.2.0. The LLM Cost tile's status pill (a placeholder in v0.4.0) is now wired
live to the cost-cap sidecar's `status` field, so the two tiles render a
coherent picture: the cost tile shows where the federation has been (rolling
spend windows), and the cost-cap tile shows what the runtime guard is doing
about it (active / warning / downgraded / stopped). Federations that don't
install the cost-cap sidecar still render every other tile unchanged.

### Added

- Cost Cap tile + banner state, paired with the dev-apprenticeship `tools/cost-cap.sh` sidecar
  ([#318](https://github.com/Replikanti/agentis-colonies/issues/318)). Collector reads
  `<fed>/.agentis/cost-cap-banner.json` + `<fed>/.agentis/cost-cap-state.json` + the install file
  `<fed>/.cost-cap.toml`, exposes a `cost_cap` block in `COLLECTOR_JSON` with status, mode,
  per-cap progress percentages, slope multiplier (flat mode), and sidecar liveness fields.
  HTML template renders a mode-aware tile (metered: `$X.XX / $5.00` daily + monthly bars; flat:
  `234 / 1000 requests` daily/monthly/hourly bars + slope gauge with green/yellow/red bands)
  and a status pill (`active | warning | downgraded | stopped`). The LLM Cost tile's status pill
  (added in v0.4.0 as a placeholder for #318) is now wired live to the cost-cap
  sidecar's `status` field. The Federation Health Banner reuses its `.degraded` (warning) and
  new `.stopped` (breach) states for cost-cap, and renders a `⛔ Cost cap` label when the sidecar
  has tripped. New `POST /cost-cap/override` endpoint shells out to `tools/cost-cap.sh --override
  <reason>` (returns 503 when no shared `tools/` is available, mirroring the `/kill` precedent;
  returns 409 Conflict on sidecar lock contention instead of falsely reporting success — the
  sidecar exits 75 and the dashboard maps that to a retry hint).

### Compat floor

- Recommends `dev-apprenticeship` >= **1.2.0** (`tools/cost-cap.sh` sidecar + `<fed>/.cost-cap.toml` install + `agentis-core >= 1.4.7` for the `cost_usd` field the metered mode sums). Federations on `dev-apprenticeship <= 1.1.0` see the Cost Cap tile render `Cost cap not installed.` and the rest of the dashboard keeps working.

## [0.4.0] — 2026-04-26

LLM Cost tile (per-agent JSONL spend log readout, three rolling windows, 24h
sparkline, sortable agents column, per-agent modal section), full Agentis
favicon + PWA `site.webmanifest`, and a per-agent promote forecast on
Promote Candidates skipped rows. Plus a wave of correctness/observability
fixes: zombie-row stat-box reconciliation, Learning 24h delta honesty,
auto-promote startup grace, cwd-aware daemon listing, argv-too-long
breakage on long-running dashboards, `/start` endpoint detach, and
macOS bash 3.2 lint parse.

### Added

- **LLM Cost tile.** New card on the dashboard surfaces the federation's
  LLM-prompt spend across three rolling windows (today / 7d / 30d).
  Powered by a new collector step that walks
  `<agentis_root>/spend/<agent_id>.jsonl` (written by agentis-core
  v1.4.7 — see #311 PR A) and aggregates per-federation, per-colony, and
  per-agent. The tile renders three headline numbers, a 24×1h SVG
  sparkline, a per-colony breakdown reusing the Forge Rate Limits
  `rl-row` layout, and a placeholder status pill ("active" today; #318
  will wire active/warning/critical states once the cost-cap sidecar
  lands — shipped in v0.5.0). The Agents table gains a sortable "$ today" column with a
  tooltip exposing the today/7d/30d trio; the per-agent modal carries a
  full LLM Cost section with the last 5 spend rows (backend, model,
  in/out tokens, cost, source). Currency is USD; the cost-table pin
  date (2026-04-01) is surfaced in the tile footer for #319 multi-
  backend audit. Supported backends today: Claude CLI (native cost via
  `total_cost_usd`), Claude HTTP, OpenAI, Gemini, Ollama, mock — all
  resolved through the `(backend, model)` lookup table in
  `agentis-core::llm_cost`. Federations on agentis-core < 1.4.7 still
  render the tile; with no spend log present, every window reads $0.00
  ([#311](https://github.com/Replikanti/agentis-colonies/issues/311)).
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
- Per-agent promotion forecast on Promote Candidates skipped rows. Linear
  regression over `history.json` colony-confidence series projects
  days-to-next-step; null/hidden when slope is flat, declining, or history
  has fewer than 3 points
  ([#276](https://github.com/Replikanti/agentis-colonies/issues/276)).

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
- "Learning // 24h" stat box no longer reports a delta whose window is shorter than 24h when `history.json` does not yet span a full day. The template previously fell back to `history[0]` when no entry satisfied `h.t >= dayAgo`, producing a delta against the oldest surviving snapshot (potentially up to 7 days old) while still labelling the box `// 24h`. The `|| history[0]` fallback is dropped; when no real 24h baseline exists, `expDelta` stays `null` and the existing render guard omits the box (the `confMoves` half still renders independently when confidence-log activity is present in the last 24h) ([#275](https://github.com/Replikanti/agentis-colonies/issues/275)).
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
