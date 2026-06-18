# Dev Apprenticeship

![Version: 2.0.0](https://img.shields.io/badge/version-2.0.0-blue) ![Agentis >= v1.4.7](https://img.shields.io/badge/agentis-%3E%3D%20v1.4.7-blue) ![Agents: 21](https://img.shields.io/badge/agents-21-green) ![Status: Beta](https://img.shields.io/badge/status-beta-yellow)

**Version:** `2.0.0` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.4.7`

> **One example federation** built on the [`agentis-colonies`](../) platform. The platform contract every federation must satisfy is [ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md); to scaffold a different kind of federation (data-ops, research, support-triage, monitoring-ops, …) see [`doc/federation-patterns.md`](../doc/federation-patterns.md) and [`tools/new-federation.sh`](../tools/new-federation.sh).

A federation of 21 agents that learns how you work by watching your GitLab or GitHub activity. It observes how you triage issues, review merge requests, plan features, write code, and ship releases. Over time it takes over the mechanical parts, while you keep control over the decisions that matter.

The federation starts silent. Agents only watch. As you see what they are learning in the logs and trust what they would do, you progressively unlock autonomy by raising each agent's confidence memo through four named tiers — `shadow` (observe), `propose` (suggest), `review-gated` (act under review), and `autonomous` (act alone). The tier contract is defined in [`doc/adr/ADR-0001-confidence-tiers.md`](../doc/adr/ADR-0001-confidence-tiers.md) and is normative for every agent in this federation. Agents do not promote themselves; the gradient is operator-controlled. You can always veto or demote.

As knowledge accumulates, agents rely more on stored patterns and less on LLM inference. Early ticks are LLM-heavy (learning your style, generating summaries). Mature agents resolve most decisions from knowledge recall alone, falling back to the LLM only for novel situations.

```mermaid
graph LR
    GL["Your GitLab Project"]
    FED["Dev Apprenticeship Federation"]
    TR["Triage"]
    CR["Code Review"]
    PL["Planning"]
    IM["Implementation"]
    RE["Release"]

    GL <--> FED
    FED --- TR
    FED --- CR
    FED --- PL
    FED --- IM
    FED --- RE

    style FED fill:#2d333b,stroke:#539bf5,color:#adbac7
    style TR fill:#1a1e24,stroke:#57ab5a,color:#adbac7
    style CR fill:#1a1e24,stroke:#57ab5a,color:#adbac7
    style PL fill:#1a1e24,stroke:#57ab5a,color:#adbac7
    style IM fill:#1a1e24,stroke:#57ab5a,color:#adbac7
    style RE fill:#1a1e24,stroke:#57ab5a,color:#adbac7
```

## Contents

- [What you need](#what-you-need)
- [Installation](#installation)
- [Starting and stopping](#starting-and-stopping)
- [Monitoring](#monitoring)
- [How work enters the system](#how-work-enters-the-system)
- [Confidence tiers](#confidence-tiers)
- [Security](#security)
- [What to expect](#what-to-expect)
- [Auto-confidence from feedback](#auto-confidence-from-feedback-106)
- [Colonies](#colonies)
- [Knowledge portability](#knowledge-portability)
- [Troubleshooting](#troubleshooting)
- [Extension points](#extension-points)
- [Auto-promote and auto-evolve](#auto-promote-and-auto-evolve-148)

## What you need

- [Agentis](https://github.com/Replikanti/agentis) runtime **>= v1.4.7** (v1.4.0 provides the `tier()` builtin required by the four-tier confidence gating in all 21 agents; v1.4.1 wires `fitness_delta` from the `outcome` argument to `learn()` so downstream consumers — auto-promote, evolve, dashboard — see non-zero deltas; v1.4.7 is the floor pinned by the [2.0.0] CHANGELOG entry)
- An LLM backend (Claude CLI, Ollama, or any OpenAI-compatible API)
- GitLab instance with API access (personal access token with `api` scope)
- Python 3 and git

## Installation

Pick one of the two install paths.

**Option A — release tarball** (recommended for running the federation; install-ready, no git tree required):

```bash
VERSION=2.0.0
curl -LO https://github.com/Replikanti/agentis-colonies/releases/download/dev-apprenticeship-v${VERSION}/dev-apprenticeship-v${VERSION}.tar.gz
curl -LO https://github.com/Replikanti/agentis-colonies/releases/download/dev-apprenticeship-v${VERSION}/dev-apprenticeship-v${VERSION}.tar.gz.sha256
sha256sum -c dev-apprenticeship-v${VERSION}.tar.gz.sha256   # optional but recommended
tar xzf dev-apprenticeship-v${VERSION}.tar.gz
cd dev-apprenticeship-v${VERSION}/dev-apprenticeship
./install.sh
```

The tarball ships only the runtime surface of this federation (the federation itself plus the `tools/` scripts and `doc/` references it needs at run time). Contributor tooling (`colony-lint.sh`, tests, CI config, `CLAUDE.md`) is intentionally excluded — see [`BUNDLE.manifest`](./BUNDLE.manifest).

**Option B — clone the repo** (use this if you want to contribute or work from `main`):

```bash
git clone https://github.com/Replikanti/agentis-colonies.git
cd agentis-colonies/dev-apprenticeship
./install.sh
```

The install script checks prerequisites, creates configs for all 5 colonies, writes your GitLab credentials, and seeds agent confidence levels. Running it again is safe. See [Security](#security) for how tokens are stored and rotated.

## Starting and stopping

```bash
./start-federation.sh           # Start all 5 colonies (21 agents)
./kill-federation.sh            # Stop everything reliably (preferred)
agentis daemon stop --all       # Fallback only — known false-positive / false-negative on stale registry entries (see top-level README)
```

> Agents must be launched via `start-federation.sh` or a colony's
> `start-colony.sh`. Those scripts export `COLONY_DIR`, which the
> agents expand inside `exec sh "$COLONY_DIR/scripts/..."` at runtime.
> Launching `agentis daemon <agent>.ag` directly bypasses that export,
> so `$COLONY_DIR` expands to empty and GitLab polling fails silently.

## Monitoring

### Dashboard

A web dashboard that shows agent health, confidence levels, phase readiness with ETA, knowledge growth trends, remediation history, and a live suggestion feed. Auto-refreshes every 60 seconds. Includes a kill switch (two-click safety) to stop the entire federation from the browser.

The dashboard is a [separately-versioned standalone component](../federation-dashboard/) ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)). This federation recommends `federation-dashboard >= 0.8.0` (pinned in [`.dashboard-version`](./.dashboard-version)); `install.sh` step 8 offers to install it for you, and `./dashboard.sh` is a thin resolver that finds the installed binary.

Per-agent **confidence bump** controls (▲▼) in the Confidence Levels card walk each agent through the canonical tier ladder: `shadow` (0.4) → `propose` (0.6) → `review-gated` (0.8) → `autonomous` (0.95). Promotions to `autonomous` trigger a confirmation dialog since at that level the agent performs terminal external writes (merge, tag, publish) without a second gate. Every change is appended to `.dashboard/confidence-log.jsonl` for audit. The CLI path (`agentis memo set <agent>:confidence <value>`) still works and is equivalent.

```bash
./dashboard.sh                  # http://localhost:8420
./dashboard.sh 9000             # custom port
```

The dashboard auto-discovers colonies and agents from the directory structure. It persists history in `.dashboard/history.json` so trends survive restarts.

### Right after start

Verify everything is alive:

```bash
agentis daemon list             # 21 processes, all STATE=running?
agentis federation status       # 5 colonies connected?
tail .agentis/logs/router.log   # See "[router] GitLab poll..." lines?
```

### First day

Verify agents are learning:

```bash
agentis knowledge stats         # Knowledge entries growing?
agentis memo get router:confidence  # Confidence at 0.4 (shadow seed)?
agentis stats                   # CB consumption per agent
```

### Ongoing

Check daily or when something feels off:

```bash
agentis daemon list             # Check HEALTH and QUARANTINE columns
agentis colony health           # Health per colony
agentis colony ps               # Agent lifecycle states
agentis remediation history     # Any auto-remediation actions?
```

### Warning signs

| Signal | Meaning | Action |
|--------|---------|--------|
| STATE=stopped in daemon list | Agent crashed, watchdog gave up | Check log, restart the colony |
| QUARANTINE=yes | Agent failed repeatedly, runtime isolated it | `agentis quarantine status <agent>`, fix cause, `agentis quarantine promote <agent>` |
| knowledge stats shows 0 after a day | Agents see no GitLab activity | Check token, project path, verify project has recent activity |
| One log growing much faster than others | Agent hitting errors repeatedly | `tail .agentis/logs/<agent>.log` |
| remediation history shows entries | System detected an anomaly and responded | `agentis remediation history --json` for details |

## How work enters the system

Agents pick up work from three sources:

1. **GitLab polling**: Every 60 seconds, agents poll for new issues, merge requests, pipeline results, and review activity. This is the primary input. If something changes on GitLab, the relevant colony reacts on the next tick.

2. **Colony bus events**: Colonies pass work to each other over the federation bus. When triage routes an issue, the implementation colony picks it up. When implementation opens an MR, the code-review and release colonies react. You do not need to trigger these handoffs manually.

3. **Operator commands**: You can intervene directly via the agentis CLI. Adjust confidence (`agentis memo set labeler:confidence 0.95`), inspect knowledge (`agentis knowledge list`), or stop individual agents. The CLI is your control plane.

```mermaid
graph LR
    GL["GitLab Activity"]
    BUS["Colony Bus"]
    CLI["Operator CLI"]
    FED["Federation"]

    GL -- "poll every 60s" --> FED
    BUS -- "cross-colony events" --> FED
    CLI -- "confidence, knowledge, stop" --> FED

    style FED fill:#2d333b,stroke:#539bf5,color:#adbac7
```

## Confidence tiers

What agents do depends on their current tier. See [`doc/adr/ADR-0001-confidence-tiers.md`](../doc/adr/ADR-0001-confidence-tiers.md) for the normative contract.

```mermaid
graph TD
    CHECK["Check tier()"]
    SHA["shadow: LLM + memo only, no emit, no external write"]
    PRO["propose: + emit on bus + draft external writes"]
    RG["review-gated: + direct external writes (non-terminal)"]
    AUT["autonomous: + terminal writes (merge, tag, publish)"]

    CHECK -- "[0.4, 0.6)" --> SHA
    CHECK -- "[0.6, 0.8)" --> PRO
    CHECK -- "[0.8, 0.95)" --> RG
    CHECK -- "[0.95, 1.0]" --> AUT

    style SHA fill:#1a1e24,stroke:#636e7b,color:#adbac7
    style PRO fill:#1a1e24,stroke:#c69026,color:#adbac7
    style RG fill:#1a1e24,stroke:#ff8800,color:#adbac7
    style AUT fill:#1a1e24,stroke:#57ab5a,color:#adbac7
```

Agents below `0.4` are `dormant` — not yet admitted to the ladder. Fresh federations seed every agent at `0.4` (shadow).

**Start at 0.4 (shadow)**. Agents watch your GitLab activity and build knowledge. Check logs to see what they are learning: `tail -f .agentis/logs/labeler.log`

**Promote to 0.6 (propose)** when you trust what they have learned. Agents emit suggestions to the colony bus and draft external writes marked as non-authoritative. They do not post directly on your behalf. Watch all suggestions in one stream:

```bash
agentis memo set labeler:confidence 0.6
./watch-suggestions.sh          # Live feed from all 21 agent logs
```

**Promote to 0.8 (review-gated)** when proposals have been reliable. Agents now post directly on GitLab (non-terminal writes: comments, non-draft MRs). Terminal actions (merge, tag, publish, credential rotation) still require an explicit second gate.

```bash
agentis memo set labeler:confidence 0.8
```

**Promote to 0.95 (autonomous)** when the agent has demonstrated sustained success under the review gate. At this tier the agent may perform terminal writes without a second approver. Start with low-risk agents (labeler, style_reviewer) before promoting high-impact ones (code_writer, approval_decider).

```bash
agentis memo set labeler:confidence 0.95
```

| Colony | Autonomous actions |
|--------|--------------------|
| Triage | Creates issues, applies labels, sets priority, assigns people |
| Code Review | Posts review comments, approves MRs, requests changes |
| Planning | Posts scope/risk/breakdown plans as issue comments |
| Implementation | Creates branches, commits code and tests, opens MRs |
| Release | Runs pre-release checks, posts ship decisions, creates tags and releases |

You can always demote an agent back: `agentis memo set labeler:confidence 0.4`

## Security

Your GitLab personal access token is stored in plaintext in 5 files:

```
<colony>/config/colony.toml     # token = "glpat-..."
```

`install.sh` sets these to mode 0600 (owner-only). If you move a federation directory to a multi-user system or copy configs manually, re-run `chmod 600 <colony>/config/colony.toml` on each.

Rotate tokens periodically via GitLab (User Settings -> Access Tokens). Re-run `./install.sh` and answer `Y` to the "Update GitLab credentials" prompt — it accepts a new token without rewriting the colony templates.

### Migrating to vault-stored tokens (#321)

If you don't want a plaintext token on disk, the federation now understands `secret://` URIs in any `[forge.*]` `token` / `api_key` field. The token lives in your OS vault; `colony.toml` just carries a pointer.

Three backends are supported:

| Backend | URI shape | When |
|---------|-----------|------|
| `libsecret` (Linux GNOME-Keyring) | `secret://libsecret/<service>/<key>` | Linux desktop |
| `keychain` (macOS) | `secret://keychain/<service>/<account>` | macOS |
| `pass` (passwordstore.org) | `secret://pass/<path>` | cross-platform |
| `env` (existing `${VAR}` idiom) | `secret://env/<VAR>` | unattended / CI |

The `tools/secret-set.sh` helper auto-detects the backend, reads the token from stdin (no echo), writes it via the matching command, and prints the resulting URI on stdout:

```bash
# libsecret (Linux)
echo "glpat-yourtoken" | tools/secret-set.sh --service agentis-colonies --account gitlab-token
# → secret://libsecret/agentis-colonies/gitlab-token

# keychain (macOS) — same invocation, autodetected
echo "ghp_yourtoken" | tools/secret-set.sh --service agentis-colonies --account github-token
# → secret://keychain/agentis-colonies/github-token

# pass (cross-platform)
echo "glpat-yourtoken" | tools/secret-set.sh --backend pass --service agentis-colonies --account gitlab-token
# → secret://pass/agentis-colonies/gitlab-token
```

Paste the printed URI into each `colony.toml` in place of the plaintext token. `install.sh` will offer to do this for you on a fresh install — answer `y` when it asks "Store this token in your OS vault?".

The plaintext path keeps working — vault use is opt-in. `tools/colony-lint.sh` warns when it spots a plaintext forge token; set `COLONY_LINT_STRICT_SECRETS=1` to upgrade the warning to a hard fail in CI.

## LLM backend (per-colony override, [#319](https://github.com/Replikanti/agentis-colonies/issues/319))

Every agent reads its LLM backend from `<fed>/.agentis/config` by default — that is the federation-wide pin written by `install.sh` step 4 (one of `cli` / `http` / `mock`). A colony can pin its own backend via an optional `[llm]` block in `<colony>/config/colony.toml`:

```toml
[llm]
backend = "http"               # mock | cli | http
# command = "claude"           # for cli backend
# model = "claude-sonnet-4"    # for http backend
# api_key_env = "ANTHROPIC_API_KEY"  # for http backend
```

All four keys are optional. Each set key is spliced onto every `agentis daemon` invocation as `--config-override llm.<key>=<value>`; absent keys fall through to the federation-wide default. Use this to put a low-stakes colony (e.g. `triage`) on a cheap local Ollama / OpenAI endpoint while reserving Claude for `release` / `code-review`. Edits take effect on the next colony restart (`./scripts/start-colony.sh` or the dashboard's per-agent ▶ Restart button).

The cost-cap downgrade primitive ([#318](https://github.com/Replikanti/agentis-colonies/issues/318)) takes precedence over the colony block: when the sidecar trips a daily/monthly budget breach with `on_breach = "downgrade"`, every running daemon is restarted onto `--config-override llm.backend=mock` until UTC midnight or the operator runs `tools/cost-cap.sh <fed> --override "<reason>"`. While the override file is in place, the colony's `[llm]` block is ignored entirely (downgrade snaps to mock cleanly without leaking colony-specific keys onto the daemon CLI).

This is PR 1 of a 5-PR rollout. Per-agent backend selection (e.g. `@llm("ollama")` decorators) is explicitly deferred — split the agent into its own colony if heterogeneity is real. Subsequent PRs land the portable pricing registry (`tools/llm-pricing.toml` for `cost-cap-sum.py` in metered mode), the swap-without-restart primitive (generalising the override file into a TOML doc with `model` / `endpoint` keys), the `install.sh` interactive backend prompt, and the dashboard's `cost_source` chip + per-colony backend column.

## What to expect

**Day 1**: Nothing visible. Agents are silent in `shadow` (seeded at 0.4). Check `agentis daemon list` and logs to confirm they are polling.

**Week 1-2**: Knowledge entries accumulate from your GitLab activity. Run `agentis knowledge list` to inspect.

**After promotion**: Proposals appear in logs at `propose` (0.6), direct non-terminal writes on GitLab at `review-gated` (0.8), and terminal writes (merge/tag/publish) at `autonomous` (0.95). Knowledge keeps growing with every tick.

Separately from the tier ladder, the runtime slowly decays the per-entry confidence score that `learn()` attaches to each unvalidated knowledge row — `knowledge.confidence_decay_rate` defaults to `0.01/hr`, floored at `knowledge.confidence_decay_min` (`0.05`); validated entries are left alone. This affects how much weight an old entry carries inside an agent, not which tier the agent is running at.

## Auto-confidence from feedback (#106)

Suggestions don't just sit in logs — participating agents score themselves against what you actually did. The loop is:

1. Agent emits a proposal in `propose` tier (confidence 0.6–0.8) and stashes a "pending verdict" — issue/MR id plus the payload it proposed.
2. On a later tick, agent fetches the current GitLab state of the artifact and compares.
3. Exact match → confidence `+0.02`. Partial match → `+0.005`. Mismatch → `-0.01`. Still no operator action → leave pending, re-check next tick.
4. Verdicts that age past 24 h without operator action are dropped without scoring — absence is not evidence of wrong suggestion.

**Autonomy cap**. Auto-promotion stops at **0.85** (within `review-gated`). Positive deltas above the cap are clipped; the agent has to earn *review-gated trust* automatically, but you still have to manually bump it across the `autonomous` boundary at 0.95 (via the dashboard ▲ button or `agentis memo set <agent>:confidence 0.95`) before it is permitted to perform terminal writes (merge, tag, publish). This is deliberate — the auto-loop earns propose/review-gated trust from matching your style; terminal autonomy is your call. Negative deltas are not capped, so a confident agent that goes off the rails can still be pulled back down.

**Phase 1 scope** (what ships today). The feedback loop is wired into the `labeler` agent as the reference implementation — suggested labels are compared against the labels you actually apply to the issue (set overlap).

Four more reference agents will follow in separate PRs using the same pattern:

- `style_reviewer`
- `plan_reviewer`
- `code_writer`
- `version_bumper`

Each needs its own matcher (did the MR get merged? was the plan followed? was the version tagged?). Shared infrastructure (`clamp_auto`, `signal_to_delta`, `apply_feedback`, `record_*_verdict`, `evaluate_*_verdict`, `get-issue` gitlab-api subcommand) is in place.

**Config knobs** live in each colony's `config/colony.toml` under `[feedback]`. The current shipment reads the defaults directly from the agent source (`match_rate = 0.02`, `partial_rate = 0.005`, `mismatch_rate = 0.01`, `timeout_s = 86400`, `autonomy_cap = 0.85`). The TOML section is declared so you can see where runtime-configurable knobs will land without a future config rewrite being disruptive.

**Observability**. Every delta prints one line to the agent's log: `[labeler] feedback delta 0.02 confidence 0.62 -> 0.64`. Grep that prefix to audit every confidence change the agent made to itself. The dashboard's per-agent confidence bar reflects the current memo value regardless of how it moved.

**Why not auto-promote into `autonomous`**. The cap makes the honest claim match the observed behavior: *agents learn to propose and act-under-review well*. Promoting them into terminal-write territory ought to be an explicit operator decision, not a drift that happened while you weren't looking.

## Colonies

| Colony | Agents | What it learns |
|--------|--------|---------------|
| [Triage](./triage/) | 4 | Issue creation, labeling, prioritization, routing |
| [Code Review](./code-review/) | 5 | Style, logic, security, test coverage review, approval decisions |
| [Planning](./planning/) | 4 | Scope estimation, risk assessment, task decomposition, plan review |
| [Implementation](./implementation/) | 4 | Code generation, test writing, refactoring, commit conventions |
| [Release](./release/) | 4 | Pre-release checks, ship decisions, changelogs, versioning |

Cross-colony wiring: Triage routes issues to Implementation. Implementation signals Code Review and Release when an MR is ready. See individual colony READMEs for internal event wiring.

## Shared GitLab snapshot (#1111 / #1112)

Without sharing, every agent in a colony curls the same GitLab collection on every tick and passes the raw JSON straight into `prompt()`. In the Triage colony that meant the `/issues` (now `/work_items`) endpoint was fetched **three times per tick** — once each by the labeler, router, and prioritizer (four with the issue_creator) — and each copy was the full ~74 KB raw payload. The duplicate fetches throttle the API; the raw payloads waste a factor 5–10× of the model's input budget.

Two mechanisms fix this:

**One shared fetch per colony per tick (#1111).** The Triage `scripts/start-colony.sh` publishes a single snapshot of the `issues` collection:

- It fetches the collection **once** via `scripts/forge-api.sh snapshot issues` (the single fetch implementation — `gitlab-api.sh` / `github-api.sh` stay the only code that touches the network) and writes the result to the shared memo `gitlab:snapshot:issues`, with an epoch-seconds freshness key at `gitlab:snapshot:issues:ts`.
- The publish runs on full-colony bootstrap, and can be re-run any time via `scripts/start-colony.sh --snapshot-refresh` (a lightweight, daemon-free mode for a per-tick sidecar).
- Each agent reads `recall_latest("gitlab:snapshot:issues")` instead of curling the endpoint. The agent renders its role view from the snapshot via `forge-api.sh issues --from-snapshot --view <role>`, which rehydrates + projects the memo with **zero HTTP calls**.

**Compressed before it reaches `prompt()` (#1112).** The snapshot is not stored raw. `scripts/snapshot-compress.py` (reusing the normalized-subtree-hashing idea from `dark-factory/evm-harness/struct-sig.js`) transforms the raw GitLab JSON into a compact, deduplicated, structurally-chunked envelope before it lands in the memo:

- Each item is normalized to the union of role-relevant fields (everything else — `web_url`, `time_stats`, `references`, `milestone`, … — is dropped).
- Each item's normalized **structure** is content-addressed (SHA-256 of its canonical JSON); identical structures are interned once in a `chunks` table and referenced by index, so repeated structure (and unchanged structure across ticks) is stored once, not re-serialized.
- The transform is deterministic and **byte-stable** for identical input (the key that makes cross-tick caching sound). On a realistic 20-issue payload this is ~11× smaller than the raw JSON.

**Backward-safe degrade.** Every read path is total-on-failure: if the snapshot memo is missing, empty, malformed, or older than the freshness window (600 s), the agent silently falls back to its legacy direct `forge-api.sh issues` fetch. A broken or stale snapshot never hard-fails a tick. The per-colony snapshot is used only on the single-repo path; the multi-repo (`[[forge.github]]`) fan-out keeps its per-repo direct fetch.

| Memo key | Writer | Readers |
|----------|--------|---------|
| `gitlab:snapshot:issues` | `triage/scripts/start-colony.sh` (snapshot step) | labeler, router, prioritizer, issue_creator |
| `gitlab:snapshot:issues:ts` | `triage/scripts/start-colony.sh` (snapshot step) | the four agents' `snapshot_fresh()` gate |

> The same mechanism extends to the `merge_requests` collection in the Planning / Implementation / Code Review / Release colonies; their reads are label-event-filtered rather than plain full-collection fetches, so that wiring is driven by the live run (#1117) and is not enabled yet.

## Knowledge portability

Every `learn()` call in the federation's agents tags entries with one of `observed` (shadow tier: passive learning from GitLab activity), `emitted` (propose tier: suggestion logged with draft external write), `review-gated` (review-gated tier: direct non-terminal external write under the review gate), or `acted` (autonomous tier: terminal external write with no second gate) plus the colony name (`triage`, `code-review`, `planning`, `implementation`, `release`). See [`doc/auto-promote.md#classification`](../doc/auto-promote.md#classification) for how the auto-promote heuristic consumes these tags.

**Personal vs team (`#104`).** If you set your forge username during `./install.sh` (or in `colony.toml` under `[forge.gitlab] me = "..."` / `[forge.github] me = "..."`), three agents additionally tag their `learn()` calls as either `personal` (the issue/MR author matches your username) or `team` (anyone else):

- `labeler` — tags every tier's entries
- `prioritizer` — tags every tier's entries
- `style_reviewer` — tags only its direct-write (`review-gated` and `acted`) branches

The remaining agents still tag only the tier name + colony; widening coverage is tracked as future work. If you leave the username empty, every entry keeps the legacy `team` tag so exports stay stable.

Bulk export/import is available at the runtime level and will carry all entries as-is:

```bash
agentis knowledge export > fed-knowledge.json
agentis knowledge export --tags personal > my-preferences.json  # carry just your style
agentis knowledge import fed-knowledge.json --merge
```

Filtering by `--tags observed`, `--tags emitted`, `--tags review-gated`, `--tags acted`, `--tags <colony>`, `--tags personal`, or `--tags team` works once the matching agents have acted at least once with the relevant author context.

### Bootstrap from another federation (#323)

A fresh federation starts every agent at `confidence = 0.4` with zero rows in its experience store, so the first auto-promote step (`min_entries: 200`) is unreachable for weeks. To shorten that ramp, you can transfer experience and (optionally) knowledge from a healthy federation.

**Experience track.** `tools/experience-transfer.sh` packs each agent's `.agentis/experience/<agent_id>.jsonl` keyed by agent **name** (since `agent_id = sha8(...)` is never stable across federations) and re-imports into the recipient by remapping name to the recipient's current `agent_id`:

```bash
# Donor: pack experience tagged for the autonomous tier, last 30 days, scrubbed.
./tools/experience-transfer.sh export dev-apprenticeship \
    --out /tmp/devapp-pack.tar.gz \
    --since 2026-03-26 \
    --tags acted,emitted \
    --max-rows-per-agent 500 \
    --scrub

# Recipient (new federation, same colony layout): import the pack.
./tools/experience-transfer.sh import my-fresh-fed /tmp/devapp-pack.tar.gz
```

Imported rows are stamped with `donor=<src-fed-name>` so the auto-promote sidecar can later distinguish imported rows from native ones. Re-imports of the same pack are idempotent (rows are deduped by sha256). Agents present in the pack but missing on the recipient are reported on stderr and skipped — only same-shape colony decompositions transfer cleanly.

**`--scrub` strips:** `row.in` (free-text input excerpts), nested `row.signal.in_summary` / `row.signal.title`, and any tag matching `forge_user=*` or `assignee=*`. Default is **off** — review what you're shipping outside your org before flipping it on.

**Confidence is intentionally NOT transferred.** The recipient keeps its install-time defaults (every agent at `0.4`). Imported experience rows count toward `min_entries` / `min_acting_entries`, so the first auto-promote tick on the recipient fires fast on real local activity instead of artificially lifting confidence to a level the agent has not earned in its own environment.

**Knowledge track.** Knowledge transfer reuses the existing upstream CLI verbatim — no new tool needed:

```bash
# Donor:
agentis knowledge export --tags personal > /tmp/donor-knowledge.json

# Recipient:
agentis knowledge import /tmp/donor-knowledge.json --merge
```

## Troubleshooting

**Agents are silent after starting**: Expected in `shadow` tier (seed 0.4). Check `agentis daemon list`. If running, check logs: `tail -f .agentis/logs/router.log`.

**"GitLab poll failed"**: Token lacks `api` scope, or the project path is wrong.

**Issue reads/writes 404 on a self-hosted GitLab**: GitLab renamed the issue-tracking REST collection from `/issues` to the unified `/work_items` collection ([#1119](https://github.com/Replikanti/agentis-colonies/issues/1119)). The colony `gitlab-api.sh` helpers default to `work_items`. If your instance has **not** migrated yet, set `GITLAB_ISSUE_COLLECTION=issues` in the environment that launches the federation to pin the legacy path — no code change required. The default (`work_items`) is correct for migrated instances. This knob, like `GITLAB_CURL_MAX_TIME` / `GITLAB_CURL_RETRIES`, is read from the operator environment by each colony's `gitlab-api.sh` and is not seeded from `colony.toml`.

**"Config not found"**: Run `./install.sh` or copy the template: `cp config/colony.example.toml config/colony.toml`

**LLM errors**: Check your backend configuration in `.agentis/config`. For CLI backends, verify the command works in your terminal. For HTTP backends, verify the endpoint is reachable and the API key is set.

**Agents not learning**: Run `agentis knowledge list`. If empty after several ticks, verify the GitLab project has recent activity.

**Log growth**: Logs go to `.agentis/logs/<agent>.log` with no built-in rotation. Volume is low (a few lines per tick per agent), but with 21 agents running continuously and occasional error loops (e.g. a bad GitLab token causing one log line per retry × 6 retries × per tick) individual logs can reach tens of megabytes per day. A sample logrotate config lives at `ops/logrotate.conf` — copy it into `/etc/logrotate.d/` (requires sudo) and adjust the path to your federation root, or adapt it for a user-level cron if you prefer not to touch system logrotate.

As a zero-config fallback, `start-federation.sh` can be asked to truncate logs on start by setting `TRUNCATE_LOGS=1` in the environment. This keeps disk usage bounded between manual restarts but loses history — use logrotate for long-running federations.

## Extension points

Terminal colony bus events with no internal listener, meant for external consumption (webhooks, dashboards, custom agents):

| Event | Emitter | When |
|-------|---------|------|
| `triage:label_suggestion` | labeler | `propose` tier: label suggestion for human review |
| `triage:priority_suggestion` | prioritizer | `propose` tier: priority suggestion for human review |
| `review:decision_suggestion` | approval_decider | `propose` tier: approve/reject suggestion |
| `review:escalation` | approval_decider | `review-gated` / `autonomous`: MR requires human attention |
| `planning:draft_plan` | plan_reviewer | `propose` tier: assembled plan for human review |
| `release:version_bumped` | version_bumper | After tag/release creation or version bump suggestion |

## Auto-promote and auto-evolve (#148)

A scheduler-driven script (`tools/auto-promote.sh`) that evaluates per-agent fitness from experience data and decides when to promote (raise confidence) or evolve (mutate `.ag` source). Reads state via `agentis daemon list --json` and experience JSONL files.

### Quick start

Scheduling is installed by `./install.sh` — answer **Y** (the default) when it asks:

```
Enable auto-promote scheduling? [Y/n]:
```

The decision is persisted in `dev-apprenticeship/.auto-promote-install.toml`. `start-federation.sh` reads it on startup and spawns a sidecar that invokes `tools/auto-promote.sh` every 30 minutes while the federation is up. The sidecar dies when the federation is torn down (`kill-federation.sh`, Ctrl-C), so no scheduling state lingers system-wide.

> **Shutdown drift:** after `kill-federation.sh` sweeps the daemons in a second terminal, the sidecar exits on its next poll, so the foreground `start-federation.sh` terminal may take up to `interval_s` seconds (default 30 min) to return. Ctrl-C in the foreground terminal reaps the sidecar instantly via the `EXIT` trap.

To change your mind, re-run `./install.sh` and answer the prompt again.

Log: `.agentis/logs/auto-promote.log`. Manual runs are still possible:

```bash
# Dry-run (default) — log what would happen, take no action:
./tools/auto-promote.sh dev-apprenticeship

# Live mode — actually promote/evolve:
./tools/auto-promote.sh dev-apprenticeship --live
```

Configuration lives in `tools/auto-promote-config.yaml` (rules and `dry_run`). Decisions are journaled to `tools/auto-promote-journal.jsonl` (append-only, one JSON line per decision).

### Decision rules

**Promote** (confidence step-up along the three-step ladder `0.4 → 0.6 → 0.8 → 0.95`, i.e. `shadow → propose → review-gated → autonomous`):
- Minimum 200 experience entries
- At least 48 hours of runtime
- Reject rate below 5%
- Delta slope non-negative over last 100 entries

**Evolve** (`.ag` source mutation via `agentis evolve`):
- Negative delta slope sustained over 1000 entries, OR
- Reject rate above 20%

### Safety guards

1. **Federation check**: exits cleanly when `agentis daemon list --json` returns empty
2. **Lock file**: `tools/.auto-promote.lock` prevents overlapping scheduler runs
3. **Confidence seeded**: skips agents where `recall_latest` returns null
4. **PID liveness**: `kill -0` check before acting on a daemon
5. **Dry-run default**: all actions are logged but not executed until you flip `dry_run: false` in the config

### Roadmap: 3 layers of self-governance

| Layer | Where | Status |
|-------|-------|--------|
| **1 — External scheduler** | `tools/auto-promote.sh` + `start-federation.sh` sidecar (#216) | Shipped (#148) |
| **2 — Supervisor agent** | `meta/agents/conductor.ag` | Planned (separate ticket) |
| **3 — Daemon self-decide** | agentis-core | Long-horizon (needs months of L1+L2 data) |

**Layer 1** (this) runs as a dumb scheduler tick. It cannot observe the federation in real time — it snapshots state once per invocation, evaluates rules, and exits. Good enough for 30-minute decision cadence.

**Layer 2** lifts the same logic into a native `.ag` agent (`conductor.ag`) running inside a new `meta` colony. The supervisor ticks every 5 minutes, reads other agents' state via the agentis API, and emits structured `promote`/`evolve` events. The federation learns how to manage itself — and you can evolve the supervisor too. Requires agentis-core support for cross-agent state reads (currently sandboxed).

**Layer 3** gives each daemon a self-governance loop: track own metrics, decide when to self-promote, write memo, signal restart. Most invasive design with open questions about uncontrolled escalation. Out of scope until layers 1+2 have run for months and we have data on whether self-promote is desirable.
