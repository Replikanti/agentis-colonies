---
id: ADR-0002
title: Forge abstraction — normalized wrapper dispatch for multi-forge federations
status: Accepted
date: 2026-04-23
accepted-date: 2026-04-24
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
exports the legacy `GITLAB_*` env names from whichever `[forge.<type>]`
block is active. The migration window collapsed at PR 7 (v1.0.0): the
top-level `[gitlab]` section has been retired and `[forge.*]` is
authoritative. Operators on pre-#256 configs must move their
`url`/`token`/`project`/`me` keys under `[forge.gitlab]` and add
`[forge].type = "gitlab"` — the post-PR-7 start-colony.sh rejects
configs that lack `[forge]`.

#### Non-forge federations (`forge.type = "none"`)

[ADR-0003](./ADR-0003-federation-portability-contract.md) explicitly
allows federations that do not talk to a forge ("a federation that does
not talk to a forge has no obligation to that ADR"). Since #373, the
post-#256 `[forge]`-required contract enforced by `colony-lint`
recognises `[forge].type = "none"` as the explicit non-forge marker:
the `[forge]` block stays present (so the schema check still passes)
but no `[forge.gitlab]` / `[forge.github]` sub-block is required, and
any backend-specific keys are ignored. This ADR remains normative for
every forge-bound colony; non-forge colonies opt out of it
block-and-tackle. `tribes-bench/tribe-alpha` and `tribes-bench/tribe-beta`
are the first consumers.

### Normalized shape contract (normative)

Every subcommand emits a fixed JSON shape. The following table is the
authoritative contract; `test-forge-api.sh` enforces byte-identical
output for matching fixtures across both backends.

**Per-PR rollout.** PR 1 shipped the dispatcher skeleton and config
schema only. PR 2 shipped the triage colony's `github-api.sh` with 7
subcommands (`issues`, `create-issue`, `update-issue`, `members`,
`get-issue`, `labels`, `add-note`) plus the `[forge.github]` env-export
branch in `triage/scripts/start-colony.sh`. PR 3 shipped the planning
colony's `github-api.sh` with 5 subcommands (`issues`,
`issues-by-label-events`, `issue-label-events`, `add-note`,
`merge-requests`) plus the matching `[forge.github]` env-export branch
and `.ag` dispatcher migration. PR 4 ships the implementation colony's `github-api.sh` with 11
subcommands (`merge-requests`, `mr-changes`, `mr-commits`, `issue`,
`assigned-issues`, `issue-label-events`,
`assigned-issues-by-label-events`, `create-branch`, `commit-files`,
`create-mr`, `add-note`) plus the matching `[forge.github]` env-export
branch and 25 `.ag` call-site migrations across the four implementation
agents. PR 5 ships the code-review
colony's `github-api.sh` with 5 subcommands (`merge-requests`,
`mr-changes`, `mr-notes`, `post-note`, `approve`) plus the matching
`[forge.github]` env-export branch and 28 `.ag` call-site migrations
across the five code-review agents. PR 6 ships the release colony's `github-api.sh` with 7 subcommands
(`releases`, `tags`, `pipelines`, `merge-requests`, `create-tag`,
`create-release`, `post-note`) plus the matching `[forge.github]`
env-export branch and 29 `.ag` call-site migrations across the four
release agents. `rate-limit-status` and the dashboard tile ship in PR 7
alongside the legacy `[gitlab]`-section retirement.

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

**PR 3 additions.** The planning contract layers two subcommands on
top of the triage surface: `merge-requests` (maps to GitHub `/pulls`
with `state=open|closed|all`, `--state merged` collapsing to
`closed + merged_at != null` since GitHub has no separate "merged"
state) and `issue-label-events` (maps to GitHub `/issues/{n}/timeline`
filtered to `event in ("labeled", "unlabeled")`, since GitHub has no
dedicated `resource_label_events` endpoint). `issues-by-label-events`
(the composite the planning agents use to catch short-lived trigger
labels) is shared contract for PRs 3-6 — any colony that ingests
label-event-driven triggers uses the same shape. GitHub's `/pulls`
list endpoint omits `changed_files`; the normalizer forwards `null`,
and scope_estimator tolerates it (complexity scoring is best-effort).
GitHub's `/pulls` has no `since` query param, so `--since` is filtered
client-side against `updated_at`.

**PR 4 additions.** The implementation contract adds the write-path
subcommands: `create-branch`, `commit-files`, `create-mr`, plus the
two MR-detail readers `mr-changes` and `mr-commits`. GitHub has no
single-call multi-file commit endpoint (unlike GitLab's
`POST /repository/commits`); `commit-files` implements the 5-step Git
Database API dance — `GET /git/refs/heads/{branch}` to resolve HEAD,
`GET /git/commits/{sha}` to fetch the base tree, `POST /git/trees`
with the per-file action list (supported: `create`/`update`/`delete`;
`move`/`chmod` are rejected up-front with exit 1), `POST /git/commits`
to create the commit object, then `PATCH /git/refs/heads/{branch}` to
advance the ref. Failure at any step surfaces as a normal `gh_call`
non-zero exit and the `.ag` try/catch rolls back. `create-branch`
mirrors `/git/refs` — when `--ref` is a 40-hex SHA we short-circuit
the ref resolution and POST directly; otherwise we resolve via
`/git/refs/heads/{ref}` first. `mr-changes` maps GitHub's
`/pulls/{n}/files` into the GitLab `{"changes": [{old_path, new_path,
diff, new_file, deleted_file, renamed_file}]}` shape; the per-file
`status` drives the three boolean flags, `previous_filename` (when
present) drives `old_path`. `mr-commits` flattens
`commit.author.{name,date}` into the GitLab-flat
`{author_name, created_at}` shape. As in PR 3, GitHub's `/pulls` has
no `since` query param, so `--since` is client-side on `updated_at`
and the list response omits `changed_files` (forwarded as `null`).
`add-note` is the `.ag`-layer call target for implementation agents'
review-gated comment posts; it was silently failing against both
backends before this PR (the implementation `gitlab-api.sh` exposed
only `post-note` targeting MRs), same failure pattern PR 2 fixed for
triage. The back-port of `add-note` into the implementation
`gitlab-api.sh` is in-scope for this PR.

**PR 5 additions.** The code-review contract adds the comment-path
subcommands agents use to leave findings and approve merges:
`mr-notes`, `post-note`, and `approve`. GitHub unifies issue and PR
conversations under `/issues/{n}/comments` — the same endpoint
triage/planning/implementation already hit via `add-note` — so
code-review's `mr-notes` reads from `/issues/{n}/comments` and
`post-note` writes to it. There is no `system` flag on GitHub
comments (GitLab uses it to mark timeline-event notes like
`assigned user`, which the reviewer agents filter out to avoid
echo-chamber loops); the normalizer stamps `system: false` on every
row unconditionally, which is correct because `/issues/{n}/comments`
only surfaces human-authored comments. `approve` maps GitLab's
idempotent `POST /merge_requests/{iid}/approve` to GitHub's
non-idempotent `POST /pulls/{n}/reviews` with
`{"event": "APPROVE"}`; calling it twice creates two APPROVED review
events on GitHub (the approvals collapse from the table above still
holds — `approved = (count of latest-per-reviewer APPROVED reviews
>= required)`, so extra approves from the same reviewer don't break
the count). `normalize_pulls` adds a native `draft` boolean pulled
from GitHub's `draft` field — code-review's `reviewer` view consumes
it to skip draft PRs, which GitHub (unlike GitLab) exposes natively
on the list response. As in PRs 3-4, `--state merged` collapses to
`state=closed + merged_at != null` client-side and `--since` is a
client-side filter on `updated_at`.

**PR 6 additions.** The release contract adds the tag/release/pipeline
read + write surface the four release agents depend on: `releases`,
`tags`, `pipelines`, `create-tag`, `create-release`, plus the shared
`merge-requests` and `post-note` already contracted in PRs 3-5.
`normalize_releases` maps `body` → `description`, `published_at` →
`released_at`, and `author.login` → `author.username`; the `commit`
object is forwarded as `null` because GitHub's `/releases` response
does not carry the tag's target commit inline (changelog_writer reads
it from `tags` instead, which is the only consumer that needs it).
`normalize_tags` forwards `message` and `commit.created_at` as `null`
rather than doing the per-tag `GET /git/refs/tags/{name}` +
`GET /git/tags/{sha}` + `GET /git/commits/{sha}` round-trip — for the
release colony's list reads this would be ~20 extra API calls per
`tags` fetch, and the one consumer (tag-summary view in
release_checker) only needs `name` + `short_id` for prompt context.
`commit.short_id` is derived as `sha[:8]` locally.
`normalize_pipelines` unwraps GitHub's `{total_count, workflow_runs:
[...]}` envelope (also tolerates a bare array for defensive test
input) and collapses the 2-axis `(status, conclusion)` matrix to
GitLab's single-field `status`: `completed + success|skipped|neutral`
→ `success`, `completed + failure|cancelled|timed_out|action_required|
stale` → `failed`, `in_progress` → `running`, `queued|requested|
waiting|pending` → `pending`. `create-tag` implements the 3-step
annotated-tag dance (`GET /git/refs` to resolve the ref, `POST
/git/tags` to create the tag object, `POST /git/refs` to point
`refs/tags/{name}` at the new tag SHA); when no `--message` is
supplied it short-circuits to a single `POST /git/refs` for a
lightweight tag. `create-release` posts to `/releases` with
`{tag_name, name, body}` and normalizes the response through
`normalize_releases` so the calling agent sees the same shape regardless
of backend. `post-note` on the release colony (used by ship_decider
and changelog_writer to post on MRs) goes through
`/issues/{n}/comments`, same as code-review's. PR 6 also back-ports
the `[forge.gitlab]`/`[forge.github]`-aware `default_branch` fix
first called out in PR 4 QA into `release/scripts/start-colony.sh`
(pre-PR 6 the release colony's gitlab arm silently ignored both
`[forge.gitlab].default_branch` and `[forge.github].default_branch`,
falling back to legacy `[gitlab].default_branch` only).

**PR 7 additions (MAJOR, v1.0.0).** The final PR ships the
`rate-limit-status` subcommand across all 10 per-colony wrappers (5
GitLab, 5 GitHub) with a uniform `{"remaining", "limit", "reset_at"}`
contract — GitHub reads `/rate_limit` (uncounted), GitLab reads
`RateLimit-*` response headers from a cheap `/api/v4/version` call.
GitLab behavior under a self-hosted instance without rate-limiting: the
arm forwards `null`s and exits 0 (not-configured is common and
non-fatal). GitHub behavior under transport failure: the arm propagates
the non-zero `gh_call` exit so operators can distinguish "no rate-limit
data" (never happens on github.com) from "PAT missing / API down".
Dashboard consumption of the primitive is deliberately deferred to a
separate `federation-dashboard` release; the rate-limit-status
subcommand is a stable building block regardless of when the tile ships.
The same PR retires the legacy top-level `[gitlab]` config section
federation-wide: all 5 `colony.example.toml` templates, all 5
`start-colony.sh` scripts, and `install.sh`'s credential-writer have
been rewritten to read/write `[forge.<backend>]` only — the MAJOR bump
that gates v1.0.0. Pre-#256 configs with a bare `[gitlab]` block now
fail the `[forge]`-presence guard in `start-colony.sh` with an explicit
retirement message pointing operators at the migration one-liner;
`tools/colony-lint.sh` adds a matching lint rule so a regression
re-introducing `[gitlab]` in any `colony.example.toml` fails CI.
`install.sh` drops the PR-1-to-PR-6 "GitHub scaffolding is partial,
continue anyway?" abort gate and splits credential prompting into
FORGE_TYPE-conditional branches: GitLab selects the existing
url/project/PAT/me flow; GitHub uncomments the `[forge.github]`
template block and writes owner/repo/PAT + optional Enterprise URL +
optional `me` into it.

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
  release of the port.** Retired in PR 7 (v1.0.0, MAJOR); operators
  must migrate to `[forge.gitlab]`.
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
  exports `FORGE_TYPE`. The `GITLAB_*` env-var names are kept as
  backend-agnostic internal exports (populated from whichever
  `[forge.<type>]` block is active); renaming to `FORGE_*` was deferred
  past #256 to avoid a cross-colony churn that doesn't change operator
  semantics.
- `tools/forge-normalize.sh` (new) ships shared helpers: pagination
  walker, label-event filter, draft-flag inferrer, approvals collapse.
- `install.sh` carries a forge-choice prompt defaulting to GitLab
  (preserves Enter-key behavior for pre-#256 re-runs) and conditional
  credential prompting branched on `FORGE_TYPE`. Legacy top-level
  `[gitlab]` is never written (retired in PR 7).
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

`rate-limit-status` subcommand is shipped in PR 7 of #256 (contract:
`{"remaining", "limit", "reset_at"}`) as the building block for an
operator-visible counter. A dashboard tile is deliberately deferred to
a separate `federation-dashboard` release so a UI churn does not gate
v1.0.0 of the federation. If a real install trips the limit, the fix
is per-agent tick-interval tuning, not a change to this ADR.

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
