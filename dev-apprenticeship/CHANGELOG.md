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

- First-real-task **completion criterion + post-run triage protocol**
  (#1116 / #1118). New `doc/dev-apprenticeship-first-task.md` pins down,
  *before* the first end-to-end run (#1117), the two things that were
  never defined: (1) a single binary, non-author-checkable **completion
  criterion** — the federation "completed" a nominated ~1h bounded task
  iff it opened a PR that is mergeable **and** passes the gate green
  (`colony-lint.sh` 0-failed + required CI) — plus an explicit
  **human-intervention boundary** (operator may fix the environment —
  infra/creds/prompts/I-O/restarts/tiers — but may not produce the work
  being measured; crossing that invalidates the run); and (2) a standing
  **post-run triage** rule (fail → file a `dev-apprenticeship` issue
  naming the exact failure mode with `cost-rate-report.sh` (#1114)
  evidence and fix that; succeed → record the completion and nominate the
  next task; **never** close a `dev-apprenticeship` issue with a
  cut-reason instead of a fix-reason or recorded data point). New
  `tools/completion-gate.sh <fed-dir> <target-issue> --pr <N>` makes the
  criterion script-checkable — prints `[PASS]`/`[FAIL]` per condition (PR
  mergeable, CI green, local colony-lint 0-failed) and an overall verdict,
  exits non-zero unless all pass (no heredocs, dash-safe ASCII markers).
  Both the doc and the gate are bundled (added to `BUNDLE.manifest`) and
  linked from the federation README. The run itself (#1117) is
  operator-driven (live federation, real backend, operator's repo); this
  is the pre-run scaffolding that makes its outcome objective.
- Shared GitLab snapshot + payload compression for the Triage colony
  (#1111 / #1112). The `issues` collection is now fetched **once per
  colony per tick** and shared via a memo instead of each of the four
  triage agents (labeler / router / prioritizer / issue_creator)
  curling it independently (the former 3–4× duplicate fetch per tick).
  `triage/scripts/start-colony.sh` publishes the snapshot to
  `gitlab:snapshot:issues` (+ epoch freshness key
  `gitlab:snapshot:issues:ts`) via the new `forge-api.sh snapshot issues`
  verb on bootstrap, and standalone via `--snapshot-refresh`. The
  snapshot is **compressed before it reaches `prompt()`**: the new
  `triage/scripts/snapshot-compress.py` (normalized-subtree-hashing,
  reusing the `dark-factory/evm-harness/struct-sig.js` concept)
  normalizes each item to role-relevant fields, content-addresses each
  item's structure, interns repeated structures once, and references
  them by index — deterministic + byte-stable, ~11× smaller than raw
  on a realistic 20-issue payload. Agents read the memo via a new
  `snapshot_issues_cmd()` helper and render their role view with
  `forge-api.sh issues --from-snapshot --view <role>` (zero HTTP).
  Backward-safe: a missing / empty / stale (> 600 s) / malformed
  snapshot transparently degrades to the legacy direct fetch, and the
  shared snapshot is used only on the single-repo path (multi-repo
  fan-out keeps its per-repo fetch). Both `gitlab-api.sh` and
  `github-api.sh` gained the symmetric `snapshot` verb +
  `--from-snapshot` flag. The `merge_requests` collection in the other
  four colonies uses label-event-filtered reads and is deferred to the
  live run (#1117). Three follow-up fixes harden the snapshot path:
  - **Snapshot-refresh sidecar (#1111).** `start-federation.sh` now
    runs a background loop that re-publishes the shared snapshot every
    300 s (override via `SNAPSHOT_REFRESH_INTERVAL_S`) — shorter than
    the 600 s freshness window — so the snapshot never goes stale and
    the agents never permanently fall back to per-agent direct fetches
    (the exact I/O problem #1111 fixes). It mirrors the auto-promote /
    cost-cap sidecars (self-terminates on zero running daemons,
    EXIT/TERM/INT trap) and is backward-safe (refresh failures are
    logged to `.agentis/logs/snapshot-refresh.log`, never fatal).
  - **Full `description` for the issue_creator view (#1112).**
    `snapshot-compress.py` previously kept only a 200-char `desc_head`,
    but the `issue_creator` view consumes the full `description`, so its
    rehydrated input was truncated vs. the legacy direct fetch. The
    compact form now carries the untruncated `description` (only the
    issue_creator view projects it; labeler/router/prioritizer drop it),
    making the rehydrated issue_creator `description` byte-identical to
    the direct-fetch value. `--self-test` gained a full-description
    fidelity assertion.
  - **Quiet-project prompt suppression on the snapshot path (#1111).**
    The shared snapshot is the full collection (not a `--since` delta),
    so `raw` is non-empty every tick even when nothing changed, causing
    `prompt()` on every tick. labeler / router / prioritizer now
    fingerprint (SHA-256) their projected view, memo it as
    `<agent>:snapshot_hash`, and skip `prompt()` on a tick whose
    fingerprint matches the last-processed one — an additional gate that
    restores the legacy `--since`-empty early-exit (one `tier()` call
    per tick and the existing prompt-gate are preserved).
- Cross-repo reference detection in PR review prompts (#317): the four
  code-review agents (logic / style / security / test) scan PR body
  for `<owner>/<repo>#<N>` references and splice resolved issue context
  (title / state / labels) into their review prompt — capped at 5 refs
  per tick. Resolved records cached at
  `<fed>/.agentis/cross-repo-cache/<owner>__<repo>__<N>.json` with 1h
  TTL (override via `CROSS_REPO_CACHE_TTL_SECS` env). Out-of-colony
  repos resolve to a tombstone and skip silently. Reviewer view of
  `merge-requests` gains `description` for the scanner. Triage `router`
  agent gains bidirectional closed-by lookup. Single-block configs
  (M3a sentinel) skip the scan entirely (byte-identical). Helpers:
  `tools/{scan-cross-repo-refs,cross-repo-cache,resolve-cross-repo-ref,
  closed-by-index}.{sh,py}`. Test: `tools/test-cross-repo-refs.sh` (7
  cases). Dashboard timeline overlay deferred to follow-up.

- **Cost / rate instrumentation report + sidecar (#1114).** New
  `tools/cost-rate-report.sh <fed-dir> [--json] [--baseline] [--self-test]`
  (all Python in `tools/cost-rate-report.py`, no heredocs) folds each
  colony's per-prompt spend rows
  (`<fed>/<colony>/.agentis/spend/<agent>.jsonl`, #311 — one row ≈ one
  prompt) plus `agentis stats --json --per-identity` into a
  machine-readable per-agent **and** per-role (per-colony) record:
  `prompts`, `prompts_per_hour` (rolling over the trailing window from row
  `ts`), `chars_in` (proxy: `avg_input_size` × prompts), `chars_out`
  (proxy: Σ `output_tokens`), `cost_usd` (Σ `cost_usd`, null → 0), a
  **throttle vs task-error split** (`throttle_events` = forge-429 /
  `[llm.cancelled]` rows; `task_errors` = agent failure markers — kept as
  separate fields end to end), and `retries` (0 with a documented note:
  spend rows do not carry a colony-side retry count today, so the field is
  wired but reads 0 until the runtime emits it). Default output is one
  compact line per role (`role=… prompts=… pph=… cin=… cout=… cost=…
  throttle=… retries=…`); `--json` emits the structured object;
  `--baseline` stamps the pre-fix number (~74 KB/agent) to
  `<fed>/.agentis/logs/cost-rate-baseline.json` so improvements are
  provable. A **4th `start-federation.sh` sidecar** runs the report every
  `COST_RATE_INTERVAL_S` (default 60 s) to `.agentis/logs/cost-rate.log`,
  mirroring the snapshot-refresh / cost-cap / auto-promote sidecars
  exactly (tick-first emit, `''|*[!0-9]*` / `-gt 0` interval validation,
  self-terminate on zero running daemons, EXIT/TERM/INT trap that also
  kills the new `COST_RATE_PID`, backward-safe skip-with-warning when the
  report is not executable). `--self-test` seeds a synthetic spend.jsonl +
  stats fixture in a temp dir and asserts every field including the
  throttle-vs-error split and the baseline stamp. **Operator-run-gated /
  upstream (NOT in this PR):** the real-backend baseline number, the
  ≥ 90 % prompt-cache-hit DoD line, and the induced-rate-limit recovery
  line all require a live LLM backend and are operator-run. The
  LLM-backend HTTP-429 backoff / prompt cache that produces
  `[llm.cancelled]` rows lives in the agentis runtime / LLM backend
  (handled upstream); this report only observes the resulting rows. Tools
  added to `BUNDLE.manifest`.

- **Per-tick CB cap + forge rate-limit backoff (#1115).** Two colony-side
  guardrails:
  - **`--cb-per-tick` cap.** All five colonies' `start-colony.sh` now
    splice `--cb-per-tick <n>` onto every `agentis daemon` launch (both the
    normal launch and the `--restart-agent` respawn path), config-driven
    via a new `cb_per_tick_for()` helper that mirrors the per-agent
    `--tick-interval` pattern (#146): a per-agent `cb_per_tick` under the
    matching `[[agents]]` entry wins, else the colony-wide
    `[colony].cb_per_tick` default, else 2000 (matching
    `daemon.cb_per_tick` in `<fed>/.agentis/config`). The example configs
    document the key. Unlike `--config-override` (#351), `--cb-per-tick` is
    a real `agentis daemon` flag, so this lands on the binary. A runaway
    tick can no longer burn the whole budget in one pass.
  - **Jittered forge-429 backoff + observable rate-limited state.** Every
    colony's `gitlab-api.sh` retry loop now adds equal-jitter on top of its
    existing exponential backoff (`_backoff_sleep`: slept value in
    `[delay, delay + delay/2]`) so simultaneous retries from many agents do
    not synchronise into a thundering herd. The agents that act on forge
    writes (`approval_decider`, `risk_assessor`, `plan_reviewer`) detect a
    rate-limited write (via the `rate-limit-status` contract), record a
    growing jittered backoff window in a `<agent>:rate_limited_until` memo,
    emit a `<colony>:rate-limited` event, and **defer** rather than mark the
    task failed; a successful write clears the state. `--cb-per-tick` and
    the LLM-backend HTTP-429 backoff are distinct layers: the latter lives
    in the agentis runtime / LLM backend (handled upstream). Test:
    `tools/test-rate-limit-backoff.sh` stubs a 429-on-every-attempt forge
    call and asserts the backoff delays grow within their jitter bounds,
    the call gives up after the retry budget (no retry storm), and the
    rate-limited memo + emit + defer wiring is present. **Operator-run-gated
    (NOT in this PR):** the live induced-rate-limit recovery DoD line
    requires a real backend and is operator-run; this PR ships the
    mechanism + synthetic proof. The `rl_is_limited` helper guards the
    null/absent-`remaining` case (`to_string(json_get(...)) == "void"` →
    not limited) so a genuine forge failure on an instance that emits no
    `RateLimit-*` headers (null `remaining`, e.g. self-hosted GitLab with
    rate limiting disabled) is no longer misclassified as a rate-limit and
    swallowed into backoff — only a real numeric `remaining == 0` trips the
    rate-limited path.

### Fixed

- GitLab issue-collection rename (#1119): GitLab migrated the
  issue-tracking REST collection from `/issues` to the unified
  `/work_items` collection, which broke every issue read/write on a
  migrated instance. Each colony's `gitlab-api.sh` (triage / planning /
  implementation / code-review) now resolves the collection segment in
  one place via `ISSUE_COLLECTION="${GITLAB_ISSUE_COLLECTION:-work_items}"`
  and routes all issue reads, writes, `/notes`, and
  `/resource_label_events` sub-paths through it. Default is `work_items`;
  set `GITLAB_ISSUE_COLLECTION=issues` to pin the legacy path on a
  non-migrated instance (no code change). `release/gitlab-api.sh` defines
  the same knob for cross-script consistency (it only talks to
  `/merge_requests` today). Documented in the README troubleshooting
  section.

## [2.0.0] — 2026-04-29

**Requires:** agentis >= 1.4.7
**Recommends:** federation-dashboard >= 0.8.0

This release ships full multi-repo capability across the federation (#316
M1-M6) and **retires the legacy single-table `[forge.github]` config form**.
Operators upgrading from v1.x MUST run the migration recipe in the
`### Removed` block below before starting v2.0.0; the migration is
idempotent and byte-identical at runtime.

### Added

- Multi-repo schema (#316 M1): a colony's `[forge.github]` may now be repeated as
  array-of-tables `[[forge.github]]`. Each entry has its own `owner / repo / token /
  url / me`. Single-block `[forge.github]` continues to work unchanged in this
  release. Per-repo runtime + per-repo confidence + per-repo dashboard tiles ship
  in follow-up PRs M2-M5; M6 retires the single-block form (MAJOR, v2.0.0).
- `tools/parse-toml.sh` grows three entrypoints: `parse_toml_array_count`,
  `parse_toml_array_get`, `parse_toml_array_keys` (delegates to the existing
  `parse-toml-secret.py` helper, no new dependencies).
- `tools/migrate-to-multi-repo.sh` rewrites a legacy single `[forge.github]`
  block to a single-entry `[[forge.github]]` array. Idempotent. Preserves
  operator hand-edits.
- Multi-repo runtime wiring (#316 M2): when a colony.toml uses the
  `[[forge.github]]` array form, all 5 `dev-apprenticeship/*/scripts/
  start-colony.sh` scripts now export `GITHUB_REPOS_JSON` — a JSON array
  carrying every entry's resolved `{url, owner, repo, token, me}` —
  alongside the existing `GITHUB_OWNER`/`GITHUB_REPO`/`GITHUB_TOKEN`/
  `GITHUB_URL`/`GITHUB_ME` env vars. Back-compat: single-block configs
  continue to set only the latter; multi-block configs additionally set
  the back-compat vars from entry [0] so M2-only deployments keep
  working against the first repo until M3 lands per-repo iteration in
  agents. `secret://` URI tokens resolve to plaintext before
  serialisation. The existing `dev-apprenticeship/.agentis/config`
  `exec.env_passthrough = ...,GITHUB_*` glob carries `GITHUB_REPOS_JSON`
  through to `exec sh` children for free.
- Multi-repo runtime (#316 M3a): `forge-api.sh` accepts `--repo <owner/repo>` flag
  resolving the matching `[[forge.github]]` entry's token/url/me from
  `GITHUB_REPOS_JSON`. The 4 triage agents now iterate per-repo on each tick
  (M3b will fan out to the remaining 17 agents); experience rows tagged
  `repo:<owner>/<name>`; per-repo state memos use
  `<owner>__<repo>:<agent>:<suffix>` keys (double-underscore separator
  avoids `/` in memo keys, which the runtime treats as a path component).
  Single-block `[forge.github]` configs continue to work byte-identically —
  same call-graph, same experience rows, same memo keys, same `.ag` source.
  `tools/iter-repos.sh` is the per-tick fan-out helper. ADR-0002 grows a
  "Multi-repo dispatch" subsection. Per-repo confidence keys ship in M4;
  per-repo trigger label vocabulary in M5.
- Multi-repo runtime (#316 M3b): the remaining 17 agents (5 code-review + 4 planning
  + 4 implementation + 4 release) now iterate per-repo on each tick, completing the
  M3 fan-out started in M3a (4 triage agents, PR #381). All 21 agents in
  dev-apprenticeship now serve N repositories from one colony when `colony.toml`
  uses the `[[forge.github]]` array form. Single-block configs continue to work
  byte-identically.
- Multi-repo runtime (#316 M4): per-repo confidence keys + `repo_tier()` helper.
  All 21 agents now read tier via `repo_tier("<agent>", owner, repo)` instead of
  the runtime `tier("<agent>")` builtin. The helper looks up
  `<owner>__<repo>:<agent>:confidence` first, falls back to the legacy unscoped
  `<agent>:confidence` when missing, and maps to the same five-tier string set
  the runtime returns using ADR-0001 thresholds. Single-block configs (M3a
  sentinel `owner==""`) bypass the scoped lookup entirely and stay
  byte-identical to legacy. Operators set per-repo divergence via
  `agentis memo set acme__frontend:labeler:confidence 0.95`; the legacy
  unscoped key continues to govern every repo without an override.
  `labeler.ag`'s reality-check `apply_feedback()` now writes to the per-repo
  memo so per-repo confidence drifts independently. `auto-promote.sh` per-repo
  writes ship in a follow-up; until then the sidecar continues to write only
  the unscoped key. `colony-lint.sh` gains a check failing on direct `tier()`
  calls inside `fn tick_for_repo`.
- Multi-repo runtime (#316 M5): per-repo trigger label memo seeding. `triage`,
  `planning`, and `implementation` start-colony.sh now read each
  `[[forge.github]]` entry's `labels = { trigger = "..." }` inline table and
  seed `<owner>__<repo>:<colony>:labels:trigger` on full-colony bootstrap.
  Single-block configs continue to seed only the legacy unscoped vocabulary
  memos. `tools/parse-toml.sh` grows `parse_toml_array_get_inline` for
  inline-table subkey lookup. **Recommends:** federation-dashboard >= **0.8.0**
  (M5b) for the per-repo Forge Rate Limits + confidence overlay on dashboard.

### Deprecated

- Single-table `[forge.github]` (and by symmetry `[forge.gitlab]`). The form
  remains valid throughout the v1.x line; M6 (#316, scheduled v2.0.0) retires
  it. Run `tools/migrate-to-multi-repo.sh <colony.toml>` to migrate ahead of
  the cutover.

### Removed

- Legacy single-table `[forge.github]` config form (#316 M6, MAJOR). Use
  `[[forge.github]]` array-of-tables instead — single-entry arrays are
  byte-identical at runtime to the retired single-table form. **Breaking**
  for operators upgrading from v1.x — run
  `tools/migrate-to-multi-repo.sh <colony.toml>` once per colony before
  starting v2.0.0. `colony-lint.sh` now hard-fails on a single-table
  `[forge.github]` block with the migration command in the error message.
  `[forge.gitlab]` single-table form is **unchanged** in v2.0.0 — its
  symmetric retirement waits for a future GitLab multi-repo runtime
  milestone.

  Migration recipe:

  ```bash
  for colony in triage code-review planning implementation release; do
    ./tools/migrate-to-multi-repo.sh dev-apprenticeship/$colony/config/colony.toml
  done
  ./tools/colony-lint.sh dev-apprenticeship/
  ./dev-apprenticeship/kill-federation.sh
  ./dev-apprenticeship/start-federation.sh
  ```

  The migration tool is idempotent (test 11 of `test-multi-repo-schema.sh`).

## [1.3.0] — 2026-04-26

LLM cost-cap and per-colony LLM-backend wiring continue maturing. New
production-ready agent template catalog (1 canary + 5 templates:
`dependency-updater`, `security-scanner`, `release-manager`, `pr-triage`,
`digest-poster`) ships with `tools/scaffold-agent.sh`. Operator-facing
**test-mode replay** docs + `tools/replay-export-experience.sh` (paired
with the upstream `agentis replay` engine that follows). Federation
**experience transfer** via `tools/experience-transfer.sh` lets a fresh
federation bootstrap from a healthy donor's experience JSONL — clear
auto-promote `min_entries` prereq in hours instead of weeks. Official
multi-arch **Docker image** at `ghcr.io/replikanti/agentis-colonies` +
sample `examples/k8s/` and `examples/docker/` manifests. Per-colony
`[llm]` config block plumbing landed but is currently a no-op (see
Fixed: `start-colony.sh` change for #351 — `agentis daemon` does not
yet accept `--config-override`; cost-cap downgrade is also no-op until
upstream lands the flag).

**Requires:** agentis >= **1.4.7** (unchanged from 1.2.0; cost-cap
consumes the per-agent JSONL spend log shipped by [agentis-core
1.4.7+](https://github.com/Replikanti/agentis/releases/tag/v1.4.7)).
**Recommends:** federation-dashboard >= **0.6.0** (pinned via
`dev-apprenticeship/.dashboard-version`; tabbed layout, sidecar
listing, bulk-restart, Config tab — operators get a focused
single-screen-per-tab view instead of the long-scroll layout).

### Fixed

- `start-colony.sh` no longer splices a non-existent `--config-override llm.<key>=<value>` flag onto the `agentis daemon` command line ([#351](https://github.com/Replikanti/agentis-colonies/issues/351)). PR [#348](https://github.com/Replikanti/agentis-colonies/pull/348) (#319 PR 1) and the cost-cap downgrade path (#318) both relied on a CLI flag that `agentis daemon` does not actually accept (`agentis daemon --help` lists `--tick-interval` / `--cb-per-tick` / `--deadline` / `--priority` / `--colony` / `--enable-*` / `--skip-prompt-*` only — no `--config-override`). On every respawn that hit either the colony-toml `[llm]` block or the cost-cap `<fed>/.agentis/llm-backend-override` file, `agentis daemon` errored out with `unknown flag: --config-override` and the spawn died inside `start-colony.sh`'s 0.5-second liveness probe, exiting 4 with `agentis daemon failed to launch <agent>`. Live impact on the dev-apprenticeship federation: `risk_assessor` got watchdog-killed for stale heartbeat earlier in the day and could not be revived by `start-colony.sh --restart-agent`, leaving the federation indefinitely at 19/20 (and any other agent killed by the watchdog post-#348 would have the same fate). Fix collapses `llm_override_args()` to a no-op in all five colonies; the `[llm]` block stays in the schema as forward-compatible documentation but emits no daemon flags. Cost-cap's downgrade path is reduced to no-op for the same reason — the override-file write succeeds but its value is never consumed; the `tools/cost-cap.sh` sidecar continues to track usage and emit warnings via `cost-cap-banner.json`, but the actual backend swap on metered breach waits on upstream agentis ([Replikanti/agentis](https://github.com/Replikanti/agentis)) shipping `--config-override`. `tools/test-llm-per-colony.sh` rewritten to assert the new contract (16 PASS): no `llm.*` overrides emitted in any of the 5 historical scenarios, no `--config-override` token ever appears in the recorded argv (regression guard), `--restart-agent` succeeds even with both an `[llm]` block AND a cost-cap override file present.

### Added

- Per-colony `[llm]` config block + `start-colony.sh` wiring ([#319](https://github.com/Replikanti/agentis-colonies/issues/319), PR 1 of 5 — first-class multi-LLM backend; PRs 2-5 follow with the portable pricing registry, swap-without-restart primitive, install-flow + dashboard chip, and the release pair). Each colony's `config/colony.example.toml` already shipped a stub `[llm] backend = "cli"` line marked "informational only" — this PR makes it functional. Four optional keys are now consumed by `<colony>/scripts/start-colony.sh` and spliced onto every `agentis daemon` invocation as `--config-override llm.<key>=<value>`: `backend` (`mock` / `cli` / `http`), `command` (consumed by the `cli` backend), `model` and `api_key_env` (consumed by the `http` backend). All four are OPTIONAL — when absent, the agent inherits the federation-wide default from `<fed>/.agentis/config` (the install-flow's `step 4` setup). The pre-existing `<fed>/.agentis/llm-backend-override` cost-cap downgrade file ([#318](https://github.com/Replikanti/agentis-colonies/issues/318)) takes precedence over the `[llm]` block: when the cost-cap sidecar trips a metered breach and writes `mock` into the override file, every daemon picks `mock` cleanly without leaking colony-specific `command` / `model` / `api_key_env` keys onto the CLI. Pre-#319 colonies (no `[llm]` block at all) emit zero `--config-override` flags and stay byte-identical to v1.2.0 behaviour. Operator outcome: `[llm] backend = "http"` in `triage/config/colony.toml` while `release/config/colony.toml` keeps `backend = "cli"` flips the four triage daemons to a low-stakes Ollama / OpenAI endpoint while reserving Claude for `release/ship_decider`. Wired in all five colonies (`triage`, `code-review`, `planning`, `implementation`, `release`); the existing `cost_cap_override_args` helper is renamed `llm_override_args` since it now serves both the colony block and the override-file path. The `--config-override` daemon flag was already on the `colony-lint.sh` allowlist (PR 7 of [#256](https://github.com/Replikanti/agentis-colonies/issues/256)) so no lint changes were needed. Test coverage in `tools/test-llm-per-colony.sh` (5 cases: no `[llm]` block emits zero overrides, `mock` emits one, `cli` + `command` emits two, `http` + `model` + `api_key_env` emits three, cost-cap override-file precedence asserts the `[llm]` block is ignored when the override file exists). PR 1 does NOT close [#319](https://github.com/Replikanti/agentis-colonies/issues/319) — PR 5 (the release pair) is the closer. Out of scope for PR 1 and deferred per the lgtm'd plan: per-agent `[llm]` block (`@llm("...")` decorator on `tick()`), portable pricing registry under `tools/llm-pricing.toml` (PR 2), generalising the cost-cap override file into a small TOML doc with `model` / `endpoint` keys (PR 3), interactive backend prompt in `install.sh` step 6 (PR 4), and the dashboard's per-colony backend column + `cost_source` chip (PR 4).
- Two portability pre-built agent templates ([#322](https://github.com/Replikanti/agentis-colonies/issues/322), PR 3 of 3 — completes the v1 catalog at 1 canary + 5 production templates total): `templates/agents/pr-triage.ag` (CODEOWNERS-style reviewer assignment; `propose` emits a `<colony>:reviewer_suggestion` bus event with the matched reviewer CSV, `review-gated` posts an `@-mention` comment on the PR — non-terminal so the operator still formally requests the review, `autonomous` actually requests review via the forge API's `request-reviewers` verb with graceful fall-through to the review-gated `@-mention` surface when the colony's `forge-api.sh` does not yet implement the verb; CODEOWNERS path knob `[pr_triage].codeowners_file` defaults to `.github/CODEOWNERS` and is read at exec time via `recall_latest("pr_triage:codeowners_file")` so operators can hot-edit the location; last-match-wins glob semantics matching the canonical GitHub / GitLab CODEOWNERS rule; `cb 100;`), and `templates/agents/digest-poster.ag` (daily / weekly summary of merged PRs + closed issues + recent release tags rendered into a markdown digest; `propose` emits a `<colony>:digest_draft` bus event, `review-gated` posts the digest to a configured `[digest_poster].digest_thread_iid` issue thread but only after the operator stamps `digest_poster:last_approved_draft` with a non-empty value — an explicit approval handshake, `autonomous` posts on a fixed schedule (default `weekly@mon@09:00` UTC; configurable to `daily@HH:MM` or `weekly@<dow>@HH:MM`) parsed by inline python3 with a 12h debounce; falls back to the review-gated `digest_draft` bus surface when `digest_thread_iid` is not configured; `[digest_poster].window_days` defaults to 7 to match the weekly cadence; `cb 150;`). Both follow the canonical `tier()` + per-tier `learn(..., [...])` + `memo_write("<agent>:last_check", now)` + `shell_escape()` + `parse_int(to_string(json_get(..., "[0].iid")))` patterns from CLAUDE.md "Agent conventions"; both ship with the standard `// TEMPLATE: <name> — <purpose> | customization: <points>` header. Test coverage extends `tools/test-scaffold-agent.sh` to 15 cases (13 from PR 1 + PR 2 + t14 pr-triage scaffold + tier-branch + `memo_write` + `shell_escape` checks, t15 digest-poster scaffold + tier-branch + `memo_write` + `cb 150` header + the schedule-parsing python3 inline regression guard against scaffolder substitutions mangling the multi-line schedule parser). `templates/README.md` catalog table now lists all five production templates with a closing line declaring v1 catalog completion (1 canary + 5 production: `dependency-updater` / `security-scanner` / `release-manager` / `pr-triage` / `digest-poster`).
- Three high-impact pre-built agent templates ([#322](https://github.com/Replikanti/agentis-colonies/issues/322), PR 2 of 3 — the catalog half; the two portability templates `pr-triage` + `digest-poster` follow in PR 3): `templates/agents/dependency-updater.ag` (Dependabot-style PR triage; `propose` drafts a "good to merge" assessment as a PR comment, `review-gated` posts an LGTM approval note, `autonomous` actually merges after CI green + no conflicts + denylist miss with graceful fall-through to the review-gated surface when the colony's `forge-api.sh` does not yet implement a `merge` verb; operator-configurable via `[dependency_updater].denied_packages` surfaced through `recall_latest("dependency_updater:denied_packages")` so the list can be hot-edited without restarting the daemon; `cb 100;`), `templates/agents/security-scanner.ag` (auto-detects `npm` / `cargo` / `pip` audit toolchain by lockfile presence at `$COLONY_DIR/..`, runs the corresponding audit command on a daily-windowed cadence regardless of tick interval — the 24h window guard is enforced in `tick()` because reactive colonies tick at 5 min and we do not want to re-run `npm audit` against `node_modules/` every five minutes; `propose` emits the result on the bus, `review-gated` files an issue via `forge-api.sh create-issue`, `autonomous` additionally assigns the issue to the on-call rotation when `[security_scanner].oncall_handle` is configured; `cb 200;`), and `templates/agents/release-manager.ag` (a generalised, repo-agnostic version of `release/agents/ship_decider.ag`; `propose` emits a release-window assessment with a Keep-a-Changelog-style draft block, `review-gated` opens a "release: vX.Y.Z" PR via `forge-api.sh create-mr`, `autonomous` merges + tags + creates the release ONLY when `[release_manager].auto_tag = "true"` is explicitly opted in AND no release happened in the last 24h — built-in double-release guard prevents back-to-back tags from a single bad LLM call; `cb 150;`). All three follow the canonical `tier()` + per-tier `learn(..., [...])` + `memo_write("<agent>:last_check", now)` + `shell_escape()` + `parse_int(to_string(json_get(..., "[0].iid")))` patterns from CLAUDE.md "Agent conventions"; each ships with a `// TEMPLATE: <name> — <purpose> | customization: <points>` header so operators can grep the catalog. Test coverage extends `tools/test-scaffold-agent.sh` to 13 cases (10 from PR 1 + t11 dependency-updater scaffold + tier-branch + `memo_write` + `cb 100` header check, t12 security-scanner scaffold + every `exec sh` string-concat is `shell_escape`-wrapped, t13 release-manager scaffold + `cb 150` header round-trips byte-for-byte through the scaffolder); structural grep-based checks rather than full agentis-binary lint because headless `.ag` linting on synthetic fixtures would require an `agentis` install on every CI runner. `templates/README.md` catalog table extends to a six-column form (Template / Purpose / At `autonomous` / Required env / Recommended placement / Status) so operators can see at a glance which colony shape each template needs (e.g. `dependency-updater` lands well in a colony that already has merge-requests + post-note + merge surface; `security-scanner` lands well in a triage-shaped colony with `create-issue` + `update-issue`).
- Pre-built agent template scaffolding via `tools/scaffold-agent.sh <template> <federation> <colony>` ([#322](https://github.com/Replikanti/agentis-colonies/issues/322), PR 1 of 3). Opens the path for the curated catalog landing in follow-up PRs. The canary `stale-issue-closer` template ships under `templates/agents/` for round-trip testing of the scaffolding plumbing — copy the `.ag` into an existing colony's `agents/` directory, optionally rename via `--name`, optionally overwrite via `--force`. The scaffolder resolves `<federation>` against the repo root first then as an absolute path (mirrors `tools/auto-promote.sh` / `tools/cost-cap.sh`), asserts the destination colony has the conformant `agents/` + `scripts/start-colony.sh` shape per [ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md), and prints a single machine-friendly `scaffolded <template> -> <colony>/agents/<local-name>.ag` line on stdout. Exit codes: 0 ok, 1 destination conflict (re-run with `--force`), 2 template / federation / colony not found, 3 unknown flag. The `templates/` tree is contributor-only and is excluded from `colony-lint.sh`'s federation discovery (the `.ag` files are linted only after they have been scaffolded into a real colony). Test coverage in `tools/test-scaffold-agent.sh` (10 cases — happy path, destination conflict, `--force`, bogus template / federation / colony, non-conformant colony detection in two flavours, `--name` rename, repo-relative federation resolution). Bash 3.2 portable (no heredocs, `__TEMPLATE_NAME__` / `__COLONY_NAME__` substitution via inline python3, matching `tools/cost-cap.sh` precedent). The canary template's runtime is not yet wired into a colony — it ships purely so PR 2/3 can scaffold against a pipeline that already round-trips the canary. Catalog rollout (`dependency-updater`, `security-scanner`, `release-manager`, `pr-triage`, `digest-poster`) follows in PRs 2 and 3 of the same issue.
- Operator-side reference for **test-mode replay** ([#320](https://github.com/Replikanti/agentis-colonies/issues/320)). Adds [`doc/replay-mode.md`](../doc/replay-mode.md) (when to score a candidate `.ag` against history vs use the auto-promote ladder, the five-step export → modify → replay → diff → deploy flow, and how the verdict composes with [`auto-promote`](../doc/auto-promote.md) and the [`feedback-loop`](../doc/feedback-loop.md) reality-check pattern), `tools/replay-export-experience.sh` (a thin wrapper that walks `<fed>/.agentis/experience/<agent_id>.jsonl`, remaps each id to its agent name via `agentis daemon list --json` so the candidate matches even when its eventual id differs from the historical one, and emits a single replay-friendly JSONL pack with the same parent-fallback resolver auto-promote uses for the symlinked single-federation layout), and a sample fixture under `examples/replay/` (a stub `candidate_labeler.ag` plus a 15-row synthetic pack) that lets operators dry-run the flow before exporting from a live federation. The replay engine itself ships in a separate upstream `agentis` release; this colonies-side PR lands the operator surface against `agentis >= TBD` (release-PR fixup once the upstream MINOR is tagged) per the two-PR split rationale on the issue. If [#323](https://github.com/Replikanti/agentis-colonies/issues/323) (`tools/experience-transfer.sh`) lands, the replay export will delegate to it via `experience-transfer.sh export --replay-pack`; until then the wrapper carries the minimal walk replay needs.
- Federation experience transfer. New `tools/experience-transfer.sh` exports a healthy federation's per-agent experience JSONL into a portable `pack.tar.gz` keyed by agent **name** (since `agent_id = sha8(...)` never lines up across federations) and re-imports into a fresh federation by remapping name to the recipient's current `agent_id`. Operator opt-in only — nothing in `start-federation.sh` or `install.sh` runs the transfer automatically. Filtering flags `--since YYYY-MM-DD`, `--tags t1,t2`, `--max-rows-per-agent N`, and `--scrub` (strips PII-suspect `in` / `signal.in_summary` / `signal.title` fields plus `forge_user=*` and `assignee=*` tags) cover the common privacy posture before sharing outside the donor's org. Every imported row gets a `donor=<src-fed-name>` tag stamped on so the auto-promote sidecar (`tools/auto-promote.sh`) and dashboard can distinguish imported rows from native ones in later visualisation passes. Re-imports are idempotent: rows are deduped by sha256 of the canonical JSON line. Knowledge transfer is documented as the one-line `agentis knowledge export | import` workflow in `dev-apprenticeship/README.md` and reuses existing upstream tooling — no new code there. Implementation portable on macOS bash 3.2 (no heredocs, no `declare -A`); JSONL / tar / scrub / dedupe logic lives in `tools/experience-transfer-pack.py` matching the precedent set by `auto-promote-decisions.py` and `cost-cap-sum.py`. Test coverage in `tools/test-experience-transfer.sh` (13 cases — round-trip row counts, each filter flag, name remap, dedupe idempotency, missing-agent skip, malformed pack, schema-version skew) ([#323](https://github.com/Replikanti/agentis-colonies/issues/323)).
- Official multi-arch Docker image at `ghcr.io/replikanti/agentis-colonies` ([#324](https://github.com/Replikanti/agentis-colonies/issues/324)). Top-level `Dockerfile` (multi-stage: Debian-slim builder downloads + sha256-verifies the agentis binary, runtime stage with `bash` + `python3` + `jq` + `gawk` + `curl` + `git` runs as non-root `agentis` user). New `.github/workflows/release-docker.yml` fires on every `dev-apprenticeship-v*` tag push, builds + pushes `linux/amd64` + `linux/arm64` via Buildx, tags `:dev-apprenticeship-<X.Y.Z>` + `:dev-apprenticeship-latest`. Image bundles the dev-apprenticeship federation tree at `/opt/agentis-colonies/dev-apprenticeship/` and the shared platform tooling at `/opt/agentis-colonies/tools/`; first-run bootstrap by `examples/docker/entrypoint.sh` mirrors `install.sh` §4 (writes the federation-wide config keys, materialises each colony's `colony.toml` from `colony.example.toml`, sets `[forge].type` from `$FORGE_TYPE`). New `dev-apprenticeship/.agentis-version` pin file (mirrors `.dashboard-version` precedent) is read by both the Dockerfile builder and `install.sh` so the runtime floor lives in one place. Sample operator manifests under `examples/k8s/` (Deployment + PVC + Secret/ConfigMap templates) and `examples/docker/` (compose + env). Build-only smoke test in `tools/test-docker-build.sh` (skips cleanly when docker is unavailable).

## [1.2.0] — 2026-04-26

Hard LLM cost cap (`tools/cost-cap.sh` sidecar with metered + flat-tariff modes,
on_breach = `downgrade` / `stop`), `secret://` URI resolver for forge tokens
across four host vaults, and a knob that lets `code_writer` fire on label alone.
Plus a wave of correctness/observability fixes that had accumulated in
`[Unreleased]` since 1.1.0 — auto-promote unblocked twice (tier-range matcher in
`#331` and parent-fallback experience resolver in `#333`), `colony-lint.sh` no
longer kills the live federation, `start-federation.sh` actually wipes the right
heartbeat dir, `install.sh` heartbeat / env-passthrough / GITHUB_ME defaults all
fixed, and `colony-lint.sh` parses on stock macOS bash 3.2.

**Requires:** agentis >= 1.4.7 (cost-cap consumes the per-agent JSONL spend log shipped by [agentis-core 1.4.7+](https://github.com/Replikanti/agentis/releases/tag/v1.4.7); pre-1.4.7 agents emit no `cost_usd` rows and the sidecar will sum to zero in `metered` mode)
**Recommends:** federation-dashboard >= 0.4.0 (pinned via `dev-apprenticeship/.dashboard-version`; LLM Cost tile + Cost Cap tile both read the same on-disk JSONL the sidecar protects)

### Added

- Hard daily/monthly LLM cost cap. New `tools/cost-cap.sh` sidecar (mirrors the auto-promote sidecar shape) reads the per-agent JSONL spend log shipped by agentis-core's #311 foundation and evaluates usage against caps in `<fed>/.cost-cap.toml`. Two modes: `metered` (sum `cost_usd` against daily/monthly $ caps for per-token billing — Anthropic / OpenAI API) and `flat` (count requests against rate caps + slope detection vs trailing 24h baseline for subscription / Ollama plans where `cost_usd` is meaningless). State machine: `active` → `warning` (≥ `warn_at_pct`%, default 80%) → `breach` (≥ 100% of any cap, OR slope ≥ `slope_breach_multiplier` in flat mode). On breach, `on_breach = "downgrade"` writes `<fed>/.agentis/llm-backend-override` and restarts every running daemon via `<colony>/scripts/start-colony.sh --restart-agent <name>` so newly-spawned agents pick `--config-override llm.backend=mock`; `on_breach = "stop"` calls `agentis daemon stop --all`. Period rollover (UTC midnight / month boundary) clears flag/override and restarts agents back to the real backend. Manual reset via `tools/cost-cap.sh <fed> --override <reason>` (also exposed as `POST /cost-cap/override` on the dashboard; `--override` under sidecar lock contention exits 75 and the dashboard returns HTTP 409 so operators see retry hints instead of a misleading success). Default `enabled = false` — operator opts in during `install.sh` step 7.5. Federation-level only in v1; per-agent / per-colony caps deferred ([#318](https://github.com/Replikanti/agentis-colonies/issues/318)).
- `tools/parse-toml.sh` now resolves `secret://` URI values via OS keychains so forge tokens can live outside the repo. Four backends supported: `secret://libsecret/<service>/<key>` (Linux GNOME-Keyring via `secret-tool`), `secret://keychain/<service>/<account>` (macOS Keychain via `security`), `secret://pass/<path>` (passwordstore.org), `secret://env/<VAR>` (env-var normalisation). Plaintext stays valid (back-compat). Companion helper `tools/secret-set.sh` writes a token into the host vault interactively and prints the URI to paste into `colony.toml`. `dev-apprenticeship/install.sh` offers the vault path during forge-token prompts. `tools/colony-lint.sh` warns on plaintext `*token*`/`*api_key*` values (default warn-only, opt-in fail via `COLONY_LINT_STRICT_SECRETS=1`). Test coverage in `tools/test-secret-resolver.sh` (16 cases × 4 backends) and a `parse-toml.sh` regression for plaintext passthrough ([#321](https://github.com/Replikanti/agentis-colonies/issues/321)).
- New `[implementation].require_assignee` config knob (default `false`) gates whether `code_writer`'s action path also fires on labeled-but-unassigned issues or stays restricted to labeled+assigned. The `implementation/scripts/{gitlab,github}-api.sh` wrappers gain a matching `--include-unassigned` flag on `assigned-issues` and `assigned-issues-by-label-events`; `start-colony.sh` seeds `code_writer:require_assignee` from the TOML, and `code_writer.ag` appends the flag when the memo reads `"false"`. Unblocks the 13 downstream agents that listen for `implementation:code_draft` / `implementation:mr_ready` on repos where labeled issues are typically unassigned ([#291](https://github.com/Replikanti/agentis-colonies/issues/291)).

### Changed

- `code_writer`'s assigned-issues poll now defaults to firing on label alone (the pre-#291 behaviour gated on both label AND assignee). Operators who want to keep the old contributor-hand-off behaviour set `[implementation].require_assignee = true` ([#291](https://github.com/Replikanti/agentis-colonies/issues/291)).

### Fixed

- `tools/auto-promote-decisions.py` step matcher now uses tier-range membership (`step_from <= confidence < step_to`) aligned with ADR-0001, instead of strict equality with `step_from` (within 0.001). Pre-fix every agent whose confidence was not exactly seeded on a tier boundary (0.4 / 0.6 / 0.8) logged `no applicable promote step for confidence=0.6X` and could never auto-promote — even one successful `learn()` nudge moving the value by +0.005 broke promotion permanently. The live federation was fully blocked because the operator typed 0.61 during install. Range membership is also robust to the post-`learn()` drift that pushes confidences off the canonical anchors. New regression tests in `tools/test-auto-promote.sh` cover seven edge cases (0.61, 0.4, 0.6, 0.8 lower-bound inclusive; 0.39 below ladder, 0.95 above ladder, 0.799 just under upper bound) ([#331](https://github.com/Replikanti/agentis-colonies/issues/331)).
- `tools/auto-promote-decisions.py` now mirrors the dashboard wrapper's parent-fallback resolver (`<fed>/../.agentis/experience/<id>.jsonl`) when the fed-local path is missing, so the symlinked layout produced by `dev-apprenticeship/install.sh` (every colony's `.agentis` is a symlink to `<repo-root>/.agentis`) sees the same experience entries the dashboard already reads. Pre-fix every agent reported `entries_total=0` against the live federation and the `min_entries` prereq could never clear despite ~130 entries on disk; the disagreement between dashboard's `Experience Growth` (real count) and Promote Candidates' prereq checklist (zero) was the reproducible smoking gun. Fed-local stays the first hit so sibling-federation isolation (#238 invariant) is preserved. Two regression tests added: a symlinked-layout positive case, and a fed-local-priority guard with different row counts in fed-local vs parent dirs ([#333](https://github.com/Replikanti/agentis-colonies/issues/333)).
- `tools/colony-lint.sh` no longer transitively runs `tools/test-kill-endpoint.sh` and `tools/test-kill-federation.sh` (which kill the live federation despite the #296 cwd-filter). The auto-discovered test loop now `[SKIP]`s both by default; opt in via `AGENTIS_RUN_KILL_TESTS=1` for CI in isolated environments ([#329](https://github.com/Replikanti/agentis-colonies/issues/329)).
- `start-federation.sh` heartbeat-wipe path now matches the actual agentis registry. The old wipe targeted `<fed-dir>/.agentis/daemon` (empty placeholder) but the real registry lives at `<fed-dir>/../.agentis/daemon` via the per-colony symlink layout — stale heartbeat files survived restarts and the watchdog killed every fresh child on its first poll iteration with `heartbeat stale (N ms > timeout)`. Both paths are now swept ([#302](https://github.com/Replikanti/agentis-colonies/issues/302)).
- `start-federation.sh` auto-promote sidecar now ticks before sleeping (was: sleep `interval_s` first, then tick) and stamps `.agentis/logs/auto-promote.sidecar_started_at` on spawn. The first regression — the sidecar produced zero log activity for the first 30 min after restart even when healthy — is fixed by inverting the loop. The second — `auto-promote.log` inherits a stale mtime from the previous run so the dashboard reads "silent NNNNm DEGRADED" — is fixed by the start-timestamp file, which the dashboard collector reads to suppress DEGRADED while `now - started_at < interval_s + 120s` ([#274](https://github.com/Replikanti/agentis-colonies/issues/274)).
- GitHub wrapper no longer fails on repos with >20 closed PRs — normalizers now read HTTP body via stdin instead of env var, bypassing `MAX_ARG_STRLEN` ([#279](https://github.com/Replikanti/agentis-colonies/issues/279)).
- `install.sh` now routes `FORGE_TYPE` and `GITHUB_*` through `exec.env_passthrough`; existing installs with the pre-fix literal are auto-upgraded in place. Unblocks GitHub-backend federations ([#277](https://github.com/Replikanti/agentis-colonies/issues/277)).
- `install.sh` now sets `daemon.heartbeat_interval_ms = 900000` (3× the longest tick interval, 300 000 ms, per #146) so reactive code-review/release agents are no longer killed by the watchdog after their first tick; existing installs with the pre-fix `180000` literal are auto-upgraded in place ([#280](https://github.com/Replikanti/agentis-colonies/issues/280)).
- `install.sh` now seeds the `gitlab:me` memo from `$GITHUB_ME` on github-backed federations (previously only `$GITLAB_ME` was honored, leaving the three `recall_latest("gitlab:me")` consumers — labeler, prioritizer, style_reviewer — falling back to `team` tagging). Re-runs preserve operator-customized memos ([#278](https://github.com/Replikanti/agentis-colonies/issues/278)).
- `start-colony.sh --restart-agent <name>` now kills the pre-existing daemon (SIGTERM → 5s wait → SIGKILL) before spawning the new one; previous behaviour silently accumulated duplicate `agentis daemon-inner` processes across dashboard `/restart` and `/confidence`-triggered respawns ([#285](https://github.com/Replikanti/agentis-colonies/issues/285)).
- `tools/colony-lint.sh` no longer fails to parse on stock macOS bash 3.2 (`/bin/bash`). The inline `awk '...'` literal that extracted daemon flags from `start-colony.sh` is now sourced from `tools/colony-lint-flag-allowlist.awk` via `awk -f`, removing the multi-line single-quoted block that the bash 3.2 parser miscompiled near the case-statement at line 202. Same workaround pattern already applied to the `auto-promote.sh` family (#245) and the `federation-dashboard-*.py` family (#172). New smoke harness `tools/test-colony-lint-bash32.sh` enforces ([#271](https://github.com/Replikanti/agentis-colonies/issues/271)).

## [1.1.0] — 2026-04-24

Adds a federation-wide `--rate-limit-status` mode to every colony's
`start-colony.sh`, the colony-side half of the `federation-dashboard`
0.3.0 Forge Rate Limits tile. Additive-only — no behaviour changes for
existing callers.

**Requires:** agentis >= 1.4.1
**Recommends:** federation-dashboard >= 0.3.0 (pinned via `dev-apprenticeship/.dashboard-version`)

### Added

- Every colony's `scripts/start-colony.sh` supports a new
  `--rate-limit-status` mode that reuses the env-load path and execs
  `forge-api.sh rate-limit-status`, printing the JSON contract
  `{remaining, limit, reset_at}` from PR 7 of [#256](https://github.com/Replikanti/agentis-colonies/issues/256).
  Used by `federation-dashboard` 0.3.0's Forge Rate Limits tile so the
  dashboard can surface remaining API budget per colony without parsing
  `colony.toml` itself (the [#257](https://github.com/Replikanti/agentis-colonies/issues/257)
  decoupling principle). Memo seeding and log truncation are gated on
  the new flag too — both are full-colony bootstrap concerns.

## [1.0.0] — 2026-04-24

First major release. Forge abstraction ([#256](https://github.com/Replikanti/agentis-colonies/issues/256)) lets each colony run against GitHub or GitLab via a new `[forge]` section; the legacy top-level `[gitlab]` block is retired (that is the MAJOR). Every forge wrapper also exposes a uniform `rate-limit-status` subcommand. Also bundles the #257 dashboard-restart decoupling that landed on `main` during the #256 phase work.

**Requires:** agentis >= 1.4.1
**Recommends:** federation-dashboard >= 0.2.0 (pinned via `dev-apprenticeship/.dashboard-version`)

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
- **Planning colony GitHub backend (PR 3 of 7 for #256).**
  `dev-apprenticeship/planning/scripts/github-api.sh` implements the
  planning contract against the GitHub REST API v3 (5 subcommands:
  `issues`, `issues-by-label-events`, `issue-label-events`, `add-note`,
  `merge-requests`). Two GitHub-specific endpoint collapses that are not
  a concern for triage: `/issues/{n}/timeline` replaces GitLab's
  `/resource_label_events` (filtered to `event in ("labeled",
  "unlabeled")`, mapped `labeled` → "add" / `unlabeled` → "remove");
  `/pulls` replaces `/merge_requests` and has no distinct "merged"
  state, so `--state merged` collapses to `state=closed` plus a
  client-side `merged_at != null` filter. GitHub's `/pulls` also omits
  `changed_files` on the list endpoint — the normalizer forwards `null`,
  and `scope_estimator` already tolerates missing complexity scores.
  All 16 `exec sh` call sites across `scope_estimator`, `risk_assessor`,
  `task_decomposer`, and `plan_reviewer` were rewritten from
  `scripts/gitlab-api.sh` to `scripts/forge-api.sh` (required so
  `check-forge-dispatch.sh` stays green once the concrete
  `github-api.sh` lands). `planning/scripts/start-colony.sh` now
  branches on `FORGE_TYPE` identically to triage: exports
  `GITHUB_URL` / `GITHUB_OWNER` / `GITHUB_REPO` / `GITHUB_TOKEN` /
  `GITHUB_ME` from `[forge.github]` when `type = "github"`, reads
  `[forge.gitlab]` with `[gitlab]` legacy fallback otherwise; the
  `PLANNING_TRIGGER_LABEL` export is backend-agnostic and unchanged.
  Two new tests: `tools/test-github-planning-normalize.sh` (32
  assertions covering `normalize_issues` PR-filter + field mapping,
  `normalize_pulls` state collapse + target_branch/source_branch/
  changes_count handling, `normalize_timeline` label/since filters + add/
  remove mapping, end-to-end pipes through `planning` and `planning-mr`
  views); and a planning-colony extension to `tools/test-gitlab-views.sh`
  asserting byte-identical `project_json` output between
  `github-api.sh` and `gitlab-api.sh` for the `planning` and
  `planning-mr` views.
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)
- **Implementation colony GitHub backend (PR 4 of 7 for #256).**
  `dev-apprenticeship/implementation/scripts/github-api.sh` implements
  the implementation contract against the GitHub REST API v3 (11
  subcommands: `merge-requests`, `mr-changes`, `mr-commits`, `issue`,
  `assigned-issues`, `issue-label-events`,
  `assigned-issues-by-label-events`, `create-branch`, `commit-files`,
  `create-mr`, `add-note`). The write-path subcommands — `create-branch`,
  `commit-files`, `create-mr` — carry the main GitHub-vs-GitLab
  asymmetry: GitHub has no single-call multi-file commit endpoint, so
  `commit-files` implements the 5-step Git Database API dance (resolve
  HEAD ref → fetch base tree → `POST /git/trees` with per-file action
  list → `POST /git/commits` → `PATCH /git/refs/heads/{branch}`).
  Supported actions are `create`/`update`/`delete`; `move`/`chmod` are
  rejected up-front with exit 1 (GitLab-only semantics). `mr-changes`
  maps `/pulls/{n}/files` into the GitLab
  `{"changes": [{old_path, new_path, diff, new_file, deleted_file,
  renamed_file}]}` shape; `mr-commits` flattens
  `commit.author.{name,date}` into the GitLab-flat
  `{author_name, created_at}` shape. All 25 `exec sh` call sites across
  `code_writer`, `test_writer`, `refactorer`, and `commit_composer`
  were rewritten from `scripts/gitlab-api.sh` to `scripts/forge-api.sh`.
  `implementation/scripts/start-colony.sh` now branches on `FORGE_TYPE`
  identically to triage and planning; the `IMPLEMENTATION_TRIGGER_LABEL`
  and `GITLAB_DEFAULT_BRANCH` exports are backend-agnostic and
  unchanged. Back-port fix: `implementation/scripts/gitlab-api.sh`
  gains an `add-note` subcommand targeting `/issues/{iid}/notes`; all
  four implementation agents call `add-note` on their review-gated
  branches but it never existed on the GitLab side (the existing
  `post-note` arm targets MRs). Calls were silently failing through
  `.ag` try/catch — same pattern that PR 2 fixed for triage. Two new
  tests: `tools/test-github-implementation-normalize.sh` (50 assertions
  covering `normalize_issues` PR-filter, `normalize_pulls` state
  collapse, new `normalize_mr_changes` wrap-and-flag mapping, new
  `normalize_mr_commits` author flattening, `normalize_timeline`
  label/since filters, end-to-end pipes through `impl` and `assigned`
  views); and an implementation-colony extension to
  `tools/test-gitlab-views.sh` asserting byte-identical `project_json`
  output between `github-api.sh` and `gitlab-api.sh` for the `impl`
  and `assigned` views.
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)
- **Code-review colony GitHub backend (PR 5 of 7 for #256).**
  `dev-apprenticeship/code-review/scripts/github-api.sh` implements the
  code-review contract against the GitHub REST API v3 (5 subcommands:
  `merge-requests`, `mr-changes`, `mr-notes`, `post-note`, `approve`).
  Two endpoint collapses unique to the review surface: GitHub unifies
  issue and PR conversations under `/issues/{n}/comments`, so both
  `mr-notes` and `post-note` target that endpoint (same one the
  triage/planning/implementation `add-note` subcommands already hit);
  `approve` maps GitLab's idempotent
  `POST /merge_requests/{iid}/approve` to GitHub's non-idempotent
  `POST /pulls/{n}/reviews` with `{"event": "APPROVE"}` (extra calls
  from the same reviewer stack as additional APPROVED review events
  but don't break the approvals collapse, since the approved-count
  logic counts latest-per-reviewer). `normalize_pulls` adds a native
  `draft` boolean from GitHub's `draft` field (consumed by the
  `reviewer` view to skip draft PRs); GitHub has no `system` flag on
  comments, so `normalize_notes` stamps `system: false` on every row
  (correct because `/issues/{n}/comments` only surfaces human comments,
  unlike GitLab's `/notes` which mixes in timeline events). As in
  PRs 3-4, `--state merged` collapses to
  `state=closed + merged_at != null` client-side and `--since` filters
  client-side on `updated_at` (GitHub's `/pulls` has no `since` param).
  All 28 `exec sh` call sites across `approval_decider`, `logic_reviewer`,
  `security_reviewer`, `style_reviewer`, and `test_reviewer` were
  rewritten from `scripts/gitlab-api.sh` to `scripts/forge-api.sh`.
  `code-review/scripts/start-colony.sh` now branches on `FORGE_TYPE`
  identically to triage/planning/implementation; no colony-specific
  env additions (code-review agents don't create branches or issues).
  Two new tests: `tools/test-github-code-review-normalize.sh` (32
  assertions covering `normalize_pulls` state collapse + `draft` field
  passthrough, `normalize_mr_changes` status → new_file/deleted_file/
  renamed_file mapping, `normalize_notes` `system: false` invariant,
  end-to-end pipe through the `reviewer` view); and a code-review-colony
  extension to `tools/test-gitlab-views.sh` asserting byte-identical
  `project_json` output between `github-api.sh` and `gitlab-api.sh`
  for the `reviewer` view.
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)
- **Release colony GitHub backend (PR 6 of 7 for #256).**
  `dev-apprenticeship/release/scripts/github-api.sh` implements the
  release contract against the GitHub REST API v3 (7 subcommands:
  `releases`, `tags`, `pipelines`, `merge-requests`, `create-tag`,
  `create-release`, `post-note`). Three release-specific endpoint
  collapses: `normalize_tags` forwards `message` and
  `commit.created_at` as `null` rather than doing the per-tag
  `/git/refs/tags` + `/git/tags` + `/git/commits` round-trip (~20
  extra API calls per `tags` list read — the one consumer,
  release_checker's `tag-summary` view, only needs `name` +
  `commit.short_id` for prompt context, and `short_id` is derived as
  `sha[:8]` locally). `normalize_pipelines` unwraps GitHub's
  `{total_count, workflow_runs: [...]}` envelope and collapses the
  2-axis `(status, conclusion)` matrix to GitLab's single-field
  `status`: `completed + success|skipped|neutral` → `success`,
  `completed + failure|cancelled|timed_out|action_required|stale` →
  `failed`, `in_progress` → `running`, `queued|requested|waiting|
  pending` → `pending`. `normalize_releases` maps `body` →
  `description`, `published_at` → `released_at`, `author.login` →
  `author.username`; the `commit` object is forwarded as `null` (not
  carried inline by GitHub's `/releases` — changelog_writer reads it
  from `tags` instead). `create-tag` implements the 3-step annotated-
  tag dance (`GET /git/refs` to resolve the ref → `POST /git/tags` →
  `POST /git/refs` to advance `refs/tags/{name}`); without a
  `--message` it short-circuits to a single `POST /git/refs` for a
  lightweight tag. `create-release` posts to `/releases` with
  `{tag_name, name, body}` and normalizes the response.
  `post-note <num>` on the release colony (used by ship_decider and
  changelog_writer for MR comments) goes through
  `/issues/{n}/comments`, same endpoint as code-review's. All 29
  `exec sh` call sites across `version_bumper`, `ship_decider`,
  `release_checker`, and `changelog_writer` were rewritten from
  `scripts/gitlab-api.sh` to `scripts/forge-api.sh`.
  `release/scripts/start-colony.sh` now branches on `FORGE_TYPE`
  identically to triage/planning/implementation/code-review, and —
  as a bonus fix deferred from PR 4 QA finding F1 — now honors
  `[forge.gitlab].default_branch` and `[forge.github].default_branch`
  (pre-PR 6 release silently ignored both, falling back only to
  legacy `[gitlab].default_branch`). Two new tests:
  `tools/test-github-release-normalize.sh` (47 assertions covering
  all four normalizers with the full status/conclusion matrix,
  annotated-vs-lightweight tag fixtures, the envelope-unwrap
  fallback, and end-to-end pipes through all four release views);
  and a release-colony extension to `tools/test-gitlab-views.sh`
  asserting byte-identical `project_json` output between
  `github-api.sh` and `gitlab-api.sh` for the `release-summary`,
  `tag-summary`, `pipeline-summary`, and `release-mr` views.
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)
- **Forge rate-limit primitive (PR 7 of 7 for #256).** Every per-colony
  forge wrapper now supports a `rate-limit-status` subcommand that
  emits a uniform `{"remaining": <int|null>, "limit": <int|null>,
  "reset_at": <ISO-8601 UTC|null>}` JSON object. Both backends share
  the same output contract; the source differs. GitHub reads
  `/rate_limit` (an uncounted endpoint so operators can poll without
  burning budget). GitLab reads `RateLimit-*` response headers off a
  cheap `GET /api/v4/version` call — self-hosted GitLab instances
  without rate-limiting configured (the common case) return no
  headers; the arm forwards `null`s and exits 0 rather than
  hard-failing, so operator dashboards can distinguish
  "not-configured" from "over-budget" without a wrapper error.
  Transport failure on GitHub propagates the non-zero `gh_call` exit;
  transport failure on GitLab still yields exit 0 with nulls (the
  absence of a `RateLimit-Remaining` header is identical to a DNS-less
  self-hosted instance, by design). Dashboard consumption is
  deliberately deferred to a separate `federation-dashboard` release so
  a UI churn does not gate the federation's v1.0.0. New test:
  `tools/test-rate-limit-status.sh` (25 assertions: 5 colonies × 3
  GitLab modes + 5 colonies × 2 GitHub modes).
  [#256](https://github.com/Replikanti/agentis-colonies/issues/256)

### Changed

- **BREAKING (MAJOR, v1.0.0) — legacy top-level `[gitlab]` config
  section retired federation-wide (#256 PR 7).** The transitional
  dual-read behavior introduced in PR 1 has ended. All 5
  `colony.example.toml` templates now ship `[forge.gitlab]` only (no
  top-level `[gitlab]`). All 5 `scripts/start-colony.sh` scripts read
  from `[forge.gitlab]` / `[forge.github]` and emit an explicit
  "Required: url, token, project under [forge.gitlab]" error when the
  section is missing — the pre-PR-7 fallback to a bare `[gitlab]`
  section has been removed. `install.sh` no longer writes into the
  legacy section. `tools/colony-lint.sh` gains a guard that flags a
  top-level `[gitlab]` in any `colony.example.toml` as a retirement
  regression. **Operator migration:** edit each `colony.toml`, rename
  `[gitlab]` → `[forge.gitlab]`, and add a top-level `[forge]` block
  with `type = "gitlab"` (see `colony.example.toml` for the exact
  shape). The `me` / `default_branch` keys move with the section.
  Pre-#256 installs that cannot migrate should stay on
  `dev-apprenticeship v0.3.3` (the last release carrying the
  dual-read fallback).
- **BREAKING (MAJOR, v1.0.0) — install.sh GitHub credential prompting
  (#256 PR 7).** The "GitHub scaffolding is partial, continue anyway?"
  abort gate that guarded pre-PR-6 installs has been removed — both
  backends are first-class after PR 6. Credential prompting now branches
  on `FORGE_TYPE`: `gitlab` prompts for url/project/PAT/me and writes
  `[forge.gitlab]` (identical semantics to v0.3.x); `github` prompts for
  owner/repo/PAT plus optional Enterprise URL and optional `me`,
  uncomments the `[forge.github]` template block in `colony.toml`, and
  writes the credentials into it. `FEDERATION_FORGE_TYPE=github
  ./install.sh` is now a supported unattended flow.
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

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v2.0.0...HEAD
[2.0.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v1.3.0...dev-apprenticeship-v2.0.0
[1.3.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v1.2.0...dev-apprenticeship-v1.3.0
[1.2.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v1.1.0...dev-apprenticeship-v1.2.0
[1.1.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v1.0.0...dev-apprenticeship-v1.1.0
[1.0.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.3...dev-apprenticeship-v1.0.0
[0.3.3]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.2...dev-apprenticeship-v0.3.3
[0.3.2]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.1...dev-apprenticeship-v0.3.2
[0.3.1]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.3.0...dev-apprenticeship-v0.3.1
[0.3.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.2.0...dev-apprenticeship-v0.3.0
[0.2.0]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.1...dev-apprenticeship-v0.2.0
[0.1.1]: https://github.com/Replikanti/agentis-colonies/compare/dev-apprenticeship-v0.1.0...dev-apprenticeship-v0.1.1
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dev-apprenticeship-v0.1.0
