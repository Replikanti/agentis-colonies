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

| Template | Purpose | At `autonomous` | Required env | Status |
|----------|---------|-----------------|--------------|--------|
| [`stale-issue-closer`](./agents/stale-issue-closer.ag) | Closes issues idle past N days (soft default 30, hard default 60) with a "is this still relevant?" warning at the propose / review-gated tiers. | Adds the `stale` label and posts a "closing as stale" note after the warning has been ignored for the hard window. | `[forge]` block configured. Optional `STALE_DAYS` (soft, default 30) and `STALE_DAYS_HARD` (hard, default 60). | v1 canary (PR 1 of [#322](https://github.com/Replikanti/agentis-colonies/issues/322)) |

The remaining v1 templates land in PR 2 and PR 3 of the same issue:

- `dependency-updater` — polls the forge for stale-dependency PRs (Dependabot-style); merges minor/patch dep PRs with green CI at the autonomous tier.
- `security-scanner` — runs `cargo audit` / `npm audit` / `pip-audit` and files an issue per new advisory.
- `release-manager` — generalises `dev-apprenticeship/release/ship_decider.ag`; tags + creates the release at the autonomous tier.
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
