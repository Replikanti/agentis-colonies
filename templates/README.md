# Pre-built agent templates

Curated, copy-pasteable starter agents that drop into any colony conforming
to the platform contract ([ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md)).
Issue [#322](https://github.com/Replikanti/agentis-colonies/issues/322) tracks
the v1 catalog rollout.

Templates land here as standalone `.ag` files. The
[`tools/scaffold-agent.sh`](../tools/scaffold-agent.sh) entry point copies a
template into an existing colony's `agents/` directory, performs any
`__TEMPLATE_VAR__` substitutions, and prints the destination path on stdout.

```bash
tools/scaffold-agent.sh <template> <federation> <colony> [--name <local-name>] [--force]
```

- `<template>` resolves against `templates/agents/<template>.ag`.
- `<federation>` resolves against the repo root first, then as an absolute
  path (mirrors `tools/auto-promote.sh` / `tools/cost-cap.sh`).
- `<colony>` resolves as `<federation>/<colony>` and is asserted to have
  the conformant shape (`agents/` + `scripts/start-colony.sh` present).
- `--name <local-name>` renames the scaffolded `.ag` (default: same as
  the template name).
- `--force` overwrites an existing destination.

Exit codes: `0` ok, `1` destination conflict, `2` template / federation /
colony not found, `3` unknown flag.

## Catalog

| Template | Purpose | At `autonomous` | Required env | Recommended placement | Status |
|----------|---------|-----------------|--------------|-----------------------|--------|
| [`stale-issue-closer`](./agents/stale-issue-closer.ag) | Closes issues idle past N days (soft default 30, hard default 60) with a "is this still relevant?" warning at the propose / review-gated tiers. | Adds the `stale` label and posts a "closing as stale" note after the warning has been ignored for the hard window. | `[forge]` block configured. Optional `STALE_DAYS` (soft, default 30) and `STALE_DAYS_HARD` (hard, default 60). | Any colony with a `forge-api.sh` exposing `issues` + `add-note` + `update-issue` (e.g. a triage / planning-shaped colony). | v1 canary (PR 1 of [#322](https://github.com/Replikanti/agentis-colonies/issues/322)) |
| [`dependency-updater`](./agents/dependency-updater.ag) | Observes Dependabot / Renovate-style PRs, drafts a "good to merge" assessment as a PR comment at `propose`, posts an LGTM approval note at `review-gated`. | Merges the PR after CI green + no conflicts + denylist miss. Falls back to the review-gated approval note if the colony's `forge-api.sh` does not yet implement the `merge` verb. | `[forge]` block configured. Optional `[dependency_updater].denied_packages` (CSV of package names exempt from the autonomous merge path). | A colony with `forge-api.sh` exposing `merge-requests` + `post-note` + (for autonomous) `merge` (typically a release-shaped or implementation-shaped colony with the trigger labels disabled). | v1 (PR 2 of [#322](https://github.com/Replikanti/agentis-colonies/issues/322)) |
| [`security-scanner`](./agents/security-scanner.ag) | Auto-detects which language toolchain the repo uses (`package-lock.json` / `Cargo.lock` / `requirements.txt`), runs the corresponding audit command (`npm audit` / `cargo audit` / `pip-audit`) on a daily-windowed cadence, files a forge issue at `review-gated` and `autonomous`. | Files the issue and (when `[security_scanner].oncall_handle` is configured) assigns it to the on-call rotation. | `[forge]` block configured, the audit toolchain reachable on PATH. Optional `[security_scanner].oncall_handle`. | A colony with `forge-api.sh` exposing `create-issue` + `update-issue` (e.g. a triage-shaped colony). The repo under audit is assumed to be `$COLONY_DIR/..` — operators with a different layout should fork. | v1 (PR 2 of [#322](https://github.com/Replikanti/agentis-colonies/issues/322)) |
| [`release-manager`](./agents/release-manager.ag) | Generalises `dev-apprenticeship/release/ship_decider.ag` over an arbitrary repo: surveys merged PRs since the last release tag, drafts a Keep-a-Changelog-style block, opens a "release: vX.Y.Z" PR at `review-gated`. | Merges the release PR + creates the tag + creates the GitHub/GitLab release — but ONLY when `[release_manager].auto_tag = "true"` is explicitly set AND no release happened in the last 24h (built-in double-release guard). | `[forge]` block configured. Optional `[release_manager].auto_tag` (default off) and `[release_manager].release_branch` (default `main`). | A colony with `forge-api.sh` exposing `releases` + `merge-requests` + `create-mr` + (for autonomous) `merge` + `create-tag` + `create-release` (typically a release-shaped colony — but unlike `dev-apprenticeship/release/`, this template is repo-agnostic, NOT tied to the dev-apprenticeship layout). | v1 (PR 2 of [#322](https://github.com/Replikanti/agentis-colonies/issues/322)) |

The remaining v1 templates land in PR 3 of the same issue:

- `pr-triage` — auto-assigns reviewers from a CODEOWNERS-style heuristic plus area labels.
- `digest-poster` — daily / weekly summary of open issues + recent merges to a configurable channel.

## Doc-of-record format

Every template MUST:

- Live as a single `.ag` file under `templates/agents/`.
- Open with a `// TEMPLATE: <name> — <purpose> | customization: <points>` header line so operators can grep the catalog.
- Cover all four tiers (`shadow` / `propose` / `review-gated` / `autonomous`) per [ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md).
- Use `tier("<agent_name>")` once per tick and branch on the returned name string — never inline a `confidence >= 0.X` literal.
- Memo-gate any LLM `prompt(...)` via `recall_latest("<agent_name>:last_check")`.
- Wrap every dynamic value in an `exec sh` call in `shell_escape(...)`.
- Use `parse_int(to_string(json_get(raw, ...)))` for mechanical JSON-field extraction (per the CLAUDE.md idiom; saves an LLM round-trip).
- End every `tick()` with `memo_write("<agent_name>:last_check", now)`.
- Match `learn(...)` topic to `recommend(...)` topic within the same agent.
- Source forge calls only via `$COLONY_DIR/scripts/forge-api.sh` (never the per-backend `gitlab-api.sh` / `github-api.sh` directly — see [ADR-0002](../doc/adr/ADR-0002-forge-abstraction.md)).
- Pass `bash tools/colony-lint.sh` clean once scaffolded into a colony (the lint discovers `.ag` files only under `<fed>/<colony>/agents/`, not the bare `templates/agents/` tree).

Operators who customize a scaffolded agent are encouraged to leave the
`// TEMPLATE: ...` header line in place so future template diffs are easy
to track via `diff <colony>/agents/<name>.ag templates/agents/<name>.ag`.

## Multi-agent presets (deferred)

`templates/colonies/<name>/` will host whole-colony presets in a future
follow-up. v1 ships single-agent templates only; cross-agent bus-event
wiring stays the operator's responsibility for now.
