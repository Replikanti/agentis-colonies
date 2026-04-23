# Changelog — dev-apprenticeship

All notable changes to the `dev-apprenticeship/` federation will be documented in this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html) at the
federation level (not per-colony — see the rationale in
[issue #218](https://github.com/Replikanti/agentis-colonies/issues/218)). The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `dev-apprenticeship-v<X.Y.Z>` so tool-level or alternate-federation
releases can coexist without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`. No upper bound
is asserted until multi-version CI is in place.

## [Unreleased]

### Added

- Every colony's `scripts/start-colony.sh` supports a new
  `--restart-agent <name>` mode that respawns exactly one agent with the
  full colony env, skipping memo seeding and log truncation (both of
  which are full-colony bootstrap concerns). Exit codes: 0 ok, 2
  unknown flag / missing arg, 3 unknown agent name for this colony, 4
  daemon launch failure. Positional config-path arg still works for
  pre-#257 callers. Enables the dashboard-side decoupling in
  `federation-dashboard` 0.2.0.
  [#257](https://github.com/Replikanti/agentis-colonies/issues/257)
- **Forge abstraction foundation (ADR-0002, PR 1 of 7 for #256).** Every
  colony's `colony.example.toml` now carries a `[forge]` section with
  `type = "gitlab"` plus `[forge.gitlab]` and a commented-out
  `[forge.github]` template. Each colony ships a thin
  `scripts/forge-api.sh` dispatcher that reads `$FORGE_TYPE` and execs
  the right per-colony wrapper (`gitlab-api.sh` today, `github-api.sh`
  in PRs 2-6). Unknown `FORGE_TYPE` → exit 2; `FORGE_TYPE=github` with
  no wrapper yet → exit 99 with an ADR pointer. `start-colony.sh`
  parses `[forge].type`, defaults to `"gitlab"` (pre-#256 configs keep
  working verbatim), and exports `FORGE_TYPE`. `install.sh` gained a
  new "3a. Forge backend selection" section with a
  `FEDERATION_FORGE_TYPE=gitlab|github` env short-circuit for
  unattended installs, an interactive prompt defaulting to gitlab,
  a clear warning when github is chosen before PRs 2-6 land, and a
  section-scoped rewrite that sets `[forge].type` in the generated
  `colony.toml`. The `[forge].type` rewrite runs unconditionally (even
  when the operator re-runs `install.sh` purely to switch forge and
  declines to update credentials), and both the GitHub-confirm and
  credential-update prompts short-circuit when `FEDERATION_FORGE_TYPE`
  is set — unattended `FEDERATION_FORGE_TYPE=github ./install.sh`
  installs no longer block on stdin. The top-level `[gitlab]` section
  is retained for one release of migration overlap (retired in PR 7 of
  #256). New lint gate: `tools/test-forge-config.sh` (6 per-colony
  checks × 5 colonies + 7 install.sh + ADR checks = 37 sub-tests). See
  `doc/adr/ADR-0002-forge-abstraction.md` for the full contract.
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)
- **Triage colony GitHub backend (PR 2 of 7 for #256).**
  `dev-apprenticeship/triage/scripts/github-api.sh` implements the full
  triage contract against the GitHub REST API v3 (7 subcommands: `issues`,
  `create-issue`, `update-issue`, `members`, `get-issue`, `labels`,
  `add-note`). Responses are normalized to GitLab shape (iid ← number,
  author.username ← user.login, assignees[].username ← login, labels as
  strings — both object-form `[{"name": ...}]` and bare-string form are
  accepted for GitHub Enterprise compatibility — state "open" → "opened",
  `pull_request`-bearing entries filtered out) so the existing 8 views
  and the triage `.ag` agents keep parsing identical JSON across
  backends. Every triage `.ag` `exec sh` call site was rewritten from
  `scripts/gitlab-api.sh` to `scripts/forge-api.sh` (19 call sites
  across `issue_creator`, `labeler`, `prioritizer`, `router`) — without
  this, `FORGE_TYPE=github` silently fails because `start-colony.sh`
  exports only the `GITHUB_*` env, `gitlab-api.sh` trips its env check,
  and the `.ag` try/catch swallows the error. A new lint rule
  `tools/check-forge-dispatch.sh` (wired into `colony-lint.sh`) now
  fails CI whenever any `.ag` in a colony shipping `github-api.sh`
  references a concrete backend wrapper directly. GitHub-specific error
  handling distinguishes HTTP 403 auth failures from secondary
  rate-limit 403s (retryable) via response-body inspection. The
  `--priority` flag rejects loud with guidance to use
  `--add-labels "priority::<level>"` (GitHub has no native priority
  field). `--remove-labels` treats 404 as no-op for idempotency parity
  with GitLab. `triage/scripts/start-colony.sh` now branches on
  `FORGE_TYPE`: exports `GITHUB_URL` / `GITHUB_OWNER` / `GITHUB_REPO` /
  `GITHUB_TOKEN` / `GITHUB_ME` from `[forge.github]` when
  `type = "github"`, reads `[forge.gitlab]` with `[gitlab]` legacy
  fallback otherwise. `[forge.github].url` is optional (defaults to
  `https://api.github.com`) and exists solely to point the wrapper at a
  GitHub Enterprise Server instance. Back-ports missing `add-note`
  subcommand into `triage/scripts/gitlab-api.sh` with a numeric-iid
  guard (closes a silent bug where labeler/prioritizer/router
  review-gated comment-posting calls were swallowed by the `.ag`
  try/catch). Four new tests:
  `tools/test-github-triage-normalize.sh` (25 assertions covering
  shape, PR filtering, empty-list handling, and end-to-end pipe through
  a view); `tools/test-check-forge-dispatch.sh` (6 assertions);
  `tools/test-gitlab-add-note.sh` (4 assertions for arg parsing and the
  happy path via a curl shim); and an extension to
  `tools/test-gitlab-views.sh` with a 6-case parity block asserting
  byte-identical `project_json` output between `github-api.sh` and
  `gitlab-api.sh` (drift detector for the duplicated projection
  function).
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)

### Changed

- `.dashboard-version` floor bumped to 0.2.0. The new dashboard release
  delegates agent restarts through `start-colony.sh --restart-agent`
  instead of parsing `[gitlab]` from `colony.toml` — pairing a 0.1.0
  dashboard with a 1.x federation is still safe (the dashboard
  gracefully logs `start-colony.sh exit 2: unknown flag`), but the
  recommended floor matches the pair tested together.

### Deprecated

### Removed

### Fixed

### Security

## [0.3.3] — 2026-04-23

Operator-visibility release: a HEALTHY / DEGRADED banner and per-agent
promote-readiness breakdown, `Promote Candidates` now runs the auto-promote
scheduler's verdicts directly (no more silent drift between the two), and
the dashboard is now a separately-versioned standalone component — dashboard
fixes can ship without forcing a federation re-release. Runtime floor unchanged.

**Requires:** agentis >= 1.4.1
**Recommends:** federation-dashboard >= 0.1.0 (pinned via `dev-apprenticeship/.dashboard-version`)

### Added

- **Federation dashboard: HEALTHY / DEGRADED banner, per-agent promote-readiness breakdown, 24h learning indicator**
  ([#248](https://github.com/Replikanti/agentis-colonies/issues/248)).
  Three operator-visibility additions that share the same data surface:
  (1) a health banner right under the header that goes HEALTHY when all
  running daemons have a live PID AND (if installed + enabled) the
  auto-promote sidecar has ticked within 2× its configured interval, and
  DEGRADED with specific reason lines otherwise; (2) each skipped promote
  candidate now expands to a checklist of which prereqs it meets vs fails
  (entries_total, entries_acting, runtime_hours, and — when past the
  bootstrap step — reject_rate and delta_slope) with the agent's actual
  value and the threshold it was measured against; (3) a new "Learning //
  24h" stat box showing the delta in total experience entries over the
  last 24h (from history snapshots) plus the count of confidence moves
  in the same window. All three are null-safe: the banner hides on a
  stopped federation, the prereqs block is omitted when the decider didn't
  attach one, the learning box is omitted when history has fewer than two
  snapshots. `auto-promote-decisions.py` now emits an `evidence.prereqs`
  array on every promote-path decision (skip + promote); test 14 asserts
  the structure. `federation-dashboard-collector.py` surfaces a new
  `sidecar` field (installed, enabled, interval_s, last_tick_ts) from
  `.auto-promote-install.toml` and the sidecar log mtime.

### Changed

- **Federation dashboard: low-value panels demoted** ([#248](https://github.com/Replikanti/agentis-colonies/issues/248) PR C).
  Three changes derived from operator feedback in the parent issue:
  (1) **Phase Readiness** swapped from a colony-average bar with ETA-to-tier
  estimate (skewed by single-autonomous-outlier colonies, opaque X-axis) to
  a compact per-colony per-tier counter (`shadow: 0  propose: 4  review-gated: 0  autonomous: 0`).
  Same ADR-0001 tier classification the agent-row badges use;
  null-confidence agents render in a separate `no-conf: N` bucket (mirrors
  the table's `badge-na` vs `badge-dormant` distinction); zero-count tiers
  are suppressed when at least one tier on the row is non-zero.
  (2) **Confidence Trend** chart moved behind a collapsed `<details>` —
  per-agent confidence-on-card already answers the operator's everyday
  question; the chart stays for trend-spotters.
  (3) **Experience Growth** chart same treatment — per-agent
  `entries_total` is the number operators actually consult.
  Locked by `test-timeline-rendering.sh` tests 22 (no `phase-bar-*`
  classes; tier counter classes wired) and 23 (both charts inside a
  default-collapsed `<details class="card-collapse">`).

- **Federation dashboard extracted to a standalone, separately-versioned component**
  ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)).
  The dashboard now lives at `federation-dashboard/` in the repo and ships
  its own release tarball (`federation-dashboard-v<X.Y.Z>.tar.gz`), its
  own CHANGELOG, and its own XDG-aware `install.sh`. `dev-apprenticeship`
  pins a soft minimum via the new `dev-apprenticeship/.dashboard-version`
  file (currently `0.1.0`); `dev-apprenticeship/install.sh` gains a step 8
  that prompts the operator to install that pinned version
  (set `FEDERATION_DASHBOARD_SKIP=1` to opt out non-interactively).
  `dashboard.sh` is now a resolver wrapper that finds the standalone
  binary via `$FEDERATION_DASHBOARD_BIN` → XDG default
  (`${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/bin/federation-dashboard`)
  → `command -v federation-dashboard`. The dashboard binary resolves
  federation-shared tools (`kill-federation.sh`, `auto-promote-decisions.py`,
  `resolve-tick-interval.py`) via `<fed-dir>/tools/` first, then
  `<fed-dir>/../tools/`, and gracefully degrades when a script is
  unreachable (`/kill` returns 503, `Promote Candidates` renders empty,
  the tick interval falls back to 60000ms) instead of hard-asserting at
  startup. Net behaviour for an operator who runs `install.sh` and then
  `dashboard.sh` is unchanged; the difference is that dashboard fixes
  can now ship without forcing a federation re-release.

### Deprecated

### Removed

### Fixed

- **Federation dashboard's `Promote Candidates` panel now shows the scheduler's own verdicts**
  ([#248](https://github.com/Replikanti/agentis-colonies/issues/248)).
  Before, the dashboard ran its own fitness heuristic (success/total
  across every row, no runtime, no acting-vs-observe split) and silently
  disagreed with `auto-promote.sh`. After [#186](https://github.com/Replikanti/agentis-colonies/issues/186)
  split acting/observing rows on the scheduler side, and after
  [#245](https://github.com/Replikanti/agentis-colonies/issues/245)
  extracted the scheduler's logic into `tools/auto-promote-decisions.py`,
  the dashboard still used the old formula — so operators saw stale
  "ready to promote" rows for agents the scheduler had already ruled
  out (runtime too short, reject-rate too high, not enough acting entries).
  `auto-promote-decisions.py` now also runs as
  `--preview --config <yaml>`; `federation-dashboard-collector.py`
  invokes it each regen and the template renders the JSON verdicts
  verbatim. The no-op-at-source guard (promoting to a confidence that
  resolves to the same tier for this agent's `.ag` source) is still
  enforced client-side. `test-auto-promote.sh` test 12 asserts
  byte-identical output between the legacy positional mode and the
  new `--preview` mode.

### Security

## [0.3.2] — 2026-04-22

Portability patch. `auto-promote.sh` now runs unmodified on stock macOS;
the scheduler had previously silently no-op'd on every macOS invocation
while the sidecar reported a misleading "Another auto-promote instance
is running" line. Runtime floor unchanged.

**Requires:** agentis >= 1.4.1

### Fixed

- **`tools/auto-promote.sh` portable on macOS**
  ([#245](https://github.com/Replikanti/agentis-colonies/issues/245)).
  Two independent failure modes on stock macOS hosts are fixed. The
  `flock -n` call (util-linux, not shipped on macOS) is replaced by a
  `tools/auto-promote-lock.py` helper that acquires a POSIX
  `fcntl.flock(LOCK_EX | LOCK_NB)` lock on the inherited fd; the lock
  is held for the life of the parent shell on both Linux and macOS.
  Both embedded heredocs (`eval "$(python3 - <<'PYCONFIG' ... PYCONFIG)"`
  and `$(python3 - ... <<'PYEVAL' ... PYEVAL)`), which the macOS bash 3.2
  parser cannot handle, are extracted to `tools/auto-promote-config-parser.py`
  and `tools/auto-promote-decisions.py` — matching the #170 / #172 fix
  pattern previously applied to `federation-dashboard.sh`. Shebang on
  `auto-promote.sh` changed to `#!/usr/bin/env bash` as a secondary
  guard when users put homebrew bash ahead of `/bin/bash` on PATH.

## [0.3.1] — 2026-04-21

Feedback-loop-and-reliability patch. Labeler gains an autonomous-tier
reality check closing the remaining hole in the #195 feedback-loop
pattern (autonomous writes are now scored against operator reverts
rather than silently tracked at `"success"`). Implementation-colony
agents stop re-burning LLM budget on the same MR iid across ticks.
Federation-dashboard no longer cross-reads sibling federations'
`.agentis/` state under a shared-parent layout, and the evolve
flat-slope threshold is calibrated from production data. Runtime
floor unchanged.

**Requires:** agentis >= 1.4.1

### Added

- **Labeler autonomous-tier reality check (pilot)**
  ([#203](https://github.com/Replikanti/agentis-colonies/issues/203)).
  Extends the #195 reality-check pattern to the labeler's autonomous
  branch, where the agent writes labels to GitLab directly and the
  ground-truth signal is "did the operator revert the write?" rather
  than "did the operator apply our suggestion?". New memo schema is
  multi-slot per-iid (`labeler:autonomous_verdict:<iid>` + an index
  CSV `labeler:autonomous_verdict_index`) so multiple in-flight writes
  can soak in parallel; the single-slot propose-path idiom remains
  untouched. Soak window 30 min, ageout 48 h (longer than the propose
  path's 24 h to match the slower human-response horizon on an
  already-applied label). Two-row pattern per autonomous action:
  at-write `learn("success", ..., "acted")` preserves the existing
  acting-path fitness signal for #186, post-soak
  `learn(<outcome>, ..., "acted")` lands in the same tag bucket and
  averages in — so a consistently-reverted agent sees its acting
  fitness drift down despite at-write optimism. Full pattern
  documented in
  [`doc/feedback-loop.md`](../doc/feedback-loop.md#autonomous-tier-extension-203-labeler-pilot);
  structural regression in `tools/test-labeler-autonomous-verdict.sh`.
  Fan-out to the other 20 agents is tracked per-agent in follow-up
  tickets.

### Changed

- **Evolve flat-slope threshold calibrated from production data**
  ([#163](https://github.com/Replikanti/agentis-colonies/issues/163)).
  Bumped from `1e-6` (original guess) to `1e-4`; promoted to a named
  const `SLOPE_FLAT_THRESHOLD` in
  `tools/federation-dashboard.html.template` so future re-calibration
  is a one-line tweak. Calibration source: 23-agent slope snapshot
  captured on v1.4.3 against a long-running federation after core PR
  #542 populated `fitness_delta` per outcome. The |slope|
  distribution splits cleanly between a true plateau band
  (|slope| ≤ 1e-5: `code_writer`, `commit_composer`, `router`,
  `prioritizer` — the canonical "evolve is pointless" agents the
  gate is meant to catch) and an oscillation band
  (|slope| ∈ [1e-4, 3e-3]: most everything else), with no data in
  the gap between. `1e-4` is the lower edge of the oscillation band.

### Fixed

- **Federation-dashboard: prefer federation-local `.agentis/` over
  parent-level**
  ([#238](https://github.com/Replikanti/agentis-colonies/issues/238)).
  Sibling federations sharing a parent directory were cross-reading
  each other's experience/logs because `${FED_DIR}/../.agentis`
  resolves to the same directory for both. Precedence flipped to:
  federation-local `.agentis/` wins when present; parent-level is the
  fallback (preserves the legacy symlinked single-federation layout
  where `<fed>/.agentis -> ../.agentis` still resolves via the
  local-first check); cwd-relative `.agentis/logs` is the final
  fallback. Also fixes the same bug class in
  `dev-apprenticeship/watch-suggestions.sh` (the default
  `$SCRIPT_DIR/../.agentis/logs` resolved to the shared-parent
  directory, reporting "no logs" under a sibling-federation layout
  unless the user passed an explicit argument).
- **Implementation agents: MR-level idempotency gate on the learning path**
  ([#239](https://github.com/Replikanti/agentis-colonies/issues/239)).
  `code_writer`, `test_writer`, `refactorer`, and `commit_composer` each
  gain a `should_learn_from_mr(mr_iid)` gate that memoizes the last MR
  iid learned from and short-circuits before the `mr-changes` /
  `mr-commits` subprocess, the LLM `prompt()`, and the `learn()` call
  when the same MR is seen again. Without the gate, `merge-requests
  --since <last_check>` kept returning the same MR at index `[0]` as
  long as its `updated_at` kept getting bumped (new comment, pipeline
  event, label change) — at the implementation colony's `cb_budget`
  (600 – 2000 per agent), that produces hundreds of duplicate `Learned
  from MR <N>` entries per hour on a long-lived issue and the memory
  load that precedes the silent agent-daemon deaths described in the
  issue. Memo keys: `<agent>:last_learned_mr_iid`. Single-key, no TTL —
  we want at-most-once per distinct MR iid per daemon lifetime.
  Upstream concerns (terminal `daemon.stopped` on SIGKILL-by-OS,
  per-agent RSS instrumentation, watchdog auto-restart on silent death)
  remain open in `agentis-core`; this colony-side fix removes the load
  that triggers the class of runtime failure.

## [0.3.0] — 2026-04-20

Observability release. Planning and implementation colonies can no longer
silently miss short-lived trigger-label transitions (a label added and
removed between two 60 s polls). A new `gitlab-api.sh` command family
reads GitLab's `resource_label_events` endpoint and the 5 ticking agents
that depend on trigger-label state (`risk_assessor`, `scope_estimator`,
`task_decomposer`, `plan_reviewer`, `code_writer`) union current-state
with in-window add events. First-tick boot behavior preserved byte-
identically. Runtime floor unchanged.

**Requires:** agentis >= 1.4.1

### Added

- **Events-aware label observability for trigger-label agents**
  ([#235](https://github.com/Replikanti/agentis-colonies/issues/235)).
  Planning and implementation colonies now detect short-lived trigger
  labels that are added and removed between two 60 s polls. Three new
  `gitlab-api.sh` sub-commands wrap GitLab's `resource_label_events`
  endpoint:
    - `issues-by-label-events --since <ISO8601> [--view <name>]` (planning) —
      union of currently-labeled open issues and issues where
      `$PLANNING_TRIGGER_LABEL` was added in [since, now].
    - `assigned-issues-by-label-events --since <ISO8601> [--view <name>]`
      (implementation) — same, but assignee-scoped and uses
      `$IMPLEMENTATION_TRIGGER_LABEL`.
    - `issue-label-events <iid> [--since ISO8601] [--label NAME]` —
      primitive events reader, available from both colonies.
  `risk_assessor.ag`, `scope_estimator.ag`, `task_decomposer.ag`,
  `plan_reviewer.ag`, and `code_writer.ag` now call the events-aware
  variant whenever their `last_check` memo is populated; first tick
  still issues the pre-#235 current-state snapshot, so boot behavior is
  byte-identical.

## [0.2.0] — 2026-04-20

Portability-series release. Four new optional config keys let operators adapt
the federation to project-local label taxonomies and primary-branch names
without editing any `.ag` or `gitlab-api.sh` source. Two colonies gain
idempotency guards so long-lived workflow labels no longer drive per-tick
re-posting on the same issue. Operator-facing READMEs and `CLAUDE.md`'s
"Script conventions" paragraph were refreshed to document all four new knobs
and the accompanying memo-seed step. Runtime floor unchanged.

**Requires:** agentis >= 1.4.1

### Added

- **Configurable planning trigger label** — new `[planning] trigger_label`
  key in `planning/config/colony.example.toml`. Operators on projects
  that don't use a flat `needs-planning` label (e.g. scoped-label
  taxonomies like `DEV::not started`) can point the planning colony at
  the local label without edits to the 4 agent files. Default preserves
  pre-#223 behavior. `--data-urlencode` handles scoped labels and spaces
  at the API layer, no new encoding logic required.
  ([#223](https://github.com/Replikanti/agentis-colonies/issues/223))
- **Configurable prompt vocabulary** — new `[planning.labels]` section
  (`incident`, `epic` keys) and `[triage.labels]` section (`priority`
  key) in the respective `colony.example.toml` files. `start-colony.sh`
  seeds these values into memo (`planning:labels:incident`,
  `planning:labels:epic`, `triage:labels:priority`) on every restart;
  `risk_assessor`, `task_decomposer`, and `prioritizer` inject the
  vocabulary into their `prompt()` context arg via `recall_latest()`
  with a hardcoded-default fallback. The agentis parser requires a
  string literal for the prompt instruction arg, so vocabulary flows
  through `context`; instruction strings were rephrased to reference
  the context ("focus on the vocabulary above"). Values are free-text
  so operators can list label names or describe non-label patterns
  (e.g. `"umbrella-issue pattern"`). Unset keys preserve the pre-#226
  vocabulary verbatim — LLM behaviour is semantically equivalent.
  ([#226](https://github.com/Replikanti/agentis-colonies/issues/226))

- **Configurable implementation trigger label**
  ([#225](https://github.com/Replikanti/agentis-colonies/issues/225)) — new
  optional `[implementation] trigger_label` key in
  `implementation/config/colony.toml` lets operators override the
  hard-coded `implementation` label used by
  `gitlab-api.sh assigned-issues` so projects whose workflow taxonomy
  uses a different or scoped label (e.g. `DEV::in progress`) no longer
  have to rename their GitLab labels to match the colony. Scoped labels
  and labels containing spaces are handled safely via
  `--data-urlencode`. Unset configs fall back to `implementation`
  verbatim — fully backward compatible with pre-#225 setups. Mirrors
  the [#223](https://github.com/Replikanti/agentis-colonies/issues/223)
  pattern for the planning colony's `needs-planning` label; agent
  files are unchanged (no `.ag` diff).
- **Configurable primary branch for implementation + release colonies**
  ([#224](https://github.com/Replikanti/agentis-colonies/issues/224)) — new
  optional `[gitlab] default_branch` key in the implementation and
  release colony configs replaces three hard-coded `"main"` references
  in `gitlab-api.sh`: the default `--ref` for `create-branch`, the
  `target_branch` body field on `create-mr` (implementation colony),
  and the default `--ref` for `create-tag` (release colony). Projects
  whose primary branch is `master`, `develop`, `trunk`, or any custom
  name can now configure that once in `colony.toml` instead of
  per-call `--ref` flags. Unset configs fall back to `"main"` — fully
  backward compatible with pre-#224 setups. Explicit-config approach
  chosen over API auto-detect (fails closed when PAT lacks
  project-read scope; zero extra request per colony boot).

### Changed

### Deprecated

### Removed

### Fixed

- **`plan_reviewer` idempotency guard** — new `plan_reviewer:<iid>:posted`
  memo marker short-circuits the `prompt()` + `add-note` path once a
  plan has been successfully posted for an issue at `autonomous` or
  `review-gated` tier. Long-lived workflow labels (e.g. `DEV::not started`
  that persists for days until a human starts work) previously drove
  per-tick re-posting on the same still-labeled issue. The marker is
  written **only** when the GitLab call returns a non-empty body, so
  failed posts (auth/rate-limit/5xx/transport) are retried on the next
  tick instead of silently consumed. `propose`/`shadow` tiers do no
  external write and remain unmarked by design (so a future tier
  promotion isn't blocked by a stale marker).
  ([#223](https://github.com/Replikanti/agentis-colonies/issues/223))

- **Planning peers now short-circuit re-posting to long-lived labeled issues**
  ([#227](https://github.com/Replikanti/agentis-colonies/issues/227)) —
  `risk_assessor`, `scope_estimator`, and `task_decomposer` each gain a
  per-agent `<agent>:<iid>:posted` memo marker written only after a
  successful `add-note` call. Prior to this fix, an issue carrying a
  long-lived workflow label (e.g. `DEV::not started`) would be re-prompted
  and re-posted every autonomous-tier tick for as long as the label
  remained. Follow-up to
  [#223](https://github.com/Replikanti/agentis-colonies/issues/223) which
  applied the same pattern to `plan_reviewer`. The marker is gated on
  non-empty `exec sh` output, so auth/rate-limit/5xx/transport failures
  leave the marker unset and the next tick retries (matches
  `version_bumper.ag`'s tag/release idiom).

### Changed

- **Operator-facing documentation refresh** — `implementation/README.md` and
  `release/README.md` gain Setup bullets for `[gitlab] default_branch`
  (#224); `CLAUDE.md` "Script conventions" now enumerates the real set of
  per-colony `start-colony.sh` exports (GITLAB_ME #104,
  PLANNING_TRIGGER_LABEL #223, IMPLEMENTATION_TRIGGER_LABEL #225,
  GITLAB_DEFAULT_BRANCH #224) and documents the #226 memo-seed step for
  the prompt-vocabulary knobs.
  ([#233](https://github.com/Replikanti/agentis-colonies/pull/233))

### Security

## [0.1.1] — 2026-04-19

First release produced by the tag-triggered `.github/workflows/release.yml`
workflow. Runtime compatibility floor unchanged from `0.1.0`.

**Requires:** agentis >= 1.4.1

### Added

- **Curated install-ready release bundle** — `tools/make-federation-bundle.sh`
  + `dev-apprenticeship/BUNDLE.manifest` assemble a slim tarball
  (`dev-apprenticeship-v<X.Y.Z>.tar.gz`) containing only the paths this
  federation needs at runtime. `.github/workflows/release.yml` runs on every
  `dev-apprenticeship-v*` tag push and attaches the tarball + `.sha256` to the
  GitHub release. End users can now `curl | tar x | install.sh` without
  cloning the repo. ([#220](https://github.com/Replikanti/agentis-colonies/issues/220))

## [0.1.0] — 2026-04-19

Initial versioned release. Backfilled from the commit history on `main` up to the merge of
[#217](https://github.com/Replikanti/agentis-colonies/pull/217) (`144ef80`). Pre-1.0 signals that
cross-colony wiring and ADR-0001 semantics are still evolving; a major bump before 1.0 remains
permissible per semver §4.

**Requires:** agentis >= 1.4.1

### Added

- **Four-tier confidence contract** — named tiers (`shadow` / `propose` / `review-gated` /
  `autonomous`) replace raw numeric thresholds across all 21 agents. Normative contract in
  [`doc/adr/ADR-0001-confidence-tiers.md`](../doc/adr/ADR-0001-confidence-tiers.md). Canonical
  `tier("<agent_name>")` branching pattern; `colony-lint` enforces no inline `confidence >= 0.X`
  literals. ([#175](https://github.com/Replikanti/agentis-colonies/issues/175),
  [#176](https://github.com/Replikanti/agentis-colonies/issues/176),
  [#177](https://github.com/Replikanti/agentis-colonies/issues/177),
  [#178](https://github.com/Replikanti/agentis-colonies/issues/178),
  [#179](https://github.com/Replikanti/agentis-colonies/issues/179))
- **Five-colony federation** — triage, code-review, planning, implementation, release. 22 bus
  events (16 internally wired, 6 extension points). Cross-colony wirings documented in
  [`CLAUDE.md`](../CLAUDE.md#federation-event-wiring).
- **Auto-promote / auto-evolve scheduler** (`tools/auto-promote.sh`) — Layer 1 DMN decision
  table that promotes confidence or triggers `agentis evolve` based on acting-row fitness. Tag
  classification separates `acted`/`review-gated`/`emitted` from `observed` so shadow-mode ticks
  can't earn promotion. Scheduling now installed by `install.sh` and driven by a
  `start-federation.sh` sidecar (no crontab splice). Full reference:
  [`doc/auto-promote.md`](../doc/auto-promote.md).
  ([#148](https://github.com/Replikanti/agentis-colonies/issues/148),
  [#186](https://github.com/Replikanti/agentis-colonies/issues/186),
  [#216](https://github.com/Replikanti/agentis-colonies/issues/216))
- **Federation dashboard** — web UI auto-discovering colonies/agents, operator controls
  (promote, demote, evolve, restart, kill), history snapshotting, per-agent timelines. Split
  into four Python helpers + HTML template; never inline heredocs (macOS bash parser bug). Full
  reference: [`doc/federation-dashboard.md`](../doc/federation-dashboard.md).
  ([#149](https://github.com/Replikanti/agentis-colonies/issues/149),
  [#158](https://github.com/Replikanti/agentis-colonies/issues/158),
  [#160](https://github.com/Replikanti/agentis-colonies/issues/160),
  [#167](https://github.com/Replikanti/agentis-colonies/issues/167),
  [#170](https://github.com/Replikanti/agentis-colonies/issues/170),
  [#172](https://github.com/Replikanti/agentis-colonies/issues/172))
- **Reliable `kill-federation.sh`** — OS-level shutdown of agents + dashboard + registry
  sidecar + backup, bypassing `agentis daemon stop` bugs. Ancestor-chain walk so stale
  dashboards die. `--dry-run` + `--json` for dashboard integration.
  ([#161](https://github.com/Replikanti/agentis-colonies/issues/161),
  [#162](https://github.com/Replikanti/agentis-colonies/issues/162),
  [#188](https://github.com/Replikanti/agentis-colonies/issues/188))
- **Prompt-gate linting** — `tools/check-prompt-gate.sh` ensures every `prompt()` call in a
  ticking colony (implementation, planning, code-review, triage) is preceded by a memo-based
  staleness gate, preventing ~60 LLM-calls/hour waste per stuck issue/MR. Related agent-side
  fixes that first introduced the memo gates are listed under **Fixed** below.
  ([#205](https://github.com/Replikanti/agentis-colonies/issues/205),
  [#208](https://github.com/Replikanti/agentis-colonies/issues/208),
  [#210](https://github.com/Replikanti/agentis-colonies/issues/210))
- **`check-exec-sh.sh`** — grep-based check that all dynamic values in `exec sh` are wrapped
  in `shell_escape()`, with `// colony-lint: safe-exec-concat` opt-out.
- **Per-agent tick intervals** — `tick_interval_for()` case function in each `start-colony.sh`;
  reactive colonies (release, code-review) at 300000 ms, triage's router/prioritizer at
  180000 ms, everything else at 60000 ms.
  ([#146](https://github.com/Replikanti/agentis-colonies/issues/146))
- **Delta-check short-circuit** — 11 reactive agents early-exit when inputs are unchanged,
  skipping the `prompt()` round-trip.
  ([#147](https://github.com/Replikanti/agentis-colonies/issues/147))
- **Auto-confidence from operator feedback** — triage colony adjusts confidence from labeler
  reality checks. ([#106](https://github.com/Replikanti/agentis-colonies/issues/106),
  [#135](https://github.com/Replikanti/agentis-colonies/issues/135))
- **Dashboard confidence UI** — per-agent confidence adjustment from the browser, with
  restart-required toast, null-preserving aggregation.
  ([#105](https://github.com/Replikanti/agentis-colonies/issues/105),
  [#137](https://github.com/Replikanti/agentis-colonies/issues/137),
  [#140](https://github.com/Replikanti/agentis-colonies/issues/140),
  [#143](https://github.com/Replikanti/agentis-colonies/issues/143))
- **Per-operator personal knowledge tag** — agents can recall operator-specific observations
  across GitLab projects.
  ([#104](https://github.com/Replikanti/agentis-colonies/issues/104))
- **ADR-0001 (confidence tiers)** — normative cross-repo contract for tier semantics,
  behavioural restrictions per tier, migration rules from the legacy two-threshold scheme.
- **Interactive `install.sh`** — prereqs check, config copying, GitLab creds prompting,
  confidence seeding, optional auto-promote scheduling install (default Y).
  ([#216](https://github.com/Replikanti/agentis-colonies/issues/216))
- **`watch-suggestions.sh`** — live feed of agent suggestions from all 21 logs, for
  propose-tier agents.
- **`feedback-loop` wiring** — labeler's reality check emits honest outcome signals into the
  experience store so downstream auto-promote has real evidence to act on.
  ([#195](https://github.com/Replikanti/agentis-colonies/issues/195),
  [#202](https://github.com/Replikanti/agentis-colonies/pull/202))

### Changed

- **JSON extraction idiom** — mechanical field reads prefer
  `parse_int(to_string(json_get(raw, "[0].iid")))` over `prompt(...) -> list<T>`, saving one
  LLM round-trip per tick. Migrated across every implementation agent, four code-reviewers
  after [#138](https://github.com/Replikanti/agentis-colonies/issues/138), plan_reviewer after
  [#147](https://github.com/Replikanti/agentis-colonies/issues/147), release ship_decider /
  changelog_writer, and triage agents.
  ([#125](https://github.com/Replikanti/agentis-colonies/issues/125),
  [#131](https://github.com/Replikanti/agentis-colonies/issues/131),
  [#138](https://github.com/Replikanti/agentis-colonies/issues/138))
- **GitLab API responses downselected via `--view`** at the script level instead of in-agent
  prompt massaging. ([#119](https://github.com/Replikanti/agentis-colonies/issues/119))
- **Bash 3.2 / macOS compatibility** — `colony-lint.sh` and dashboard scripts avoid
  `declare -A`, `${var^^}`, `mapfile`, and backslash-newline in case-pattern labels.
  ([#121](https://github.com/Replikanti/agentis-colonies/issues/121),
  [#159](https://github.com/Replikanti/agentis-colonies/issues/159),
  [#170](https://github.com/Replikanti/agentis-colonies/issues/170),
  [#172](https://github.com/Replikanti/agentis-colonies/issues/172))
- **`MIN_VERSION`** floor bumped through a series of runtime upgrades, ending at `1.4.1` for
  fitness_delta signal support.
  ([#129](https://github.com/Replikanti/agentis-colonies/issues/129),
  [#136](https://github.com/Replikanti/agentis-colonies/pull/136),
  [#156](https://github.com/Replikanti/agentis-colonies/pull/156),
  [#185](https://github.com/Replikanti/agentis-colonies/pull/185),
  [#191](https://github.com/Replikanti/agentis-colonies/issues/191))

### Fixed

- Operational-readiness bundle for the dev-apprenticeship install flow.
  ([#116](https://github.com/Replikanti/agentis-colonies/issues/116),
  [#118](https://github.com/Replikanti/agentis-colonies/issues/118))
- `gitlab-api.sh` accepts `--per-page` on merge-requests queries.
  ([#127](https://github.com/Replikanti/agentis-colonies/issues/127))
- **Planning observe step** rate-limited to 30 minutes to cut LLM waste in shadow mode.
  ([#187](https://github.com/Replikanti/agentis-colonies/issues/187))
- **Implementation colony memo gate** — `code_writer` / `test_writer` / `refactorer` /
  `commit_composer` no longer burn a `prompt()` each tick on the same already-processed MR;
  a memo-based staleness gate short-circuits the hot path.
  ([#200](https://github.com/Replikanti/agentis-colonies/issues/200))
- **Code-review colony memo gate** — `logic_reviewer` / `style_reviewer` /
  `security_reviewer` / `test_reviewer` apply the same memo-based staleness gate before each
  `prompt()` call. ([#201](https://github.com/Replikanti/agentis-colonies/issues/201))

### Security

- All dynamic values flowing into `exec sh` are required to pass through `shell_escape()`;
  `check-exec-sh.sh` enforces this grep-level contract.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.3...HEAD
[0.3.3]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.2...dev-apprenticeship-v0.3.3
[0.3.2]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.1...dev-apprenticeship-v0.3.2
[0.3.1]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.0...dev-apprenticeship-v0.3.1
[0.3.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.2.0...dev-apprenticeship-v0.3.0
[0.2.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.1...dev-apprenticeship-v0.2.0
[0.1.1]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.0...dev-apprenticeship-v0.1.1
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dev-apprenticeship-v0.1.0
