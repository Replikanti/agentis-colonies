# CLAUDE.md

## Project overview

A home for [Agentis](https://github.com/Replikanti/agentis) agent **federations** plus federation-agnostic **platform components**. The platform contract every federation must satisfy is normative in [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md). Two federations ship today: `dev-apprenticeship/` — 5 colonies, 21 agents that learn a developer's workflow by observing how they work on GitLab/GitHub (Beta), and `tribes-bench/` — 5 tribes hunting CVE-grade memory safety bugs in vendored Rust crates via a deterministic verifier (Experimental, research scaffold). All `dev-apprenticeship/` agents implement the full confidence gradient (observe / suggest / act). Federation patterns beyond the coder workflow live in [`doc/federation-patterns.md`](./doc/federation-patterns.md).

This file is split into two parts:
- **Platform invariants** — federation-agnostic. Tier contract, release process, ADRs, scaffolding, agent and script conventions. Applies to any federation in this repo.
- **dev-apprenticeship specifics** — only true for the dev-apprenticeship federation: bus-event wiring, confidence keys, trigger labels, the 21-agent inventory.

# Platform invariants

## Git workflow

- **Never push directly to main.** Always create a feature branch and open a PR.
- Branch protection is enforced via GitHub rulesets (require PR, no deletion, no force-push).
- Branches are auto-deleted after merge.

## Release process

Each federation is versioned independently at the federation level. `dev-apprenticeship/` follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html); history is in [`dev-apprenticeship/CHANGELOG.md`](./dev-apprenticeship/CHANGELOG.md) (Keep a Changelog format).

Cutting a release ([#218](https://github.com/Replikanti/agentis-colonies/issues/218), [#220](https://github.com/Replikanti/agentis-colonies/issues/220)):

1. **Open a release PR** titled `release: dev-apprenticeship v<X.Y.Z>` that changes only:
   - `dev-apprenticeship/VERSION` (single-line bump).
   - `dev-apprenticeship/CHANGELOG.md` — rename `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD`, add a fresh empty `## [Unreleased]` on top, update the trailing comparison link. If the runtime floor changed, update the `**Requires:** agentis >= ...` line.
   - Optionally the version badges in `dev-apprenticeship/README.md` and the top-level `README.md`.
2. **After merge:** tag and push:
   ```bash
   git tag dev-apprenticeship-v<X.Y.Z> <merge-sha> -m "dev-apprenticeship v<X.Y.Z>"
   git push origin dev-apprenticeship-v<X.Y.Z>
   ```
   That is the entire post-merge step. `.github/workflows/release.yml` ([#220](https://github.com/Replikanti/agentis-colonies/issues/220)) fires on the tag, runs `tools/make-federation-bundle.sh dev-apprenticeship <X.Y.Z>`, and creates-or-updates the GitHub release with the curated bundle (`dev-apprenticeship-v<X.Y.Z>.tar.gz` + `.sha256`) and CHANGELOG-extracted notes attached. No manual `gh release create` / `gh release upload` required.
3. **Semver decisions** — bus-event rename/removal, agent removal, config-schema break, or a tier-semantics change in ADR-0001 is **MAJOR**. A new agent, new bus event (without removing one), a new optional config key, or a new install prompt defaulting to off is **MINOR**. Bug fixes, `.ag` tuning, docs, and new colony-lint rules that don't flag anything already-merged are **PATCH**.

If a new runtime dependency under `tools/` is added that `dev-apprenticeship/` sources or invokes, append its path to `dev-apprenticeship/BUNDLE.manifest` in the same PR so the release bundle stays install-ready. `tools/test-make-federation-bundle.sh` enforces that every manifest entry exists and that contributor-only tooling (this file, `.github/`, `tools/colony-lint.sh`, `tools/check-*.sh`, `tools/test-*.sh`, `tools/new-colony.sh`) never leaks into a bundle.

`colony-lint` (via `tools/check-changelog.sh`) loops over every versioned component (`dev-apprenticeship/`, `federation-dashboard/`): warns whenever a PR touches a component without updating its `CHANGELOG.md`, and fails whenever its `VERSION` bumps without a matching CHANGELOG entry. Adding a new versioned component is one line in the `COMPONENTS` array in that script.

The `federation-dashboard/` component follows the same release-PR + tag-after-merge dance as `dev-apprenticeship/`, but with its own tag scheme (`federation-dashboard-v<X.Y.Z>`) and its own workflow (`.github/workflows/release-dashboard.yml`) that runs `tools/make-dashboard-bundle.sh`. See the **federation-dashboard component** section below for file-level details.

## Validation

```bash
./tools/colony-lint.sh          # Full lint (structure, config, syntax, exec-sh safety, daemon flags)
bash -n scripts/gitlab-api.sh   # Bash syntax check on any script
```

Colony lint must pass with 0 failures before merge. Current CI baseline: 42 passed, 0 failed, 1 skipped (agentis binary not installed on runners). Local runs add ~42 per-agent `.ag` syntax + tier-branch passes when `agentis` is installed, and 5 skips when `shellcheck` is not.

## Colony structure

Every colony follows this layout:

```
colony-name/
  agents/          # .ag agent files (one per agent)
  config/          # colony.example.toml (copy to colony.toml for local use)
  scripts/         # start-colony.sh, gitlab-api.sh
  README.md        # Agent table, mermaid diagram, setup instructions
```

## Agent conventions (.ag files)

- `cb <N>;` at the top must match the `cb_budget` in colony.example.toml.
- **Gate behaviour on tiers, not raw thresholds.** Call `tier("<agent_name>")` (agentis-core builtin) and compare against one of the five name strings; never inline `confidence >= 0.X` literals. `colony-lint` enforces this.
- The four-tier confidence contract defined in [`doc/adr/ADR-0001-confidence-tiers.md`](./doc/adr/ADR-0001-confidence-tiers.md) is **normative** for every `.ag` scenario in this repo.

  | Tier           | Range         | Behaviour |
  |----------------|---------------|-----------|
  | `shadow`       | `[0.4, 0.6)`  | LLM + memo, no emit, no external write |
  | `propose`      | `[0.6, 0.8)`  | + emit on bus + draft external writes |
  | `review-gated` | `[0.8, 0.95)` | + direct external writes (non-terminal) |
  | `autonomous`   | `[0.95, 1.0]` | + terminal writes (merge, tag, publish) |

  Below `0.4` = `dormant`. The runtime also returns `"dormant"` when the memo is missing, so authors must handle it (typically collapsed into the `shadow` branch).

  Canonical pattern (one `tier()` call per tick, branch once, fall through to `shadow`/`dormant`):

  ```
  fn tick(rec: string) -> void {
      let my_tier = tier("style_reviewer");
      if my_tier == "autonomous" {
          // direct external write + learn(..., tags=[..., "acted"])
      } else if my_tier == "review-gated" {
          // draft external write pending approval + learn(..., tags=[..., "review-gated"])
      } else if my_tier == "propose" {
          // emit on bus + learn(..., tags=[..., "emitted"])
      } else {
          // shadow / dormant: observe only + learn(..., tags=[..., "observed"])
      }
  }
  ```

- `get_confidence()` reads from `recall_latest("<agent_name>:confidence")`. Use it for diagnostics or logging — not for branching.
- `learn()` topic must match the topic in `recommend()` within the same agent.
- `memo_write("<agent_name>:last_check", now)` at the end of every tick.
- All dynamic values in `exec sh` calls must be wrapped in `shell_escape()`.
- If the grep-based linter cannot see through nested `shell_escape()`, add `// colony-lint: safe-exec-concat` on the line above.
- Emit events use `"<colony_name>:<event_name>"` format.
- For mechanical JSON field extraction from `exec sh` output, prefer `parse_int(to_string(json_get(raw, "[0].iid")))` over `prompt(...) -> list<T>` / `-> map<K,V>`. The idiom is total on every failure mode (`Void → "void" → 0`) and saves one LLM round-trip per tick. Precedent: the `post-note` branches in `release/agents/ship_decider.ag` and `release/agents/changelog_writer.ag`, every `implementation/agents/*.ag`, `code-review/agents/{logic,test,security,style}_reviewer.ag` after #138, and `planning/agents/plan_reviewer.ag` after #147.

## Script conventions

- `start-colony.sh`: symlink-safe `$0` resolution via python3, sources `tools/parse-toml.sh`, exports the GitLab-connection env vars consumed by each colony's `.ag` agents via `exec sh`. Base exports in every colony: `GITLAB_URL`, `GITLAB_TOKEN`, `GITLAB_PROJECT`, `GITLAB_ME` ([#104](https://github.com/Replikanti/agentis-colonies/issues/104)), `COLONY_DIR`. Per-colony additions: `planning` exports `PLANNING_TRIGGER_LABEL` ([#223](https://github.com/Replikanti/agentis-colonies/issues/223)); `implementation` exports `IMPLEMENTATION_TRIGGER_LABEL` ([#225](https://github.com/Replikanti/agentis-colonies/issues/225)) and `GITLAB_DEFAULT_BRANCH` ([#224](https://github.com/Replikanti/agentis-colonies/issues/224)); `release` exports `GITLAB_DEFAULT_BRANCH` ([#224](https://github.com/Replikanti/agentis-colonies/issues/224)). For prompt-vocabulary knobs that must be readable from inside `.ag` scenarios, `planning/scripts/start-colony.sh` and `triage/scripts/start-colony.sh` additionally seed the memo store on startup: `planning:labels:incident`, `planning:labels:epic`, and `triage:labels:priority` are `agentis memo set` from `[planning.labels]` / `[triage.labels]` when non-empty ([#226](https://github.com/Replikanti/agentis-colonies/issues/226)). Launches daemons with `--colony <name> --tick-interval "$interval"` where `interval` is looked up per-agent via a local `tick_interval_for()` case function (fallback 60000ms). Reactive colonies (release, code-review) run at 300000ms, triage's router/prioritizer at 180000ms, everything else at 60000ms. See #146 for rationale. Also supports `--restart-agent <name>` mode ([#257](https://github.com/Replikanti/agentis-colonies/issues/257)) that respawns exactly one agent with the full colony env and skips memo seeding + log truncation (those are full-colony bootstrap concerns). Exit codes: 0 ok, 2 unknown flag / missing arg, 3 unknown agent name for this colony, 4 daemon launch failure. On success, prints exactly one line `started <agent> pid=<n> tick=<ms>` on stdout for the dashboard's `/restart` endpoint to parse. Positional config-path arg still works for pre-#257 callers.
- `gitlab-api.sh`: `emit_error()` for all error messages, `exit 2` for unknown flags, `python3 json.dumps` for all POST/PUT body construction. Read endpoints use `gl_get`/`gl_get_q`, write endpoints use `gl_post`/`gl_put`.

## Tools

| Tool | Purpose |
|------|---------|
| `colony-lint.sh` | Full federation lint (structure, config, .ag syntax, exec-sh safety, daemon flag allowlist, markdown links) |
| `new-federation.sh` | Scaffold a new federation conforming to [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md) ([#258](https://github.com/Replikanti/agentis-colonies/issues/258)). Creates `<fed>/VERSION`, `CHANGELOG.md`, `BUNDLE.manifest`, `README.md`, `install.sh`, plus one starter colony with an ADR-0003-conformant `start-colony.sh`. Output passes `colony-lint.sh` clean. |
| `new-colony.sh` | Scaffold a new colony within an existing federation (creates dirs, example config with `[forge]` block, starter scripts). |
| `check-exec-sh.sh` | Grep-based check for unsafe string concat into `exec sh`. See `check-exec-sh.md` for known limitations. |
| `check-prompt-gate.sh` | Grep/awk lint that ensures every `prompt()` in `implementation/`, `planning/`, `code-review/`, and `triage/` agents is preceded (same function) by a memo-based staleness gate (`recall_latest()` or gate fn) ([#200](https://github.com/Replikanti/agentis-colonies/issues/200), [#201](https://github.com/Replikanti/agentis-colonies/issues/201), [#205](https://github.com/Replikanti/agentis-colonies/issues/205), [#208](https://github.com/Replikanti/agentis-colonies/issues/208), [#210](https://github.com/Replikanti/agentis-colonies/issues/210)). Use `// colony-lint: prompt-gate-ok` on intentional cold-path prompts (legacy alias `// colony-lint: impl-prompt-gate-ok` still works). |
| `check-changelog.sh` | CI-only soft check ([#218](https://github.com/Replikanti/agentis-colonies/issues/218), generalised in [#252](https://github.com/Replikanti/agentis-colonies/issues/252)) that loops over every versioned component (`dev-apprenticeship/`, `federation-dashboard/`): warns when a PR touches a component without updating its `CHANGELOG.md`, hard-fails when its `VERSION` bumps without a matching CHANGELOG entry. No-op without `GITHUB_BASE_REF` (local runs). |
| `make-federation-bundle.sh` | Assembles the curated, install-ready release tarball for a federation ([#220](https://github.com/Replikanti/agentis-colonies/issues/220)). Reads `<federation>/BUNDLE.manifest`, stages paths under `dist/<federation>-v<version>/`, emits `.tar.gz` + `.sha256`. Invoked automatically by `.github/workflows/release.yml` on `<federation>-v*` tag pushes. |
| `make-dashboard-bundle.sh` | Assembles the curated, install-ready release tarball for the standalone `federation-dashboard/` component ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)). Reads `federation-dashboard/BUNDLE.manifest`, validates `federation-dashboard/VERSION` matches the requested version, stages contents flattened under `dist/federation-dashboard-v<version>/`, emits `.tar.gz` + `.sha256`. Excludes `BUNDLE.manifest`, `__pycache__/`, `*.pyc`. Portable sha256 (`sha256sum` or `shasum -a 256`). Invoked automatically by `.github/workflows/release-dashboard.yml` on `federation-dashboard-v*` tag pushes. |
| `parse-toml.sh` | Shared TOML parser sourced by all start-colony.sh scripts |
| `auto-promote.sh` | Layer 1 auto-promote/auto-evolve scheduler script ([#148](https://github.com/Replikanti/agentis-colonies/issues/148)) — classifies experience rows by tag, computes fitness on acting rows only ([#186](https://github.com/Replikanti/agentis-colonies/issues/186)). Scheduling is installed by `dev-apprenticeship/install.sh` §7 and driven by a `start-federation.sh` sidecar ([#216](https://github.com/Replikanti/agentis-colonies/issues/216)). **Never inline heredocs here** (macOS bash 3.2 parser bug; `test-auto-promote.sh` test 10 enforces). Lock acquisition + config parsing live in the two Python helpers below. Full reference: [`doc/auto-promote.md`](./doc/auto-promote.md). |
| `auto-promote-config.yaml` | Decision rules for auto-promote (thresholds, promote steps, evolve triggers, `dry_run`). See [`doc/auto-promote.md`](./doc/auto-promote.md#per-step-rationale). |
| `auto-promote-config-parser.py` | Parses `auto-promote-config.yaml` and emits shell-eval-able `CFG_*` exports on stdout ([#245](https://github.com/Replikanti/agentis-colonies/issues/245)). Extracted from the `PYCONFIG` heredoc in `auto-promote.sh` to dodge the macOS bash 3.2 parser bug — same pattern as the `federation-dashboard-*.py` family (#170 / #172). |
| `auto-promote-lock.py` | Acquires `fcntl.flock(LOCK_EX \| LOCK_NB)` on an inherited fd ([#245](https://github.com/Replikanti/agentis-colonies/issues/245)). Replaces the `flock(1)` binary from util-linux, which is not shipped on stock macOS. Lock is held for the life of the parent shell on both Linux and macOS. |
| `auto-promote-decisions.py` | Per-agent promote/evolve/skip decider ([#245](https://github.com/Replikanti/agentis-colonies/issues/245)). Extracted from the `PYEVAL` heredoc in `auto-promote.sh` for the same macOS bash 3.2 reason — takes 11 positional args (daemons JSON, fed_dir, thresholds, promote steps, evolve window), emits a JSON array of decision records on stdout. Also supports a `--preview --config <yaml>` read-only mode used by `federation-dashboard-collector.py` to keep the dashboard's Promote Candidates list in sync with the sidecar ([#248](https://github.com/Replikanti/agentis-colonies/issues/248)); `test-auto-promote.sh` test 12 enforces byte-identical output between the two modes, test 14 asserts the `evidence.prereqs` structure the dashboard consumes. Every promote-path skip decision carries an `evidence.prereqs` array ({name, value, threshold, op, meets}) the dashboard renders as a per-criterion checklist. |
| `resolve-tick-interval.py` | Shared helper: reads `tick_interval_for()` case statement (or legacy `TICK_INTERVALS`) from start-colony.sh for a given agent+colony. Used by `auto-promote.sh`. The dashboard used to call it too, but post-#257 restart delegates to `start-colony.sh --restart-agent`, which owns the tick lookup itself. |
| `kill-federation.sh` | OS-level reliable shutdown of a federation (agents + dashboard + registry sidecar + backup). Bypasses `agentis daemon stop` bugs via SIGTERM/SIGKILL with verification. `--dry-run` + `--json` for dashboard `/kill` integration ([#161](https://github.com/Replikanti/agentis-colonies/issues/161), [#162](https://github.com/Replikanti/agentis-colonies/issues/162)). Dashboard kills are scoped by daemon-registry membership when `--fed-dir` resolves to a populated `.agentis/daemon/` ([#440](https://github.com/Replikanti/agentis-colonies/issues/440)), so a `federation-dashboard` launched outside the federation's start scripts survives pilot-run cleanup. Empty registry collapses to legacy cwd-only filter. |

## federation-dashboard component

The web dashboard is a **separately-versioned standalone component** under `federation-dashboard/` ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)). It ships its own release tarball (`federation-dashboard-v<X.Y.Z>.tar.gz` + `.sha256`), its own CHANGELOG, and its own XDG-aware `install.sh`. Federations declare a soft minimum via a per-federation pin file (`dev-apprenticeship/.dashboard-version`).

| File | Role |
|------|------|
| `federation-dashboard/VERSION` | Component version (single line, SemVer). Bumping triggers a release-PR check. |
| `federation-dashboard/CHANGELOG.md` | Keep-a-Changelog history for the component. Independent of `dev-apprenticeship/CHANGELOG.md`. |
| `federation-dashboard/README.md` | Operator-facing install + usage reference. |
| `federation-dashboard/BUNDLE.manifest` | Single-line manifest (`federation-dashboard/`) — sanity-checked by `tools/make-dashboard-bundle.sh`. |
| `federation-dashboard/install.sh` | XDG-aware installer. Defaults: data → `${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/`, symlink → `${XDG_BIN_HOME:-$HOME/.local/bin}/federation-dashboard`. Supports `--prefix DIR`, `--uninstall`. Portable across Linux + macOS bash 3.2 (no GNU-only sed flags). |
| `federation-dashboard/bin/federation-dashboard` | Thin shell entry point — discovers colonies/agents, calls the four Python helpers under `lib/`, launches the server. **Zero heredocs of any kind** (`test-timeline-rendering.sh` test 19 enforces). Resolves the federation's shared tools via `<fed-dir>/tools/` first, then `<fed-dir>/../tools/` (so the dashboard works whether the federation is checked out as a sibling tree or a standalone install) and threads the resolved path through to the Python helpers. |
| `federation-dashboard/lib/federation-dashboard-collector.py` | Per-agent data collector (experience stats, `.ag` descriptions, log lines, PID liveness, timeline, confidence history). Also invokes `auto-promote-decisions.py --preview` each regen and surfaces sidecar liveness for the HEALTHY / DEGRADED banner — gracefully no-ops both when the federation does not ship those scripts. |
| `federation-dashboard/lib/federation-dashboard-history.py` | Snapshot appender (per-colony avg confidence skipping null agents per [#143](https://github.com/Replikanti/agentis-colonies/issues/143), plus experience totals) to `history.json`; prunes entries older than 7 days. |
| `federation-dashboard/lib/federation-dashboard-renderer.py` | Template renderer — substitutes 10 named sentinels into `federation-dashboard.html.template`, atomically writes `index.html`. |
| `federation-dashboard/lib/federation-dashboard-server.py` | HTTP server + REST endpoints (`/refresh`, `/confidence`, `/restart`, `/quarantine`, `/evolve`, `/cleanup`, `/start`, `/kill`). `/kill` returns **503** when no `kill-federation.sh` is reachable in either resolved tools dir, instead of hard-asserting at startup. Post-[#257](https://github.com/Replikanti/agentis-colonies/issues/257) `/restart` and `/confidence`-triggered respawns delegate to `<colony>/scripts/start-colony.sh --restart-agent <name>`; the dashboard does not parse `[gitlab]` or compose `GITLAB_*` env itself. |
| `federation-dashboard/lib/federation-dashboard.html.template` | Static HTML/CSS/JS page with 10 `{{SENTINEL}}` placeholders (`FED_NAME`, `FED_NAME_JS`, `COLONY_COUNT`, `AGENT_COUNT`, `EPOCH`, `TIMESTAMP`, `COLLECTOR_JSON`, `HISTORY`, `REMEDIATION`, `COLONY_LIST_JS`). Edit this file, not the shell, to change dashboard markup / styling / JS. 5-tab cut (Status / Cost / Recovery / Logs & Events / Config) per [#362](https://github.com/Replikanti/agentis-colonies/issues/362) iter5. Status tab renders verdict pill, 5-tile stat row including federation-wide cumulative Experience count (`data.experience_counts.total`), per-agent compact table (sortable, click-row → modal), sidecar pills, status-meta, and a 2-column bottom row pairing the Experience Growth chart with a collapsible **Promotion Progress** panel (`<details id="promotion-progress-details">`, default collapsed; `<summary>` shows federation-wide ready / close / not-yet counts; expanded body stacks Phase Readiness above a top-5 Promote Candidates list at `#phase-readiness-host` / `#promote-candidates-host` per [#369](https://github.com/Replikanti/agentis-colonies/issues/369)). Logs & Events tab hosts the federation-wide Event Timeline (chips + colony filter + ABS/REL toggle + Clear stale / Clear all) plus the **Per-Agent Log Tail** card (relocated from Recovery in [#369](https://github.com/Replikanti/agentis-colonies/issues/369)). Confidence Trend, the standalone Promote Candidates / Promotion Ladder cards, and the 21-cell pulse-grid removed in [#362](https://github.com/Replikanti/agentis-colonies/issues/362). |
| `dev-apprenticeship/.dashboard-version` | Per-federation soft minimum dashboard version. Read by `dev-apprenticeship/install.sh` and by `dashboard.sh`'s resolver. |

Releasing: bump `federation-dashboard/VERSION`, move `[Unreleased]` into a dated section in `federation-dashboard/CHANGELOG.md`, merge, then `git tag federation-dashboard-v<X.Y.Z> <merge-sha>` and push. `.github/workflows/release-dashboard.yml` builds the bundle and creates the GitHub release. Full reference: [`doc/federation-dashboard.md`](./doc/federation-dashboard.md).

## Scaffolding a new federation

`tools/new-federation.sh <federation-name> [<starter-colony-name>]` generates a directory shape that conforms to [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md) and passes `colony-lint.sh` clean. Output: `<fed>/VERSION` (`0.1.0`), `<fed>/CHANGELOG.md` (Keep-a-Changelog with empty `[Unreleased]` + dated `[0.1.0]`), `<fed>/BUNDLE.manifest`, `<fed>/README.md`, `<fed>/install.sh`, plus one starter colony with an ADR-0003-conformant `start-colony.sh` (supports `--restart-agent` and `--rate-limit-status`). Colony name defaults to `core`. After scaffolding: add the federation to the `COMPONENTS` array in `tools/check-changelog.sh` and add a row to the top-level `README.md` Federations table. See also [`doc/federation-patterns.md`](./doc/federation-patterns.md) for non-coder federation sketches and [`tools/new-colony.sh`](./tools/new-colony.sh) for adding additional colonies to an existing federation.

# dev-apprenticeship specifics

Everything below this line is true for the `dev-apprenticeship/` federation only. Other federations choose their own colony decomposition, bus events, confidence keys, and operator scripts.

## Federation event wiring

22 colony bus events total: 16 internally wired, 6 extension points (terminal events for external consumption).

Cross-colony events:
- `triage:route_suggestion` -> implementation/code_writer
- `implementation:mr_ready` -> release/release_checker, code-review/approval_decider

Full event-to-consumer mapping:

```
triage:new_issue             -> router, prioritizer, labeler
triage:route_suggestion      -> code_writer (cross-colony)
implementation:code_draft    -> test_writer, refactorer, commit_composer
implementation:test_draft    -> commit_composer
implementation:refactor_suggestions -> commit_composer
implementation:mr_ready      -> release_checker, approval_decider (cross-colony)
review:style_findings        -> approval_decider
review:logic_findings        -> approval_decider
review:security_findings     -> approval_decider
review:test_findings         -> approval_decider
planning:scope_estimate      -> plan_reviewer
planning:risks               -> plan_reviewer
planning:breakdown           -> plan_reviewer
release:check_result         -> ship_decider
release:ship_decision        -> changelog_writer, version_bumper
release:changelog_draft      -> version_bumper
```

6 extension points (no internal listener): `triage:label_suggestion`, `triage:priority_suggestion`, `review:decision_suggestion`, `review:escalation`, `planning:draft_plan`, `release:version_bumped`.

## Confidence keys

| Colony | Keys |
|--------|------|
| triage | `router:confidence`, `prioritizer:confidence`, `labeler:confidence`, `issue_creator:confidence` |
| code-review | `logic_reviewer:confidence`, `style_reviewer:confidence`, `security_reviewer:confidence`, `test_reviewer:confidence`, `approval_decider:confidence` |
| planning | `scope_estimator:confidence`, `risk_assessor:confidence`, `task_decomposer:confidence`, `plan_reviewer:confidence` |
| implementation | `code_writer:confidence`, `test_writer:confidence`, `refactorer:confidence`, `commit_composer:confidence` |
| release | `ship_decider:confidence`, `changelog_writer:confidence`, `version_bumper:confidence`, `release_checker:confidence` |

## End-user scripts (in dev-apprenticeship/)

| Script | Purpose |
|--------|---------|
| `install.sh` | Interactive setup: checks prerequisites, copies configs, writes GitLab credentials, seeds confidence, and (step 8) prompts to install the standalone `federation-dashboard` component pinned at the version in `.dashboard-version`. Set `FEDERATION_DASHBOARD_SKIP=1` to opt out non-interactively. |
| `start-federation.sh` | Starts all 5 colonies (launches 21 daemon processes) |
| `watch-suggestions.sh` | Live feed of agent suggestions from all 21 logs (for suggest mode, confidence 0.6-0.84) |
| `dashboard.sh` | Resolver wrapper for the standalone `federation-dashboard` component ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)). Tries `$FEDERATION_DASHBOARD_BIN` → `${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/bin/federation-dashboard` → `command -v federation-dashboard`; prints clear install instructions when none resolve. `exec`s the binary with this federation's directory + port. |
| `kill-federation.sh` | Reliably stop the federation (wrapper around `tools/kill-federation.sh`, federation-scoped via `--fed-dir`) |
