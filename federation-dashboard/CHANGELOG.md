# Changelog

All notable changes to `federation-dashboard` are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **dashboard**: `federation-dashboard-collector.py` now consults `<fed_dir>/.agentis/daemon/<agent_id>.heartbeat` line 1 (ms-since-epoch of the last completed tick, written by `write_heartbeat_ext` every tick regardless of `.ag` branch taken) as a fallback when `<agent>:last_check` memo freshness fails. The `.ag` memo-write convention `memo_write("<agent>:last_check", now)` is unreliable -- many tick bodies short-circuit before reaching the write site (missing-upstream picker-empty paths, tier branches that bail early, `exec sh` failures on the `date -u +%Y-...` helper). Concrete reproducer from the post-#798 claude run: `noticer.ag` wrote 20 `last_check` entries across 118 actual ticks (~17% coverage), and the dashboard showed "18 daemons with dead PID" while every daemon was alive and ticking inside the container -- false-negative every refresh. The heartbeat-file fallback fires only when the memo path returns false, reuses the same staleness window (`role_ticks × tick_interval_ms`), and applies only to containerized federations in practice (host-mode `dev-apprenticeship` daemons that DO write `last_check` reliably never reach the fallback path). Mirrors the auto-promote sidecar fix in [#799](https://github.com/Replikanti/agentis-colonies/pull/799) for byte-identical semantics. Empirical: 18/18 → 18/18 (no false negatives) on the current claude run after restart with the patched collector.

### Changed

- **dashboard**: `STALENESS_TICKS` default bumped from `3` to `15` in both the shared `tools/agentis_memo_freshness.py` module and the collector's `ImportError` local-fallback branch. The Run #14 forensic showed listen-driven roles (long-poll `listen()` cadence) hitting the promote-tier cascade SKIP path during their documented ~10-minute quiet windows: at `3` ticks the freshness predicate `now - last_check < STALENESS_TICKS × tick_interval` falsely classified healthy quiet listeners as `pid_alive=false`. `15` covers the 10-minute window on both the 60s `dev-apprenticeship` tick (15 min) and the 120s `research-foundry` tick (30 min) while still flagging genuinely dead daemons within one operator pulse. The `FEDERATION_DASHBOARD_STALENESS_TICKS` env override (clamped to `max(1, ...)`) is untouched, so tick-driven federations can re-tighten to `3` if they prefer faster classification. ([#716](https://github.com/Replikanti/agentis-colonies/issues/716))
- **dashboard**: memo-freshness helpers (`read_memo_raw`, `parse_last_check_epoch`, `resolve_tick_interval_ms`, `STALENESS_TICKS`) extracted from `federation-dashboard/lib/federation-dashboard-collector.py` into shared `tools/agentis_memo_freshness.py` so the dashboard and `tools/auto-promote-decisions.py` (#706) no longer keep a mirrored copy in sync via comment banners. Collector imports via the already-argv-routed `fed_tools_dir`. Graceful degradation preserved: missing helper module → all daemons `pid_alive=false`, matching the pre-existing missing-helper contract. ([#709](https://github.com/Replikanti/agentis-colonies/issues/709))

### Fixed

- **dashboard**: auto-regen now runs as a Python daemon thread inside the server PID instead of an orphan-prone bash subshell. Pre-fix, `SIGKILL` on the wrapper left the bash regen subshell reparented to init, still writing `snapshot.json` with the pre-restart `STALENESS_TICKS` env value. Multiple operator restarts compounded — each spawned a fresh subshell on top of orphaned predecessors, racing on `snapshot.json` and flashing the dashboard banner between DEGRADED and HEALTHY. New design ties the regen loop to the server PID via a `threading.Thread(daemon=True)` whose env recipe is byte-identical to the existing `/refresh` POST handler. New env knob `FEDERATION_DASHBOARD_REGEN_S` (default 60, floor 10) for future tuning. ([#705](https://github.com/Replikanti/agentis-colonies/issues/705))

### Changed

- **dashboard**: `STALENESS_TICKS` (the multiplier in the `now - last_check_epoch < STALENESS_TICKS × tick_interval` freshness window introduced by [#683](https://github.com/Replikanti/agentis-colonies/issues/683)) is now overridable via the `FEDERATION_DASHBOARD_STALENESS_TICKS` env var, clamped to `max(1, int(...))` with a `try/except` fallback to the default `3` on malformed input. Default `3` stays correct for active tick-driven federations like `dev-apprenticeship` (5 colonies, 21 agents writing `<agent>:last_check` every tick). Recommended `10` for listen-driven federations like `research-foundry`, where agents long-poll on `listen()` and the gap between two ticks can legitimately stretch past `3 × tick_interval` while the agent is healthy — at default 3 every quiet listener flipped to `pid_alive=false` and the HEALTHY / DEGRADED banner pinned to DEGRADED. The window formula at the call site is byte-identical; only the constant's source changed. ([#700](https://github.com/Replikanti/agentis-colonies/issues/700))
- **dashboard**: per-agent `pid_alive` flag now derives from `<agent>:last_check` memo freshness (`now - last_check_epoch < STALENESS_TICKS × tick_interval`, default `STALENESS_TICKS=3`) instead of `os.kill(pid, 0)`. The old PID probe required the dashboard to share a PID namespace with the daemons, which is false on containerized federations (`research-foundry`, `tribes-bench`): every PID looked dead from the host and the HEALTHY / DEGRADED banner flipped to DEGRADED even when the agents were ticking happily inside the container. Memo freshness is namespace-independent — every `.ag` agent already writes `memo_write("<agent>:last_check", now)` at the end of every tick (canonical pattern documented in `CLAUDE.md` Agent conventions). Per-agent tick interval is resolved via the existing `tools/resolve-tick-interval.py` helper (60000ms fallback). Multi-repo colonies that scope memos per repo fall back to the freshest `<owner>__<repo>:<agent>:last_check` across the per-repo set when the bare key is absent, mirroring the existing per-repo confidence overlay fan-out. The derived `is_running` field name + semantics (`state == 'running' AND pid_alive`) are preserved so the template + stats-row counter stay byte-identical. The `--raw` flag was also dropped from the pre-existing per-repo confidence overlay read at line ~490 (same root cause: `agentis v1.7.x` rejects `--raw` and silently fell through to null overlay values). ([#683](https://github.com/Replikanti/agentis-colonies/issues/683))
- **dashboard**: Promote Candidates panel now renders one row per explorer pid instead of collapsing the 5 specialties spawned by `research-foundry`'s Phase 3 PR 1 ([#644](https://github.com/Replikanti/agentis-colonies/pull/644)) bootstrap into a single `explorer` row. When a decision record carries `{pid, specialty}` (emitted by `tools/auto-promote-decisions.py` for daemons whose source is `explorer.ag`), the bar label becomes `explorer · <specialty> · gen<generation>` and the tooltip carries `fitness=<score>` alongside the existing prereq checklist. Generation comes from the `explorer:<pid>:generation` memo seeded by `tools/run-research.sh` and the replicate path in `explorer.ag` (Phase 3 PR 1). The per-pid fitness scalar is computed by the new `tools/explorer-fitness.py` helper as `novel_count × audit_conf_avg × hitl_accept` over a rolling K=20 window. Phase 3 PR 2 of [#624](https://github.com/Replikanti/agentis-colonies/issues/624).

## [0.9.1] — 2026-05-04

### Fixed

- **dashboard**: click-handlers (`openDetail`, `restartAgent`, `quarantineAgent`, `evolveAgent`, `setConfidence`) and `agentByName` lookups in the embedded JS now key by `(colony, name)` composite. Without this fix, federations with N agents sharing a role basename across N colonies (e.g. `tribes-bench`'s 5×hunter topology) had click-actions that all resolved to the same record (last-write-wins on a name-only dict). PR #413 fixed the collector data shape so each `(colony, role)` pair gets its own agent record; this fix cascades the (colony, role) keying through the template's JS layer + the `/restart`, `/quarantine`, `/evolve`, `/confidence` server endpoints. Per-row HTML now carries `data-colony` alongside `data-agent`. Single-arg legacy callers (e.g. third-party scrapers) keep working — handlers detect the old shape and fall through to a name-only server lookup, matching pre-#414 behaviour for federations whose role names are globally unique (e.g. `dev-apprenticeship`). `WHY_REGISTRY` keys grew a `colony` prefix so two open modals for same-named agents in different colonies don't overwrite each other's gate state. ([#414](https://github.com/Replikanti/agentis-colonies/issues/414))

## [0.9.0] — 2026-05-02

### Fixed

- **dashboard**: per-agent table now correctly renders one row per `(colony, agent_name)` pair instead of collapsing N agents that share the same role basename across N colonies. Discovered when `tribes-bench` (5 colonies × 1 agent named `hunter` each) rendered a single row instead of 5. `dev-apprenticeship`'s 21 agents have unique role names so it was unaffected. Collector now keys `role_to_daemon` by `(colony, role)` tuple, derives the colony from the daemon's `source` field, and iterates the per-(colony, agent) records the entry script's `AGENT_COLONY_MAP` already builds rather than the flat `all_agents` list. Spend / cost aggregation switches from `name_to_colony[role]` to a new `id_to_colony[agent_id]` lookup so per-(agent, colony) cost stays attributed to the correct colony for N×same-role topologies. ([#412](https://github.com/Replikanti/agentis-colonies/issues/412))

## [0.8.0] — 2026-04-29

### Added

- **dashboard**: per-repo Forge Rate Limits — multi-repo colonies (`[[forge.github]]` with N>=2 entries) now render one rate-limit row per repo inside the per-colony modal, with a colony-wide aggregate footer (sum-of-remaining / sum-of-limit, earliest reset_at). Single-block and N=1 multi-block colonies keep the v0.7.0 single-row layout byte-identical. New `data.forge_rate_limits[colony].repos[]` shape on multi-repo. (#316 M5)
- **dashboard**: per-repo confidence overlay on the per-agent table — when M4-shipped `<owner>__<repo>:<agent>:confidence` memos are seeded, the agent row carries a `(per-repo)` pill and the per-agent modal grows a "Per-repo overrides" subsection. New per-agent collector field `data.agents[].per_repo_confidence`. (#316 M5)

## [0.7.0] — 2026-04-29

5-tab Status redesign + Promotion Progress collapsible + orphan sidecar
detection. The Status tab swaps the prior 21-cell pulse-grid + Confidence
Trend + standalone Promote Candidates / Promotion Ladder cards for a
sortable per-agent compact table (state-dot / name / colony / conf /
next / ETA / limiting prereq / last error, sortable headers persisted in
`localStorage`), a 5-tile stat row including federation-wide cumulative
`data.experience_counts.total`, sidecar pills, and a 2-column bottom row
pairing the Experience Growth chart with a collapsible **Promotion
Progress** panel (`<details>` default collapsed; expanded body stacks
Phase Readiness above a top-5 Promote Candidates list). Logs & Events
becomes its own tab hosting the federation-wide Event Timeline and the
Per-Agent Log Tail (relocated from Recovery). Tier and limiting-prereq
bar contrast meets WCAG-AA via `pickTextColor()`. New `orphan` enum on
per-sidecar pills (orange) — sidecar process is alive (recent ticks in
`auto-promote.log` / `cost-cap.log`) but the install file
(`.auto-promote-install.toml` / `.cost-cap.toml`) is missing on disk;
restart button stays disabled with a tooltip pointing at re-running
`install.sh §7`; federation health banner stays HEALTHY (the loop is
scheduling) and adds a "sidecar running but install file missing" hint
to the detail line.

Schema additions: `data.sidecars[].running_orphan` boolean and `'orphan'`
value in the `data.sidecars[].status` enum. Detection threshold for
orphan inference is 4× the production default interval (7200s).

**Recommends:** dev-apprenticeship >= **1.4.10** (orphan detection reads
the same sidecar liveness files the Sidecars listing already consumes;
no new runtime floor beyond v0.6.0).

### Added

- **dashboard**: detect "orphan" sidecars — sidecar process is alive (recent ticks in `auto-promote.log` / `cost-cap.log`) but the install file (`.auto-promote-install.toml` / `.cost-cap.toml`) is missing on disk. Per-sidecar pill renders `orphan` (orange) instead of `not installed`; age column shows `Nm ago (install file missing)`; restart button stays disabled with a tooltip pointing at re-running `install.sh §7`. Federation health banner stays HEALTHY (the loop is scheduling) but adds a "sidecar running but install file missing" hint to the detail line. Detection threshold is 4× the production default interval (7200s). New collector field `data.sidecars[].running_orphan` and new enum value `data.sidecars[].status === 'orphan'`. ([#378](https://github.com/Replikanti/agentis-colonies/issues/378))

### Changed

- **dashboard**: Promotion Progress panel is now collapsible (default collapsed) with a federation-wide summary line (ready / close / not yet); contrast on tier bars and limiting-prereq partial bars meets WCAG-AA via the `pickTextColor` helper; Promote Candidates list capped at top 5 with a `+N more` hint pointing operators at the Agents table for the full sort. Per-Agent Log Tail moved from Recovery to Logs & Events alongside the Event Timeline. ([#369](https://github.com/Replikanti/agentis-colonies/issues/369))

- **Status tab redesign + 5-tab cut + Promotion Progress combined panel
  + Logs & Events tab**
  ([#362](https://github.com/Replikanti/agentis-colonies/issues/362),
  follow-up to [#359](https://github.com/Replikanti/agentis-colonies/issues/359)).
  Two-step rework. **Iter4** dropped the Progress tab in favour of a
  sortable per-agent compact table operators were hand-pasting from logs:
  `-Progress tab`, `-Confidence Trend` card, `-Phase Readiness` card,
  `-Promote Candidates` card, `-Promotion Ladder` top-level card,
  `-21-cell pulse-grid`; `+5-tile stat row` (incl. federation-wide
  cumulative `data.experience_counts.total` — the missing-since-#359
  ask), `+per-agent table` (state-dot / name / colony / conf / next /
  ETA / limiting prereq / last error, sortable headers persisted in
  `localStorage[agentis:dashboard:agent-table-sort]`), `+Experience
  Growth chart` relocated to the bottom of Status. **Iter5** course-
  corrects in two places after operator preview: (1) the Event Timeline
  was dropped along with Progress in iter4 even though operators still
  needed it for "what just happened?" — iter5 resurrects it on a new
  **Logs & Events** tab; the renderer body never moved, only the host
  divs. (2) Phase Readiness + Promote Candidates were also dropped, but
  the question "who is closest to next promotion?" remains operator-
  level — iter5 resurrects both renderers (verbatim from sha 90ffef4)
  retargeted at a new combined **Promotion Progress** panel
  (`#phase-readiness-host` + `#promote-candidates-host` stacked inside
  one card) and places it on the Status tab in a 2-column flex row
  alongside the relocated Experience Growth chart
  (`.status-bottom-row { display: flex; gap: 16px; }`). Tab bar now
  emits 5 buttons (Status / Cost / Recovery / Logs & Events / Config);
  keyboard shortcuts remap to digits 1-5 (was 1-4 in iter4). Subsumes
  [#361](https://github.com/Replikanti/agentis-colonies/pull/361) by
  redesign (Phase Readiness back, but as half of the Promotion Progress
  combined panel).

- **Intent-driven 5-tab dashboard restructure**
  ([#359](https://github.com/Replikanti/agentis-colonies/issues/359),
  follow-up to [#352](https://github.com/Replikanti/agentis-colonies/issues/352)
  + [#357](https://github.com/Replikanti/agentis-colonies/issues/357)).
  The dashboard now opens to one of five operator-question tabs instead
  of six topic tabs:
  - **Status** — am I healthy NOW? Federation health verdict pill
    (✅/⚠️/❌), 21-cell pulse-grid (color encodes per-agent state, click
    drills into the existing per-agent detail modal), sidecar status
    pills + last-tick age, last-error timestamp + count. NO charts, NO
    bars, NO tables, NO `<details>` — pure single-glance verdict.
    Vertical budget ≤480 px.
  - **Cost** — am I burning money? 4 projection tiles (per-min $/min,
    per-min tokens/min, projected 1h, projected 1d with 1w / 1m in the
    tooltip), today/7d/30d cumulative row, cost-cap progress bar + per-
    colony split. Traffic-light color from a 5-min cost-rate EMA against
    operator-tunable thresholds (`[dashboard].cost_yellow_per_h` /
    `.cost_red_per_h`, default $1/h yellow / $5/h red).
  - **Recovery** — what do I need to restart? Bulk "Restart all stopped"
    button, per-agent restart table (one [Restart] button per row,
    disabled when running), per-sidecar restart, federation kill switch
    with type-the-name confirm modal (defensive double-confirm). Last
    10 watchdog kills as a forensic timeline. Per-agent log-tail
    expandable behind a `<details>` (lazy-fetched from new
    `/log-tail/<agent_id>` endpoint, 20 lines by default).
  - **Progress** — are agents climbing? Confidence Trend +
    Experience Growth charts default-EXPANDED (the `<details>` wrapper
    from #248 PR C is removed on this tab). Phase Readiness as a small
    capped-height card (no longer dominant). Per-agent promotion ladder
    + ETA + limiting prereq + Promote Candidates + Event Timeline.
  - **Config** — what's running where? The #357 per-scope editor
    is preserved; #359 adds bulk apply (per-colony checkbox group on
    the confirm modal when editing federation-wide keys, server-side
    `/config/apply` accepts `scopes:[...]` + reports per-scope
    success/failure) and a cross-colony matrix view (one row per
    dotted key with at least one override).
  Eliminated tabs (their content moved): Overview → split across Status
  + Cost + Recovery; Agents → folds into Status pulse-grid + drill-in
  modal + Progress agent-table; Promotions → folds into Progress;
  Learning → folds into Progress (charts + Event Timeline). Default
  first-paint tab is `status` (was `overview`); legacy localStorage
  values migrate via `LEGACY_TAB_MIGRATION` so a returning operator
  doesn't see a blank tab on first load post-upgrade. Keyboard shortcuts:
  digits 1-5 jump between tabs (was 1-6).

### Fixed

- **Stray-quote rendering on Config tab inline arrays / tables**
  ([#359](https://github.com/Replikanti/agentis-colonies/issues/359)
  Bug 1). The pre-#359 collector's strip-quotes logic only fired when a
  value started AND ended with the same quote character; inline arrays
  (`labels = ["a", "b"]`) and inline tables (`limits = { hi=1 }`) slipped
  through and the Config tab rendered them as editable `<input>`s. Any
  edit then corrupted the array because the line-level patcher only
  handles scalars. Collector now emits a `complex_value: true` flag for
  inline-array / inline-table values; the renderer shows them read-only
  with a "complex" marker so the operator can see the value but can't
  accidentally mutate it. Scalar string values (`backend = "cli"`) keep
  their existing strip-quotes path and render `<input value="cli">`,
  not `<input value="\"cli\"">`. Test 51 is the regression guard.

- **60-second flicker + lost in-flight state**
  ([#359](https://github.com/Replikanti/agentis-colonies/issues/359)
  Bug 2 + Bug 4). The `<meta http-equiv="refresh" content="60">` tag
  on line 5 of the template triggered a full-page reload every minute.
  That wiped any operator in-flight state (modal scroll position, sort
  column, expanded `<details>`, mid-edit Config rows) — and the SSE
  channel from #313 was already keeping the page fresh in-place
  anyway. The meta tag is now removed; SSE is the single source of
  live updates. A small `#sse-dot` in the page header surfaces the
  EventSource lifecycle (green steady on `onopen`, brief pulse on each
  snapshot, red on `onerror`) so the operator can see at a glance
  whether updates are flowing. `?debug=1` enables `console.log` on
  every renderer entry for browser-DevTools verification. Tests 52 + 53
  are the regression guards.

- **Overview tab compactness, Forge Rate Limits relocation, and Config tab
  writability**
  ([#357](https://github.com/Replikanti/agentis-colonies/issues/357),
  follow-up to
  [#352](https://github.com/Replikanti/agentis-colonies/issues/352)).
  Three v0.6.0 mistakes corrected in one PR:
  - **Overview tab cut to ~480 px**. Phase Readiness moved to the top of
    the Promotions tab (where it pairs with the per-agent ladders);
    Forge Rate Limits dropped from Overview entirely. Overview now
    renders Federation Health Banner + bulk-restart action bar, the stat
    tiles row, and the Sidecars listing — operator-actionable surface
    only — leaving ~240 px headroom for the Health Banner to expand
    without scroll.
  - **Forge Rate Limits → per-colony modal**. A new `showColonyModal()`
    overlay opens when an operator clicks a colony chip on the
    Promotions or Agents tab, listing that colony's agents (clickable
    into the per-agent modal) plus a Forge Rate Limits row sourced from
    `data.forge_rate_limits[<colony>]`. Trades a 7th tab for a per-
    colony drill-in (the data is colony-scoped anyway).
  - **Config tab editable by default**. The
    `[config_editor].operator_writes_enabled` gate that defaulted false
    is replaced with a defensive opt-out:
    `operator_writes_disabled = true` in `<fed>/.agentis/config` flips
    the tab back to read-only for operators who explicitly want a lock.
    Default-absent or `false` ⇒ editable. Every Apply pops a structured
    confirm modal listing each key change line-per-line
    (`<scope.key>: <old> → <new>`) before the POST fires, replacing the
    bare `confirm()` dialog. Cancel bails clean.
  - **`/config/apply` line-level TOML patcher**. Audit-only v1 endpoint
    rewritten as a real write path. Reads the target `<fed>/.agentis/
    config` (scope `fed`/`federation`) or `<fed>/<colony>/config/
    colony.toml` as a list of lines, walks tracking the current
    `[section]`, and rewrites only the matching `<bare_key> = <value>`
    line for each change in the payload. Inline comments are preserved
    verbatim via a `(prefix)(value)(suffix)` regex capture; everything
    else is byte-copied. Multi-line array / inline-table values bail
    with 422 + a clear error rather than risk silent corruption.
    Atomic temp-file + `os.rename` write so a crash mid-apply leaves
    the file intact. Drift detection: the dashboard echoes the
    snapshot's mtime back in the apply payload; if disk mtime is newer,
    the server returns 409 with `{drift: true, current_mtime_ms}` and
    the dashboard surfaces a banner. Successful applies append one
    JSONL row per change to `<fed>/.agentis/logs/config-edits.jsonl`
    (audit trail kept) and trigger a per-colony agent restart via
    `<colony>/scripts/start-colony.sh --restart-agent <name>`.

  Operator-facing summary: Overview is actionable-first, Forge Rate
  Limits is a colony drill-in instead of an Overview tile, and the
  Config tab actually writes the file when an operator clicks Apply.
  The `--config-override` upstream gap from
  [#351](https://github.com/Replikanti/agentis-colonies/issues/351) is
  still open, so cost-cap / per-colony `[llm]` writes remain no-ops at
  the runtime layer until upstream lands the flag — the Config tab now
  records the intent in the file and the audit log either way, so the
  edit surface is no longer the blocker.

  No federation-dashboard MINOR bump; deferred to the next release PR.

## [0.6.0] — 2026-04-26

Tabbed layout + live SSE pipeline complete. Replaces the long-scroll
single-page layout with **six tabs** (Overview / Agents / Promotions /
Learning / Cost / Config) — each tab fits a 720px content area, the
operator clicks between focused views instead of scrolling. Fixes the
contrast bugs on amber / yellow bars (white text was unreadable) via a
`pickTextColor()` helper that auto-picks dark or light text based on
the bar fill colour. Adds a per-sidecar listing in Overview (auto-promote
+ cost-cap, named with status pills + per-row restart buttons) — the
prior banner just said "sidecar ticked" without naming which one. Adds
a bulk-restart action bar surfacing `[Restart N stopped agents]` only
when the federation has non-running agents, with operator confirmation.
Adds a Config tab — read-only by default — where operators can audit
per-colony + federation-wide TOML keys; `/config/apply` is audit-only
in v1 (logs intent to `<fed>/.agentis/logs/config-edits.jsonl`). Live
SSE updates ([#313](https://github.com/Replikanti/agentis-colonies/issues/313))
push fresh snapshots via `EventSource('/events')` without a hard reload,
with DOM-state preservation across re-renders (modals stay open, sort /
scroll survive). Federation-wide chronological timeline tile + `/timeline`
HTTP endpoint ([#315](https://github.com/Replikanti/agentis-colonies/issues/315))
merges all 21 agents' streams capped at last 200 reverse-chronological
for the in-page tile + `/timeline?since=<ts>&limit=&colony=&kind=` for
older data, served from a precomputed `<dash-dir>/timeline-full.jsonl`
(7-day or 5000-row cap, atomic write per generate cycle).

**Recommends:** dev-apprenticeship >= **1.3.0** (Sidecars listing reads
the auto-promote + cost-cap sidecar liveness files; Config tab reads
`<fed>/.agentis/config` and per-colony `colony.toml`; spend log fields
match dev-apprenticeship 1.3.0's runtime expectations).

### Changed

- **Tabbed dashboard layout + WCAG-AA contrast fixes + per-sidecar listing +
  bulk-restart actions + read-only Config tab**
  ([#352](https://github.com/Replikanti/agentis-colonies/issues/352)). The
  single vertical-scroll page is replaced with a six-tab single-page app
  whose content fits a 1080×720 viewport on every tab without scrolling.

  **Six tabs**, persisted via `localStorage` (key
  `agentis:dashboard:active-tab`, default `overview`), keyboard-jumpable via
  digits `1`–`6`:
  - **Overview** — federation health stat tiles, per-sidecar listing
    (auto-promote + cost-cap, with name + age-since-tick + status pill +
    `[restart]` button), bulk-restart action bar (visible only when ≥1
    agent is non-running or ≥1 sidecar is silent), Phase Readiness
    stacked bars (#342), Forge Rate Limits.
  - **Agents** — per-agent dossier table (sortable, modal-expandable;
    unchanged from #311 PR B + #313 PR 2).
  - **Promotions** — new per-agent **promotion ladder** + Promote
    Candidates bars. Each ladder row is a single full-width bar with five
    tier segments (`dormant` / `shadow` / `propose` / `review-gated` /
    `autonomous`) sized to ADR-0001 tier ranges, a vertical marker at
    the agent's current confidence, an ETA cell (`X.Xd` or `—` when no
    forecast), and a limiting-prereq cell. Autonomous-tier agents
    (confidence ≥ 0.95) render the full ladder filled with a `MAX`
    badge replacing the ETA cell — no more empty bars for already-promoted
    agents.
  - **Learning** — federation-wide Event Timeline (#315 PR 2) +
    Confidence Trend / Experience Growth charts (#248 PR C, demoted
    behind `<details>`).
  - **Cost** — split into two sections: **LLM Tokens** (federation-wide
    input/output token counts, today/7d, per-agent breakdown) on top,
    **LLM Cost (USD)** + **Cost Cap** below. The previous single
    `renderLlmCost` IIFE is now `renderLlmTokens` + `renderLlmUsd` (the
    legacy `renderLlmCost` is preserved as an alias targeting the same
    container so any third-party scrape that hits `id="llm-cost"`
    selectors keeps working).
  - **Config** — new per-colony + federation-wide TOML config editor.
    **Read-only by default**; flipping
    `[config_editor].operator_writes_enabled = true` in
    `<fed>/.agentis/config` unlocks the apply path. Two-pane layout:
    left scope picker (federation / each colony), right key-value editor
    with typed input controls (number / bool toggle / text / enum
    dropdown for known-vocab keys). `[Apply]` POSTs `/config/apply` —
    audit-logged to `<fed>/.agentis/logs/config-edits.jsonl`. Drift
    detection: when the on-disk file mtime changes between dashboard
    reads a banner + `[Reload]` surfaces.

  **WCAG-AA contrast fixes** via a new `pickTextColor(bg)` JS helper.
  Two-stage strategy: (1) static lookup mapping known palette entries
  (`#f59e0b` amber, `#ffff00` yellow, `#22c55e` light green, `#06b6d4`
  cyan-blue, `#ff8800` orange) to `var(--text-on-light)` (a new
  near-black token, `#1a1a1a`), and dark fills (red, blue, magenta,
  gray) to the original `var(--text)` cyan; (2) WCAG relative-luminance
  fallback for hex colors not in the lookup. Migrated label-color sites:
  `.phase-bar` (every tier inside Phase Readiness), `.promote-bar`
  (every bucket on Promote Candidates), `.ladder-segment` (every tier
  on the new Promotion Ladder). The previous `tier-review-gated` (amber
  fill) + white left label combination failed WCAG AA — the helper
  routes that label to dark text now.

  **Bulk-restart endpoints** (server-side): `POST /restart-all-stopped`
  walks running daemons vs `agent_to_colony` and shells each non-running
  agent through `start-colony.sh --restart-agent <name>` in parallel
  (bounded by `os.cpu_count()`); returns
  `{stopped: [...], started: [...], failed: [...]}`. `POST
  /sidecar-restart` thin-shells into a new
  `tools/sidecar-restart.sh <fed-dir> <name>` helper (mirrors the
  `cost-cap.sh --override` precedent — the actual kill+respawn lives in
  shell). `POST /config/apply` appends every applied edit to the JSONL
  audit trail; gated on `operator_writes_enabled` so a stub server
  defaults to 503.

  **Collector extensions**: `data.sidecars[]` (per-sidecar status array),
  `data.config_editor` (operator_writes_enabled flag + per-scope
  key-value snapshot), `cost.tokens_federation` + `cost.tokens_by_agent`
  (token aggregation alongside the existing dollar aggregation).

  Test coverage: `tools/test-timeline-rendering.sh` grows nine new
  assertions (36–44) — six structural (sections, tab buttons,
  pickTextColor lookup, MAX badge, sidecar rows, read-only Config), one
  init-default (Overview default + persisted), one endpoint-existence
  (three new endpoints respond with defensive status codes). Total
  44 passed / 0 failed (was 35 / 0 baseline).

  No version bump; the next federation-dashboard release PR collects
  #313 + #315 + #342 + this and bumps to 0.6.0.

- **Promote Candidates and Phase Readiness redesigned as Dune-style game-UI
  progress bars** ([#342](https://github.com/Replikanti/agentis-colonies/issues/342)).
  Both tiles trade their text-heavy lists for chunky horizontal bars so an
  operator reads federation readiness as a visual share, not a parsed sentence.

  **Promote Candidates** now renders one bar per non-autonomous agent
  instead of the per-row prereq checklist. Bar fill is the *limiting*
  prereq (`min(value/threshold)` across `evidence.prereqs[]`) — what the
  operator can actually act on, e.g. `entries 47/200` or
  `runtime 0.4h/1.0h`. Mean fill picks the colour bucket so a single
  brittle gate does not paint the whole bar red: green when all prereqs
  meet, yellow when mean is in `[0.5, 1.0)`, red when mean is below 0.5.
  `evolve` decisions render as a distinct purple bar (orthogonal intent —
  fitness recovery, not a tier promotion). Already-autonomous agents are
  excluded entirely. Sort order is closest-to-ready descending so the
  next-actionable agent rises to the top. Hover reveals the full
  per-prereq breakdown via a CSS-only `title=""` tooltip; the per-agent
  Agents table stays as-is for drill-in.

  **Phase Readiness** now renders five stacked bars per colony — one
  per ADR-0001 tier (`dormant` / `shadow` / `propose` / `review-gated` /
  `autonomous`) — instead of the #248 PR C compact tier counter. Bar
  width is `(agents_in_tier / total_agents_in_colony) * 100%`, so each
  colony's tier mix reads as a horizontal share at a glance. The
  pre-#342 `no-conf` bucket collapses into `dormant`. Hover lists the
  agents currently in that tier via the same `title=""` tooltip.

  Bars carry a subtle inner gradient (`linear-gradient` +
  `color-mix(in srgb, ..., white)`), `border-radius: 4px`, and
  `transition: width 300ms ease` so re-renders driven by the
  `agentis:snapshot` SSE channel ([#313](https://github.com/Replikanti/agentis-colonies/issues/313)
  PR 2) animate smoothly. A one-time `bars-fade-in` keyframe runs once
  per page load (gated on the `.bars-loaded` marker class) so subsequent
  pushes don't strobe.

  Test coverage: `tools/test-timeline-rendering.sh` test 22 flips its
  positive-list to the new `phase-bar` / `tier-<name>` classes; three
  new tests (33 / 34 / 35) lock the Promote bar markup, the 5-tier bar
  emission per colony, and the limiting-prereq arithmetic. Total
  35 passed / 0 failed (was 32 / 0 baseline).

### Added

- **Federation-wide chronological action timeline** — completes the timeline
  story for [#315](https://github.com/Replikanti/agentis-colonies/issues/315)
  (PR 2 of 2). Combined with PR 1 (per-agent modal section + collector-side
  `build_agent_timeline()` merge of experience / spend / confidence-log /
  lifecycle JSONL streams), the timeline story is complete. PR 2 lands the
  federation-wide tile + a new `GET /timeline` HTTP endpoint with pagination.

  The collector emits a new top-level `timeline[]` array (last 200 rows,
  reverse-chronological across all agents) as part of `COLLECTOR_JSON`.
  Each row carries the PR 1 envelope (`{ts, agent_id, kind, payload,
  severity}`) plus two new fields — `agent_name` and `colony` — so the
  client renders colony chips without a second `agents` lookup. The
  merge re-uses the per-source bucketing PR 1 already does
  (lifecycle + confidence-log keyed by `agent_id` once across the
  federation; experience + spend re-read per agent from the same files
  the per-agent timelines slice). Total complexity stays
  `O(N_lifecycle + N_experience + N_spend + N_confidence)` — no
  quadratic per-agent re-reads.

  The federation-wide Event Timeline tile (template lines around 696–710)
  drops the legacy regex log scraper (`data.events`) and renders directly
  from the structured `data.timeline[]`. Each row shows: timestamp
  (ABS / REL toggle), agent name, colony chip, kind icon, and a 1-line
  summary string per kind that mirrors the per-agent modal verbatim.
  Filter UI grows two new layers: a colony dropdown built from
  `colonyList`, and a kind chip row (`learn` / `prompt` /
  `confidence_change` / `lifecycle`) that supersedes the pre-PR2
  classifier-typed chips. Pre-existing filters survive: blanket cursor
  (Clear all), per-(agent_name, kind) cursor (Clear stale), per-row
  dismiss set, time-mode toggle, auto-hide-stale on `error`-severity
  rows from cleanly-ticking agents. Every chip / filter persists in
  `localStorage` namespaced by `FED_NAME`. Reuses the existing
  `timeline-entry` / `timeline-ts` / `timeline-type` CSS so colour cues
  match the per-agent modal palette. Live updates flow through the
  `agentis:snapshot` SSE channel landed by [#344](https://github.com/Replikanti/agentis-colonies/issues/344)
  (#313 PR 2): `renderEventTimeline(data)` is one of the eleven
  `renderXxx` functions called on every fresh snapshot, so the tile
  refreshes in place without `location.reload()`.

  **`GET /timeline?since=<unix-ms>&limit=<N>&colony=<name>&kind=<csv>`**
  — new read-only HTTP endpoint that returns
  `{rows: [...], next_cursor: <ts>|null}` of timeline rows OLDER than
  `since` (default = current time, returning the most-recent N rows).
  `limit` defaults to 200, capped at 500 to bound memory. `colony` is
  an exact-match string filter; `kind` is a comma-separated list of
  kinds. Backed by a precomputed `<dash-dir>/timeline-full.jsonl`
  written atomically by the wrapper alongside `snapshot.json` after
  each generate cycle (last 7 days OR 5000 rows, whichever is smaller,
  reverse-chronological). The new
  `lib/federation-dashboard-timeline.py` helper reads the four source
  streams once and writes the JSONL output directly without going
  through the embedded 200-row cap. Endpoint contract: `200` on
  success (including missing file → empty rows), `400` on malformed
  query params (bad since/limit, limit out of `[1, 500]`), `500` on
  internal read error. No side effects, no signals, no daemon
  mutation — purely read-only.

  New tests in `tools/test-timeline-rendering.sh`:
  - **t30**: drives the collector against a 3-agent fixture and
    asserts `data.timeline[]` is non-empty, ts-desc sorted, capped at
    200, contains rows from at least 2 distinct agents, and every row
    carries `agent_name` + `colony`.
  - **t31**: HTTP smoke against `/timeline?since=<future>&limit=5` —
    asserts `rows` is ts-desc sorted, length ≤ 5, and `next_cursor`
    is non-null when more rows remain.
  - **t32**: HTTP smoke against `/timeline?colony=colony-b` — asserts
    every returned row carries `colony=colony-b` and only the
    expected agent ids appear.

  Out of scope (deferred): calendar-picker date range, CSV export,
  full-text search, per-row drill-in to a separate page.

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

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.9.0...HEAD
[0.9.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.8.0...federation-dashboard-v0.9.0
[0.8.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.7.0...federation-dashboard-v0.8.0
[0.7.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.6.0...federation-dashboard-v0.7.0
[0.6.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.5.0...federation-dashboard-v0.6.0
[0.5.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.4.0...federation-dashboard-v0.5.0
[0.4.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.3.0...federation-dashboard-v0.4.0
[0.3.0]: https://github.com/Replikanti/agentis-colonies/compare/federation-dashboard-v0.2.0...federation-dashboard-v0.3.0
[0.2.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/federation-dashboard-v0.2.0
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/federation-dashboard-v0.1.0
