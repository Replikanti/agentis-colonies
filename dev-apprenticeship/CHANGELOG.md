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

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.1...HEAD
[0.1.1]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.0...dev-apprenticeship-v0.1.1
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dev-apprenticeship-v0.1.0
