# CLAUDE.md

## Project overview

A home for [Agentis](https://github.com/Replikanti/agentis) agent **federations** plus federation-agnostic **platform components**. The platform contract every federation must satisfy is normative in [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md). Five federations ship today: `dev-apprenticeship/` — 5 colonies, 22 agents that learn a developer's workflow on GitLab/GitHub (Beta); `tribes-bench/` — 5 tribes hunting memory-safety bugs in vendored Rust crates (Experimental); `trading-binance/` — emergence-driven futures strategy discovery, backtest-only (Alpha); `research-foundry/` — 18-colony research pipeline to human-gated arXiv preprints (Experimental); `dark-factory/` — Solana/Anchor bounty auditing with human-gated submission (Experimental). Federation patterns beyond the coder workflow: [`doc/federation-patterns.md`](./doc/federation-patterns.md); documentation map: [README](./README.md#documentation-map).

This file is split into two parts:
- **Platform invariants** — federation-agnostic. Applies to any federation in this repo.
- **dev-apprenticeship specifics** — bus-event wiring, confidence keys, operator scripts for that one federation.

Long-form references live in `doc/`: [LLM backend deep dive](./doc/llm-backend.md), [tooling reference](./doc/tooling-reference.md), [auto-promote](./doc/auto-promote.md), [federation dashboard](./doc/federation-dashboard.md), [cross-fed memo](./doc/cross-fed-memo.md).

# Platform invariants

## Git workflow

- **Never push directly to main.** Always create a feature branch and open a PR.
- Branch protection is enforced via GitHub rulesets (require PR, no deletion, no force-push).
- Branches are auto-deleted after merge.

## Release process

Each federation is versioned independently. `dev-apprenticeship/` follows [SemVer](https://semver.org/spec/v2.0.0.html); history in [`dev-apprenticeship/CHANGELOG.md`](./dev-apprenticeship/CHANGELOG.md) (Keep a Changelog).

Cutting a release ([#218](https://github.com/Replikanti/agentis-colonies/issues/218), [#220](https://github.com/Replikanti/agentis-colonies/issues/220)):

1. **Release PR** titled `release: dev-apprenticeship v<X.Y.Z>` changing only: `dev-apprenticeship/VERSION`, `CHANGELOG.md` (rename `[Unreleased]` to dated section + fresh empty `[Unreleased]` + comparison link; update the `**Requires:** agentis >= ...` line if the floor moved), optionally README version badges.
2. **After merge:** `git tag dev-apprenticeship-v<X.Y.Z> <merge-sha> -m "..."` + push. `.github/workflows/release.yml` builds the bundle via `tools/make-federation-bundle.sh` and creates the GitHub release. Nothing else to do manually.
3. **Semver:** bus-event rename/removal, agent removal, config-schema break, or ADR-0001 tier-semantics change = **MAJOR**. New agent, new bus event, new optional config key, new default-off install prompt = **MINOR**. Fixes, `.ag` tuning, docs, non-flagging lint rules = **PATCH**.

If a PR adds a runtime dependency under `tools/` that `dev-apprenticeship/` invokes, append it to `dev-apprenticeship/BUNDLE.manifest` in the same PR (`tools/test-make-federation-bundle.sh` enforces manifest integrity and keeps contributor-only tooling out of bundles).

`tools/check-changelog.sh` (CI) warns when a PR touches a versioned component (`dev-apprenticeship/`, `federation-dashboard/`) without a CHANGELOG update, and fails when VERSION bumps without a CHANGELOG entry.

`federation-dashboard/` releases follow the same PR + tag-after-merge dance with its own tag scheme (`federation-dashboard-v<X.Y.Z>`) and workflow (`release-dashboard.yml`).

## Validation

```bash
./tools/colony-lint.sh          # Full lint (structure, config, syntax, exec-sh safety, daemon flags)
bash -n scripts/gitlab-api.sh   # Bash syntax check on any script
```

Colony lint must pass with 0 failures before merge. CI baseline: 292 passed, 0 failed, 6 skipped (no agentis binary on runners). Local runs add ~42 per-agent `.ag` passes when `agentis` is installed.

## LLM backend

Federations default to **flat-cyborg** ([`Replikanti/flat-cyborg`](https://github.com/Replikanti/flat-cyborg)) — a PTY wrapper driving an interactive Claude Code session, so `prompt()` bills against a **flat-rate** subscription instead of the metered API. Two wiring styles:

- **Container federations** (`trading-binance`, `tribes-bench`, `research-foundry`): native backend `llm.backend = flat-cyborg` (requires agentis **>= v1.19.0**; pin `ARG AGENTIS_VERSION`) injected into the hermetic `.agentis/config` by the run/replay orchestrator; host `~/.claude` bind-mounted (`:z` on SELinux/Fedora). Metered `claude`/`openai` fallback stays opt-in via the orchestrator's `*_LLM_BACKEND` env knob. `research-foundry` routes per confidence tier via `llm.tier.<tier>.model`.
- **Host-run federations** (`dev-apprenticeship`, `dark-factory`): `llm.backend = claude` + `llm.command = tools/flat-cyborg-claude.sh`, written by `install.sh`. Workload-based model routing: agent `prompt()` reasoning on **Sonnet 5** (override `CLAUDE_REASONING_MODEL`), code generation in `code-edit-in-checkout.sh` on **Opus 4.8** (override `CODE_EDIT_MODEL`).

Rules that bite:

- A colony's `[llm] backend` in `colony.example.toml` stays `"cli"` = "inherit the federation default". **Never hardcode `"flat-cyborg"` there** — the federation-level `.agentis/config` is the single source of truth.
- **Global LLM-session cap** ([#1352](https://github.com/Replikanti/agentis-colonies/issues/1352)): `tools/lib/llm-session-slot.sh` — a `mkdir`-based counting semaphore, `K = ${LLM_MAX_CONCURRENT:-3}`, covering reasoning AND editing sessions. Waits are bounded (`LLM_SLOT_WAIT_S`, default 120 s) then **fail open**; leaked slots self-heal via PID-liveness reclaim. The fed-fixed slot pool is derived from the allowlisted `COLONY_DIR` (`<COLONY_DIR>/../.agentis/llm-slots`) — agentis-core **force-strips the entire `AGENTIS_*` namespace** from daemon children regardless of `exec.env_passthrough` ([#1426](https://github.com/Replikanti/agentis-colonies/pull/1426)), so the `AGENTIS_LLM_SLOTS_DIR` override only applies to direct invocations. Note: lowering an agent's confidence does NOT reduce `prompt()` volume — dormant agents still prompt each tick.
- The host wrapper reads claude's reply from a **result file** ([#1219](https://github.com/Replikanti/agentis-colonies/issues/1219)); the `--extract` screen-scrape is only a fallback. Prereqs: `flat-cyborg` >= 0.9.0 on PATH + logged-in `~/.claude`.
- **macOS**: the detached editing session cannot reach the login Keychain ([#1343](https://github.com/Replikanti/agentis-colonies/issues/1343)) — provision a `claude setup-token` credential into `CLAUDE_OAUTH_TOKEN_FILE` (install.sh §6). A raw `accessToken` copied from `.credentials.json` is the wrong token type (401).
- `qa_reviewer` judges MRs on an **adversarial** second-opinion dimension ([#1405](https://github.com/Replikanti/agentis-colonies/issues/1405)); `QA_ADVERSARIAL_LLM_CMD` optionally reroutes it to an independent model (its absence never disables the dimension; the reroute only takes effect if the var is on the `exec.env_passthrough` allowlist — see below).
- **`getenv()` reads the SANITIZED env** — only `exec.env_passthrough`-allowlisted vars reach the `.ag` runtime; `/proc/<pid>/environ` shows the pre-strip env and therefore lies. Every getenv-read operator knob MUST be allowlisted (written by `install.sh`) or it is silently inert — proven live on the #1424 burn-in ([#1426](https://github.com/Replikanti/agentis-colonies/pull/1426); audit of the remaining knobs: [#1428](https://github.com/Replikanti/agentis-colonies/issues/1428)).

Full deep dive (env knobs, resolution order, failure modes): [doc/llm-backend.md](./doc/llm-backend.md).

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
- **Gate behaviour on tiers, not raw thresholds.** Call `tier("<agent_name>")` and compare against the five name strings; never inline `confidence >= 0.X` literals. `colony-lint` enforces this.
- The four-tier confidence contract in [`doc/adr/ADR-0001-confidence-tiers.md`](./doc/adr/ADR-0001-confidence-tiers.md) is **normative** for every `.ag` scenario:

  | Tier           | Range         | Behaviour |
  |----------------|---------------|-----------|
  | `shadow`       | `[0.4, 0.6)`  | LLM + memo, no emit, no external write |
  | `propose`      | `[0.6, 0.8)`  | + emit on bus + draft external writes |
  | `review-gated` | `[0.8, 0.95)` | + direct external writes (non-terminal) |
  | `autonomous`   | `[0.95, 1.0]` | + terminal writes (merge, tag, publish) |

  Below `0.4` = `dormant`; the runtime also returns `"dormant"` when the memo is missing, so handle it (typically collapsed into the `shadow` branch).

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

- `get_confidence()` is for diagnostics/logging only — never for branching.
- `learn()` topic must match the topic in `recommend()` within the same agent.
- `memo_write("<agent_name>:last_check", now)` at the end of every tick.
- **Per-issue handled marker + idle gate ([#1370](https://github.com/Replikanti/agentis-colonies/issues/1370)).** An agent acting on the top issue of a snapshot MUST: mark it handled at **every** tier it acts at (`memo_write("<agent>:<iid>:handled", <tier>)` in the autonomous, review-gated, propose, AND shadow branches), FILTER already-handled issues BEFORE indexing (`first_unhandled_iid(...)`), `return` before `prompt()` when none remain, and PIN the prompt to that `target_iid`. Otherwise the staleness gate stays empty at sub-autonomous tiers and `prompt()` re-fires on the same issue forever. `code_writer` uses the tier-independent `input_unchanged()` fingerprint variant. Source-asserted by `tools/test-idle-prompt-gates.sh`; full pattern: [doc/tooling-reference.md](./doc/tooling-reference.md).
- All dynamic values in `exec sh` calls must be wrapped in `shell_escape()`.
- If the grep-based linter cannot see through nested `shell_escape()`, add `// colony-lint: safe-exec-concat` on the line above.
- Emit events use `"<colony_name>:<event_name>"` format.
- For mechanical JSON field extraction from `exec sh` output, prefer `parse_int(to_string(json_get(raw, "[0].iid")))` over `prompt(...) -> list<T>` / `-> map<K,V>` — total on every failure mode (`Void → "void" → 0`) and saves one LLM round-trip per tick.

## Script conventions

- `start-colony.sh`: symlink-safe `$0` resolution via python3, sources `tools/parse-toml.sh`, exports the forge env consumed by `.ag` agents via `exec sh`. Base exports in every colony: `GITLAB_URL`, `GITLAB_TOKEN`, `GITLAB_PROJECT`, `GITLAB_ME`, `COLONY_DIR`; per-colony extras include trigger labels, `PLAN_AUTO_PROMOTE` + `IMPLEMENTATION_TRIGGER_LABEL` ([#1362](https://github.com/Replikanti/agentis-colonies/issues/1362)), `GITLAB_DEFAULT_BRANCH`, and `AG_DRIVEN_EDIT_LOOP` (**default ON** since [#1354](https://github.com/Replikanti/agentis-colonies/issues/1354) step 3; epics/`--decompose` always stay on the in-shell path; on the `exec.env_passthrough` allowlist — required for `getenv()` to see it, [#1426](https://github.com/Replikanti/agentis-colonies/pull/1426)). Tick intervals are deliberately **staggered** per agent (90–300 s) so the 22 daemons don't bunch `prompt()` sessions on one boundary (#146, [#1367](https://github.com/Replikanti/agentis-colonies/issues/1367)). Supports `--restart-agent <name>` ([#257](https://github.com/Replikanti/agentis-colonies/issues/257)); on success prints exactly `started <agent> pid=<n> tick=<ms>` (parsed by the dashboard). Exit codes: 0 ok, 2 usage, 3 unknown agent, 4 launch failure. Full export matrix: [doc/tooling-reference.md](./doc/tooling-reference.md).
- `gitlab-api.sh`: `emit_error()` for all error messages, `exit 2` for unknown flags, `python3 json.dumps` for all POST/PUT bodies. Reads via `gl_get`/`gl_get_q`, writes via `gl_post`/`gl_put`.
- **`merge` verb** (code-review colony, [#1317](https://github.com/Replikanti/agentis-colonies/issues/1317)): the single SAFETY chokepoint of the auto-merge loop. Refuses (`emit_error` + `exit 4`) unless the PR/MR is cleanly mergeable AND CI is all-green (non-empty check list, every run successful); on pass squash-merges + deletes the branch. Reached only at the **autonomous tier** and only with `[code-review] auto_merge = true` (default `false`; exported as `AUTO_MERGE`). A not-ready PR is a logged no-op that retries next tick.
- **`update-issue` verb + plan-approved auto-promotion** (planning colony, [#1362](https://github.com/Replikanti/agentis-colonies/issues/1362)): autonomous-tier planning → implementation handoff — after a successful plan post, adds the implementation trigger label and removes `needs-planning`. Gated by `[planning] auto_promote` (default `false`); epic-class issues are skipped (left for the operator); revise/reject paths never promote.

Verb-level API details: [doc/tooling-reference.md](./doc/tooling-reference.md).

## Tools

| Tool | Purpose |
|------|---------|
| `colony-lint.sh` | Full federation lint (structure, config, `.ag` syntax, exec-sh safety, daemon flag allowlist, markdown links) |
| `new-federation.sh` | Scaffold an [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md)-conformant federation ([#258](https://github.com/Replikanti/agentis-colonies/issues/258)); output passes colony-lint clean |
| `new-colony.sh` | Scaffold a new colony within an existing federation |
| `check-exec-sh.sh` | Grep-based check for unsafe string concat into `exec sh` |
| `check-prompt-gate.sh` | Lint: every `prompt()` needs a same-function memo staleness gate (`// colony-lint: prompt-gate-ok` to waive) |
| `check-changelog.sh` | CI: warn on component change without CHANGELOG update, fail on VERSION bump without entry |
| `make-federation-bundle.sh` | Build the curated release tarball from `BUNDLE.manifest` (invoked by `release.yml`) |
| `make-dashboard-bundle.sh` | Build the `federation-dashboard` release tarball (invoked by `release-dashboard.yml`) |
| `parse-toml.sh` | Shared TOML parser sourced by all start-colony.sh |
| `auto-promote.sh` + `auto-promote-config.yaml` + 3 python helpers | Layer-1 promote/evolve scheduler. **Never inline heredocs** (macOS bash 3.2 parser bug; test 10 enforces). Full reference: [doc/auto-promote.md](./doc/auto-promote.md) |
| `resolve-tick-interval.py` | Tick-interval lookup for agent+colony (used by auto-promote.sh) |
| `kill-federation.sh` | OS-level reliable federation shutdown (SIGTERM/SIGKILL + verification); registry-scoped since [#440](https://github.com/Replikanti/agentis-colonies/issues/440) |
| `flat-cyborg-claude.sh` | Host LLM wrapper (see §LLM backend) |
| `code-edit-in-checkout.sh` | Approach-A code-gen ([#1210](https://github.com/Replikanti/agentis-colonies/issues/1210)): drives claude to edit a per-issue checkout, commits, opens PR/MR. Bounded attempt loop + change-scoped verify gate + `--decompose` for epics. Exit 0 = PR opened, 3 = NO_EDITS (caller retries, not an error) |
| `code-edit-job.sh` | Detached (`setsid`) launcher + cross-tick poll protocol for code-edit; global orchestrator cap `CODE_EDIT_MAX_CONCURRENT=2` ([#1367](https://github.com/Replikanti/agentis-colonies/issues/1367)) |
| `self-observe.sh` | Self-improvement driver ([#1266](https://github.com/Replikanti/agentis-colonies/issues/1266)): `detect-*.sh` findings → deduped, rate-limited tracking issues; per-signal-class acceptance gate ([#1411](https://github.com/Replikanti/agentis-colonies/issues/1411)) |
| `track-issue-outcomes.sh` | Classifies self-filed issue outcomes (`success`/`noise`) into memo JSONL; `--rates` feeds the self-observe gate |
| `lib/outcome-store.sh` | Shared JSONL memo store for outcomes + learn log |
| `lib/llm-session-slot.sh` | Global LLM-session semaphore ([#1352](https://github.com/Replikanti/agentis-colonies/issues/1352), see §LLM backend) |
| `lib/candidate-queue.sh` | Shared queue helper for multi-candidate flows |

Long-form per-tool documentation: [doc/tooling-reference.md](./doc/tooling-reference.md).

## federation-dashboard component

A **separately-versioned standalone component** under `federation-dashboard/` ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)): own release tarball, CHANGELOG, and XDG-aware `install.sh` (data → `~/.local/share/federation-dashboard/`, symlink → `~/.local/bin/`). Federations pin a soft minimum via `dev-apprenticeship/.dashboard-version`.

Layout: `bin/federation-dashboard` (thin shell entry point, **zero heredocs**, resolves federation tools via `<fed-dir>/tools/` then `<fed-dir>/../tools/`) + four Python helpers under `lib/` (collector, history appender, template renderer, HTTP server with `/refresh` `/confidence` `/restart` `/quarantine` `/evolve` `/cleanup` `/start` `/kill` endpoints) + `federation-dashboard.html.template` (static page with 10 `{{SENTINEL}}` placeholders — edit the template, not the shell, for markup/JS changes).

Releasing: bump `federation-dashboard/VERSION` + CHANGELOG, merge, tag `federation-dashboard-v<X.Y.Z>`, push — `release-dashboard.yml` does the rest. Full component reference: [`doc/federation-dashboard.md`](./doc/federation-dashboard.md); file-level table: [doc/tooling-reference.md](./doc/tooling-reference.md).

## Scaffolding a new federation

`tools/new-federation.sh <federation-name> [<starter-colony-name>]` generates an [ADR-0003](./doc/adr/ADR-0003-federation-portability-contract.md)-conformant tree (`VERSION`, `CHANGELOG.md`, `BUNDLE.manifest`, `README.md`, `install.sh`, one starter colony) that passes `colony-lint.sh` clean. After scaffolding: add the federation to the `COMPONENTS` array in `tools/check-changelog.sh` and a row to the top-level `README.md` Federations table. See [`doc/federation-patterns.md`](./doc/federation-patterns.md) for non-coder federation sketches.

## Cross-federation memo (`cross-fed:*`)

A shared memo namespace readable + writable by all federations on the same host; productive methods cross-pollinate through it.

- Conventions: `doc/cross-fed-memo.md`.
- Storage: `<repo-root>/cross-fed-memo/` host dir, file-per-key, mirrored to each fed's `.agentis/memo/cross-fed:*` by `tools/cross-fed-bridge.sh sidecar`.
- Export happens at `_publish_<role>` autonomous-tier paths when a method clears the replicate + export-fitness thresholds; import at bootstrap via `cross-fed:adopt-queue:<target-fed>`.
- Operator curates `cross-fed:applicable-to:<method-id>`.

# dev-apprenticeship specifics

Everything below is true for `dev-apprenticeship/` only. Other federations choose their own colony decomposition, bus events, confidence keys, and operator scripts.

## Federation event wiring

23 colony bus events total: 16 internally wired, 7 extension points.

Cross-colony: `triage:route_suggestion` -> implementation/code_writer; `implementation:mr_ready` -> release/release_checker + code-review/approval_decider.

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

7 extension points (no internal listener): `triage:label_suggestion`, `triage:priority_suggestion`, `review:decision_suggestion`, `review:escalation`, `review:qa_verdict` (gating approval on it is [#1359](https://github.com/Replikanti/agentis-colonies/issues/1359) step 3), `planning:draft_plan`, `release:version_bumped`.

## Confidence keys

| Colony | Keys |
|--------|------|
| triage | `router:confidence`, `prioritizer:confidence`, `labeler:confidence`, `issue_creator:confidence` |
| code-review | `logic_reviewer:confidence`, `style_reviewer:confidence`, `security_reviewer:confidence`, `test_reviewer:confidence`, `qa_reviewer:confidence`, `approval_decider:confidence` |
| planning | `scope_estimator:confidence`, `risk_assessor:confidence`, `task_decomposer:confidence`, `plan_reviewer:confidence` |
| implementation | `code_writer:confidence`, `test_writer:confidence`, `refactorer:confidence`, `commit_composer:confidence` |
| release | `ship_decider:confidence`, `changelog_writer:confidence`, `version_bumper:confidence`, `release_checker:confidence` |

## End-user scripts (in dev-apprenticeship/)

| Script | Purpose |
|--------|---------|
| `install.sh` | Interactive setup: prerequisites, configs, credentials, confidence seed; step 8 offers the `federation-dashboard` install pinned at `.dashboard-version` (`FEDERATION_DASHBOARD_SKIP=1` to opt out) |
| `start-federation.sh` | Starts all 5 colonies (22 daemon processes) |
| `watch-suggestions.sh` | Live feed of agent suggestions from all 22 logs (suggest mode) |
| `dashboard.sh` | Resolver wrapper for the standalone dashboard: `$FEDERATION_DASHBOARD_BIN` → XDG data dir → `command -v`; prints install instructions when none resolve |
| `kill-federation.sh` | Reliably stop the federation (wrapper around `tools/kill-federation.sh --fed-dir`) |
