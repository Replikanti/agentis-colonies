---
id: ADR-0002
title: Forge abstraction — normalized wrapper dispatch for multi-forge federations
status: Proposed
date: 2026-04-23
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [portability, forge, gitlab, github, dev-apprenticeship]
---

# ADR-0002: Forge abstraction — normalized wrapper dispatch for multi-forge federations

## Context

`dev-apprenticeship` is currently 100% GitLab-coupled. A grep across the
21 `.ag` agents surfaces 144 `gitlab` / `GITLAB` references. Each of the
five colonies ships its own `gitlab-api.sh` wrapper (~500 LOC each). The
JSON shape consumed by agents mirrors GitLab's REST responses verbatim
(`iid`, `merge_requests`, `approvals` fields, `/resource_label_events`
timeline).

`agentis-colonies` itself ships as a GitHub repository. Every potential
contributor or operator who runs `dev-apprenticeship` against GitHub
bounces off `install.sh` step 1. The portability gap is the most
visible adoption blocker in the project today.

Partial groundwork already exists. #223–#226 introduced env-driven
label vocabulary (`PLANNING_TRIGGER_LABEL`, `IMPLEMENTATION_TRIGGER_LABEL`),
a forge-agnostic default-branch knob (`GITLAB_DEFAULT_BRANCH`, name
notwithstanding), and memo-seeded prompt vocabulary. The confidence-tier
contract from ADR-0001, the auto-promote sidecar, the dashboard, and
the experience store are already forge-agnostic by construction. The
remaining coupling is in the API-call layer — the `gitlab-api.sh`
wrappers and the JSON shape agents parse from them.

The intent of this ADR is **not** a thin-slice GitHub PoC or a second
federation fork. One federation, one install, one CHANGELOG — forge
choice is a configuration toggle. #257 removed the last forge coupling
from the federation-dashboard side (restart delegates to
`start-colony.sh`, which owns env wiring), so the remaining surface is
exactly the colony `.ag` → wrapper → REST path.

## Decision

Adopt **wrapper dispatch with normalized JSON** as the forge
abstraction boundary.

```
.ag agent
  │
  ▼
exec sh "$COLONY_DIR/scripts/forge-api.sh <subcommand> <args>"
  │
  ▼                (new thin dispatcher; reads $FORGE_TYPE)
forge-api.sh
  │
  ├──> gitlab-api.sh <subcommand> <args>     (existing, modified to
  │                                           emit normalized JSON)
  └──> github-api.sh <subcommand> <args>     (new, emits the same
                                              normalized JSON)
```

Agents keep calling the `exec sh` subcommand interface they already
use. They receive an identical JSON shape regardless of backend. The
translation from backend-specific REST to the normalized shape happens
in exactly one place per subcommand: inside the backend's
`<backend>-api.sh` wrapper, with help from shared normalization
helpers in `tools/forge-normalize.sh`.

### Configuration

```toml
# colony.toml
[forge]
type = "github"               # or "gitlab"

[forge.github]
owner = "me"
repo  = "myrepo"
token = "ghp_your-token-here"

[forge.gitlab]
url     = "https://gitlab.com"
project = "your-org/your-project"
token   = "glpat-your-token-here"
```

Values are literal strings. `parse-toml.sh` does not expand `${VAR}`
references — tokens are stored verbatim in `colony.toml` (which is
`chmod 600`) and `install.sh` writes the literal operator-supplied
token, not an env-var reference. The `project` field is a path string
(`owner/repo` or `group/subgroup/project`), matching the existing
`[gitlab].project` convention; `gitlab-api.sh` URL-encodes it to
`%2F`-separated form before calling the API.

`start-colony.sh` reads `[forge].type`, exports `FORGE_TYPE`, and
continues to export the legacy `GITLAB_*` env for backwards
compatibility during the migration window (one release). After the
release PR at the end of the port, the top-level `[gitlab]` section is
retired and `[forge.*]` is authoritative.

### Normalized shape contract (normative)

Every subcommand emits a fixed JSON shape. The following table is the
authoritative contract; `test-forge-api.sh` enforces byte-identical
output for matching fixtures across both backends.

**Per-PR rollout.** PR 1 shipped the dispatcher skeleton and config
schema only. PR 2 (the current PR as of this writing) ships the triage
colony's `github-api.sh` with 7 subcommands (`issues`, `create-issue`,
`update-issue`, `members`, `get-issue`, `labels`, `add-note`) plus the
`[forge.github]` env-export branch in `triage/scripts/start-colony.sh`.
The remaining colonies' wrappers land across PRs 3-6 in the order
planning → implementation → code-review → release. `rate-limit-status`
and the dashboard tile ship in PR 7 alongside the legacy
`[gitlab]`-section retirement.

**`.ag` migration is in-scope for every per-colony PR.** Each
per-colony PR (PRs 2-6) MUST rewrite every `exec sh` call site in that
colony's `.ag` agents from `scripts/gitlab-api.sh` to
`scripts/forge-api.sh`. A colony that only ships `github-api.sh`
without rewriting its `.ag` files is a silent-failure landmine: under
`FORGE_TYPE=github`, `start-colony.sh` exports only `GITHUB_*` env, the
direct `gitlab-api.sh` call trips its env check and exits 1, and the
`.ag` try/catch swallows the error — the colony ticks doing zero work.
The `check-forge-dispatch.sh` lint fires per-colony (once that colony
ships a concrete `github-api.sh`), so forgetting this step breaks CI.

**PR 2 deviations from the table below.** The triage contract in PR 2
is a subset of the "full" shape listed here, because triage agents only
consume issue + member + label data and only need the seven subcommands
enumerated above — there are no `merge-requests`, `mr-*`, or
`rate-limit-status` calls in any triage `.ag` agent. That part of the
contract will be implemented incrementally as PRs 3-6 wire it into the
colonies that actually need it. Triage's `add-note` is a new subcommand
not in the original ADR table; it is added here and back-ported to
`triage/scripts/gitlab-api.sh` to match (the `.ag` agents were calling
it against a non-existent gitlab-api.sh arm before PR 2, silently
swallowed by `try/catch`).

| Subcommand           | Normalized output |
|----------------------|-------------------|
| `get-issue <n>`      | `{"number", "title", "description", "labels": [...], "state", "assignees": [...], "author", "web_url"}` |
| `list-open-issues`   | `[{...get-issue shape...}, ...]` |
| `create-issue`       | `{...get-issue shape of the created issue...}` |
| `update-issue`       | `{...get-issue shape after update...}` |
| `merge-requests`     | `[{"number", "title", "state", "draft": bool, "labels", "source_branch", "target_branch", "author", "web_url"}, ...]` |
| `mr-changes <n>`     | `[{"path", "diff"}, ...]` |
| `mr-commits <n>`     | `[{"sha", "title", "author", "created_at"}, ...]` |
| `mr-notes <n>`       | `[{"author", "body", "created_at", "system": bool}, ...]` |
| `post-note <n> <body>` | `{"id", "author", "created_at"}` |
| `create-mr`          | `{...merge-requests shape of the created MR/PR...}` |
| `create-branch`      | `{"name", "sha"}` |
| `commit-files`       | `{"sha", "branch"}` |
| `approvals <n>`      | `{"approved": bool, "approvers": [...], "required": N}` |
| `approve <n>`        | `{"approved": bool, "approvers": [...]}` |
| `labels`             | `[{"name", "color", "description"}, ...]` |
| `members`            | `[{"username", "name", "access_level": "maintainer\|developer\|reporter"}, ...]` |
| `label-events <n>`   | `[{"action": "added\|removed", "label", "user", "created_at"}, ...]` |
| `issues-by-label-events <labels>` | `[{"issue": {...get-issue...}, "events": [...label-events...]}, ...]` |
| `assigned-issues`    | `[{...get-issue shape...}, ...]` |
| `issue-label-events` | alias of `label-events` for issue-scoped consumption |
| `assigned-issues-by-label-events <labels>` | `[{...}, ...]` composed from the two above |
| `pipeline-status <sha>` | `{"status": "success\|failed\|running\|pending", "web_url"}` |
| `releases`           | `[{"tag", "name", "created_at", "body"}, ...]` |
| `tags`               | `[{"name", "sha", "created_at"}, ...]` |
| `create-tag`         | `{"name", "sha"}` |
| `create-release`     | `{"tag", "name", "web_url"}` |
| `rate-limit-status`  | `{"remaining", "limit", "reset_at"}` |

Agents never see REST responses directly. Anywhere agents currently
read `.iid`, they read `.number`. Anywhere they currently pattern-match
on `state == "opened"`, the wrapper normalizes to `"open"`.

### Semantic collapses (where shape loses fidelity)

Several asymmetries cannot be papered over; the wrapper resolves them
by collapsing to the simpler semantic and documenting the collapse
here.

| Concept | GitLab | GitHub | Collapse |
|---------|--------|--------|----------|
| Issue/MR ID | `iid` (per-project) | `number` (per-repo) | Always emit `number`. |
| Approvals | Threshold-based boolean + approver list | Review state machine (`APPROVED` / `CHANGES_REQUESTED` / `COMMENTED` / `DISMISSED` / `PENDING`) | Emit `{approved: bool, approvers: [...]}`. Rule: count latest non-dismissed review per reviewer with state `APPROVED`; `approved = (count >= required)` where `required` comes from the ruleset / branch protection. `CHANGES_REQUESTED` collapses to "not approved"; agents do not see the negative-review signal in this normalized shape. |
| Pipeline / CI | `/projects/:id/pipelines/:sha` | `/repos/:o/:r/actions/runs?head_sha=:sha` (iterate workflow runs, aggregate) | Emit `{status: success \| failed \| running \| pending}`. Multiple GitHub workflow runs for the same SHA aggregate as: any failed → `failed`; any running/queued and none failed → `running`; all success → `success`; else `pending`. |
| Label events | `/resource_label_events` (one event type) | `/issues/:n/timeline` (20+ event types) | Filter timeline to `labeled` / `unlabeled`; drop everything else. |
| Draft | Title prefix `Draft:` / `WIP:` | `draft: true` boolean | Always emit `draft: bool`. The GitLab wrapper parses the title prefix. |
| Pagination | `X-Next-Page` header | `Link: <...>; rel="next"` | Both wrappers implement an internal paginator and emit a single flat JSON array. No cursor / next-page surface is exposed to agents. |
| Atomic multi-file commit | Single API call | Four-step tree/blob/commit/ref update | `commit-files` is transactional on GitLab, best-effort on GitHub. Retry: up to 3 fast-forward retries if the branch tip advances mid-operation. On persistent conflict the wrapper surfaces a non-zero exit with a structured error JSON (`{error: "branch_advanced", attempts: 3}`) rather than silently force-pushing. |

Where a collapse loses useful signal, the rationale and the reverse
direction (how an agent can still inspect the lost detail, typically
via a follow-up subcommand) are called out in the per-PR CHANGELOG
entry for the affected colony.

### Non-goals

- **Gitea, Forgejo, Bitbucket**. The ADR deliberately scopes the shape
  contract to exactly GitLab + GitHub. A future ADR may extend the
  `FORGE_TYPE` enum once the shape has been stable for one release.
- **Polyglot federations**. One federation = one forge. `FORGE_TYPE`
  is a single value, not a list. A user who wants to mirror a
  federation onto a second forge runs a second install.
- **Keeping the top-level `[gitlab]` config section past the final
  release of the port.** One release of overlap, then retire.
- **Agent-layer knowledge of forge semantics.** Agents may branch on
  `$FORGE_TYPE` only for prompt-vocabulary tweaks ("pull request" vs
  "merge request"); they must never embed forge-specific API logic or
  parse forge-specific JSON.

## Consequences

### Migration of existing `.ag` scenarios

Every `gitlab`-ism in the 21 agents is an edit point:

- `parse_int(to_string(json_get(raw, "[0].iid")))` → `[0].number`.
- Prompt strings mentioning "GitLab" / "MR" get the `$FORGE_TYPE`-aware
  treatment (either a generic term like "pull request" or a
  conditional phrasing).
- `shell_escape("$COLONY_DIR/scripts/gitlab-api.sh …")` →
  `forge-api.sh`. `colony-lint` gains a rule that `.ag` files must not
  reference `gitlab-api.sh` or `github-api.sh` directly.

Per-colony edits land in the colony-port PRs (PRs 2–6 of #256).

### Runtime changes

- `start-colony.sh` across all 5 colonies reads `[forge].type` and
  exports `FORGE_TYPE`. Existing `GITLAB_*` exports are kept for one
  release of overlap.
- `tools/forge-normalize.sh` (new) ships shared helpers: pagination
  walker, label-event filter, draft-flag inferrer, approvals collapse.
- `install.sh` gains a forge-choice prompt, defaulting to GitLab for
  one release then "ask" (no default) at the end of the port.
  `FEDERATION_FORGE_TYPE=github|gitlab` env var short-circuits prompts
  for unattended installs.

### Rate limits

GitHub authenticated: 5000 req/h per token. Worst-case projection with
current tick intervals:

- triage (60s) × 4 agents × ~3 req/tick = 720/h
- planning (60s) × 4 × ~3 = 720
- implementation (60s) × 4 × ~3 = 720
- code-review (300s) × 5 × ~3 = 180
- release (300s) × 4 × ~3 = 144
- **Total: ~2500 req/h** — comfortably under the limit.

`rate-limit-status` subcommand + a dashboard tile are added in PR 7 of
#256 so operators see a live remaining/limit counter. If a real install
trips, the fix is per-agent tick-interval tuning, not a change to this
ADR.

### Testing

- `tools/test-forge-api.sh` (new) — fixture-based replay harness.
  Recorded GitLab + GitHub JSON blobs for every subcommand; wrappers
  run against the fixtures via an HTTP-shim; output compared
  byte-for-byte against the normalized contract.
- `tools/test-forge-normalize.sh` (new) — unit tests for the
  translation helpers.
- `colony-lint.sh` — new rule: `.ag` files must use `forge-api.sh`,
  never the backend-specific wrappers.

### Versioning

The final release PR of #256 (PR 7) is a **MAJOR** `dev-apprenticeship`
bump — `[forge]` is a new config-schema key and the top-level
`[gitlab]` section is retired, both of which are breaking changes per
the release-process rules in `CLAUDE.md`.

Foundation PRs (PR 1 of this series, which introduces the ADR + config
schema + dispatcher skeleton under the default `FORGE_TYPE=gitlab`) are
**MINOR**: additive config, no break.

## Alternatives considered

### Second federation fork (dev-apprenticeship-github)

Copy the whole federation into a second tree with GitLab wrappers
replaced by GitHub wrappers. Rejected because (a) every bugfix would
land twice, (b) the `.ag` agents diverge on shape, which undermines
the single-source-of-truth guarantee, and (c) the user has explicitly
scoped the issue: "No thin-slice PoC, no second federation fork. One
federation, one install."

### Runtime-layer forge abstraction in `agentis-core`

Move the forge adapter into `agentis-core` as a first-class concept.
Rejected because it would require a `agentis-core` release and a cross-
repo coordination step every time we extend the shape. The
subcommand-level interface is already where every `.ag` crosses the
forge boundary; promoting it to a runtime concern would ossify it
without removing any duplication. If the adapter ends up stable for
three releases, future work may propose a runtime-level home for it.

### GraphQL-only wrapper (GitHub)

Use GitHub's GraphQL endpoint exclusively; avoid the shape asymmetry
by letting each subcommand ask for exactly the normalized shape.
Rejected because (a) GitHub's GraphQL surface does not cover
`actions/runs` cleanly (pipeline status stays REST), (b) GitLab has no
equivalent GraphQL coverage for the write subcommands (`commit-files`,
`create-release`), so the overall wrapper can't be GraphQL-uniform
anyway, and (c) REST has better debuggability for operators (curl-
ability). The REST-per-backend + normalization approach keeps the
reasoning local.

### Forge-adapter as a runtime plugin loaded by the daemon

Pass a `--forge <name>` flag to `agentis daemon` and have the runtime
load a shared library. Rejected for the same reason as the runtime-
layer option above — premature coupling. The `exec sh` subcommand
abstraction already works; we're not adding a new boundary, just
honouring the one we have.

## References

- GitHub issue: Replikanti/agentis-colonies#256 (motivates this ADR,
  contains the 7-PR breakdown the colony ports follow).
- Replikanti/agentis-colonies#257 — dashboard decoupling, the prior
  restart-path fix that removed the last forge coupling on the
  dashboard side.
- Replikanti/agentis-colonies#223, #224, #225, #226 — env-driven label
  vocabulary and default-branch knob that prepared the ground for this
  ADR.
- `doc/adr/ADR-0001-confidence-tiers.md` — tier contract is already
  forge-agnostic; no changes required.
- `CLAUDE.md` — release-process rules (MAJOR vs MINOR) and federation
  conventions for `.ag` scenarios.

## Supersedes

(none)
