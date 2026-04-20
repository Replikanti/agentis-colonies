# CLAUDE.md

## Project overview

Pre-built agent colonies for the [Agentis](https://github.com/Replikanti/agentis) runtime. The `dev-apprenticeship/` federation contains 5 colonies (21 agents) that learn a developer's workflow by observing how they work on GitLab. All 21 agents implement the full confidence gradient (observe / suggest / act).

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

`colony-lint` (via `tools/check-changelog.sh`) warns whenever a PR touches `dev-apprenticeship/` without updating `CHANGELOG.md`, and fails whenever `VERSION` bumps without a matching CHANGELOG entry.

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

- `start-colony.sh`: symlink-safe `$0` resolution via python3, sources `tools/parse-toml.sh`, exports the GitLab-connection env vars consumed by each colony's `.ag` agents via `exec sh`. Base exports in every colony: `GITLAB_URL`, `GITLAB_TOKEN`, `GITLAB_PROJECT`, `GITLAB_ME` ([#104](https://github.com/Replikanti/agentis-colonies/issues/104)), `COLONY_DIR`. Per-colony additions: `planning` exports `PLANNING_TRIGGER_LABEL` ([#223](https://github.com/Replikanti/agentis-colonies/issues/223)); `implementation` exports `IMPLEMENTATION_TRIGGER_LABEL` ([#225](https://github.com/Replikanti/agentis-colonies/issues/225)) and `GITLAB_DEFAULT_BRANCH` ([#224](https://github.com/Replikanti/agentis-colonies/issues/224)); `release` exports `GITLAB_DEFAULT_BRANCH` ([#224](https://github.com/Replikanti/agentis-colonies/issues/224)). For prompt-vocabulary knobs that must be readable from inside `.ag` scenarios, `planning/scripts/start-colony.sh` and `triage/scripts/start-colony.sh` additionally seed the memo store on startup: `planning:labels:incident`, `planning:labels:epic`, and `triage:labels:priority` are `agentis memo set` from `[planning.labels]` / `[triage.labels]` when non-empty ([#226](https://github.com/Replikanti/agentis-colonies/issues/226)). Launches daemons with `--colony <name> --tick-interval "$interval"` where `interval` is looked up per-agent via a local `tick_interval_for()` case function (fallback 60000ms). Reactive colonies (release, code-review) run at 300000ms, triage's router/prioritizer at 180000ms, everything else at 60000ms. See #146 for rationale.
- `gitlab-api.sh`: `emit_error()` for all error messages, `exit 2` for unknown flags, `python3 json.dumps` for all POST/PUT body construction. Read endpoints use `gl_get`/`gl_get_q`, write endpoints use `gl_post`/`gl_put`.

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

## Tools

| Tool | Purpose |
|------|---------|
| `colony-lint.sh` | Full federation lint (structure, config, .ag syntax, exec-sh safety, daemon flag allowlist, markdown links) |
| `new-colony.sh` | Scaffold a new colony (creates dirs, example config, starter scripts) |
| `check-exec-sh.sh` | Grep-based check for unsafe string concat into `exec sh`. See `check-exec-sh.md` for known limitations. |
| `check-prompt-gate.sh` | Grep/awk lint that ensures every `prompt()` in `implementation/`, `planning/`, `code-review/`, and `triage/` agents is preceded (same function) by a memo-based staleness gate (`recall_latest()` or gate fn) ([#200](https://github.com/Replikanti/agentis-colonies/issues/200), [#201](https://github.com/Replikanti/agentis-colonies/issues/201), [#205](https://github.com/Replikanti/agentis-colonies/issues/205), [#208](https://github.com/Replikanti/agentis-colonies/issues/208), [#210](https://github.com/Replikanti/agentis-colonies/issues/210)). Use `// colony-lint: prompt-gate-ok` on intentional cold-path prompts (legacy alias `// colony-lint: impl-prompt-gate-ok` still works). |
| `check-changelog.sh` | CI-only soft check ([#218](https://github.com/Replikanti/agentis-colonies/issues/218)) that warns when a PR touches `dev-apprenticeship/` without updating `dev-apprenticeship/CHANGELOG.md`, and hard-fails when `dev-apprenticeship/VERSION` bumps without a matching CHANGELOG entry. No-op without `GITHUB_BASE_REF` (local runs). |
| `make-federation-bundle.sh` | Assembles the curated, install-ready release tarball for a federation ([#220](https://github.com/Replikanti/agentis-colonies/issues/220)). Reads `<federation>/BUNDLE.manifest`, stages paths under `dist/<federation>-v<version>/`, emits `.tar.gz` + `.sha256`. Invoked automatically by `.github/workflows/release.yml` on `<federation>-v*` tag pushes. |
| `parse-toml.sh` | Shared TOML parser sourced by all start-colony.sh scripts |
| `federation-dashboard.sh` | Generic web dashboard for any federation — auto-discovers colonies/agents, serves operator controls (promote, demote, evolve, restart, kill). Thin shell; orchestrates the four Python helpers + HTML template below. **Never inline heredocs here** (macOS bash parser bug; `test-timeline-rendering.sh` tests 13–19 enforce). Full reference: [`doc/federation-dashboard.md`](./doc/federation-dashboard.md). |
| `federation-dashboard-collector.py` | Per-agent data collector (experience stats, `.ag` descriptions, log lines, PID liveness, timeline, confidence history). Called by `federation-dashboard.sh` once per regen. See [`doc/federation-dashboard.md`](./doc/federation-dashboard.md#architecture). |
| `federation-dashboard-history.py` | Snapshot appender (per-colony avg confidence skipping null agents per [#143](https://github.com/Replikanti/agentis-colonies/issues/143), plus experience totals) to `history.json`; prunes entries older than 7 days. |
| `federation-dashboard-renderer.py` | Template renderer — substitutes 10 named sentinels into `federation-dashboard.html.template`, atomically writes `index.html`. |
| `federation-dashboard-server.py` | HTTP server for the dashboard + REST endpoints (`/refresh`, `/confidence`, `/restart`, `/quarantine`, `/evolve`, `/cleanup`, `/start`, `/kill`). |
| `federation-dashboard.html.template` | Static HTML/CSS/JS page with 10 `{{SENTINEL}}` placeholders (`FED_NAME`, `FED_NAME_JS`, `COLONY_COUNT`, `AGENT_COUNT`, `EPOCH`, `TIMESTAMP`, `COLLECTOR_JSON`, `HISTORY`, `REMEDIATION`, `COLONY_LIST_JS`). Edit this file, not the shell, to change dashboard markup / styling / JS. |
| `auto-promote.sh` | Layer 1 auto-promote/auto-evolve scheduler script ([#148](https://github.com/Replikanti/agentis-colonies/issues/148)) — classifies experience rows by tag, computes fitness on acting rows only ([#186](https://github.com/Replikanti/agentis-colonies/issues/186)). Scheduling is installed by `dev-apprenticeship/install.sh` §7 and driven by a `start-federation.sh` sidecar ([#216](https://github.com/Replikanti/agentis-colonies/issues/216)). Full reference: [`doc/auto-promote.md`](./doc/auto-promote.md). |
| `auto-promote-config.yaml` | Decision rules for auto-promote (thresholds, promote steps, evolve triggers, `dry_run`). See [`doc/auto-promote.md`](./doc/auto-promote.md#per-step-rationale). |
| `resolve-tick-interval.py` | Shared helper: reads `tick_interval_for()` case statement (or legacy `TICK_INTERVALS`) from start-colony.sh for a given agent+colony (used by dashboard + auto-promote) |
| `kill-federation.sh` | OS-level reliable shutdown of a federation (agents + dashboard + registry sidecar + backup). Bypasses `agentis daemon stop` bugs via SIGTERM/SIGKILL with verification. `--dry-run` + `--json` for dashboard `/kill` integration ([#161](https://github.com/Replikanti/agentis-colonies/issues/161), [#162](https://github.com/Replikanti/agentis-colonies/issues/162)). |

## End-user scripts (in dev-apprenticeship/)

| Script | Purpose |
|--------|---------|
| `install.sh` | Interactive setup: checks prerequisites, copies configs, writes GitLab credentials, seeds confidence |
| `start-federation.sh` | Starts all 5 colonies (launches 21 daemon processes) |
| `watch-suggestions.sh` | Live feed of agent suggestions from all 21 logs (for suggest mode, confidence 0.6-0.84) |
| `dashboard.sh` | Web dashboard (wrapper around `tools/federation-dashboard.sh`, includes kill switch) |
| `kill-federation.sh` | Reliably stop the federation (wrapper around `tools/kill-federation.sh`, federation-scoped via `--fed-dir`) |
