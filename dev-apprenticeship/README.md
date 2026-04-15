# Dev Apprenticeship

![Agentis >= v1.2.3](https://img.shields.io/badge/agentis-%3E%3D%20v1.2.3-blue) ![Agents: 21](https://img.shields.io/badge/agents-21-green) ![Status: Beta](https://img.shields.io/badge/status-beta-yellow)

A federation of 21 agents that learns how you work by watching your GitLab activity. It observes how you triage issues, review merge requests, plan features, write code, and ship releases. Over time it takes over the mechanical parts, while you keep control over the decisions that matter.

The federation starts silent. Agents only watch. As you see what they are learning in the logs and trust what they would do, you progressively unlock autonomy by raising each agent's confidence memo — first suggestions (≥ 0.6), then full automation (≥ 0.85). Agents do not promote themselves; the gradient is operator-controlled. You can always veto or demote.

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

## What you need

- [Agentis](https://github.com/Replikanti/agentis) runtime **>= v1.2.3**
- An LLM backend (Claude CLI, Ollama, or any OpenAI-compatible API)
- GitLab instance with API access (personal access token with `api` scope)
- Python 3 and git

## Installation

```bash
git clone https://github.com/Replikanti/agentis-colonies.git
cd agentis-colonies/dev-apprenticeship
./install.sh
```

The install script checks prerequisites, creates configs for all 5 colonies, writes your GitLab credentials, and seeds agent confidence levels. Running it again is safe.

## Starting and stopping

```bash
./start-federation.sh           # Start all 5 colonies (21 agents)
agentis daemon stop --all       # Stop everything
```

> Agents must be launched via `start-federation.sh` or a colony's
> `start-colony.sh`. Those scripts export `COLONY_DIR`, which the
> agents expand inside `exec sh "$COLONY_DIR/scripts/..."` at runtime.
> Launching `agentis daemon <agent>.ag` directly bypasses that export,
> so `$COLONY_DIR` expands to empty and GitLab polling fails silently.

## Monitoring

### Dashboard

A web dashboard that shows agent health, confidence levels, phase readiness with ETA, knowledge growth trends, remediation history, and a live suggestion feed. Auto-refreshes every 60 seconds. Includes a kill switch (two-click safety) to stop the entire federation from the browser.

Per-agent **confidence bump** controls (▲▼) in the Confidence Levels card walk each agent through the canonical steps 0.5 → 0.6 → 0.85. Promotions to 0.85 (AUTONOMOUS) trigger a confirmation dialog since at that level the agent begins writing to GitLab directly. Every change is appended to `.dashboard/confidence-log.jsonl` for audit. The CLI path (`agentis memo set <agent>:confidence <value>`) still works and is equivalent.

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
agentis memo get router:confidence  # Confidence at 0.5?
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

3. **Operator commands**: You can intervene directly via the agentis CLI. Adjust confidence (`agentis memo set labeler:confidence 0.85`), inspect knowledge (`agentis knowledge list`), or stop individual agents. The CLI is your control plane.

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

## Confidence gradient

What agents do depends on their confidence level:

```mermaid
graph TD
    CHECK["Check confidence"]
    OBS["Observe: learn patterns, stay silent"]
    SUG["Suggest: emit findings for your review"]
    ACT["Act: post comments, assign issues, open MRs"]

    CHECK -- "< 0.6" --> OBS
    CHECK -- "0.6 - 0.84" --> SUG
    CHECK -- ">= 0.85" --> ACT

    style OBS fill:#1a1e24,stroke:#636e7b,color:#adbac7
    style SUG fill:#1a1e24,stroke:#c69026,color:#adbac7
    style ACT fill:#1a1e24,stroke:#57ab5a,color:#adbac7
```

**Start at 0.5 (observe)**. Agents watch your GitLab activity and build knowledge. Check logs to see what they are learning: `tail -f .agentis/logs/labeler.log`

**Promote to 0.6 (suggest)** when you trust what they have learned. Agents emit suggestions to the colony bus and log what they would do. They still do not touch GitLab. Watch all suggestions in one stream:

```bash
agentis memo set labeler:confidence 0.6
./watch-suggestions.sh          # Live feed from all 21 agent logs
```

**Promote to 0.85 (autonomous)** when ready. Start with low-risk agents (labeler, style_reviewer) before promoting high-impact ones (code_writer, approval_decider).

```bash
agentis memo set labeler:confidence 0.85
```

| Colony | Autonomous actions |
|--------|--------------------|
| Triage | Creates issues, applies labels, sets priority, assigns people |
| Code Review | Posts review comments, approves MRs, requests changes |
| Planning | Posts scope/risk/breakdown plans as issue comments |
| Implementation | Creates branches, commits code and tests, opens MRs |
| Release | Runs pre-release checks, posts ship decisions, creates tags and releases |

You can always demote an agent back: `agentis memo set labeler:confidence 0.5`

## Security

Your GitLab personal access token is stored in plaintext in 5 files:

```
<colony>/config/colony.toml     # token = "glpat-..."
```

`install.sh` sets these to mode 0600 (owner-only). If you move a federation directory to a multi-user system or copy configs manually, re-run `chmod 600 <colony>/config/colony.toml` on each.

Rotate tokens periodically via GitLab (User Settings -> Access Tokens). Re-run `./install.sh` and answer `Y` to the "Update GitLab credentials" prompt — it accepts a new token without rewriting the colony templates.

Out-of-scope (not implemented): integration with a system secret store (Secret Service, macOS Keychain, `pass`). If you need that today, replace `token = "..."` with a reference your shell evaluates before starting the federation.

## What to expect

**Day 1**: Nothing visible. Agents are silent at 0.5. Check `agentis daemon list` and logs to confirm they are polling.

**Week 1-2**: Knowledge entries accumulate from your GitLab activity. Run `agentis knowledge list` to inspect.

**After promotion**: Suggestions appear in logs (0.6) or directly on GitLab (0.85). Knowledge keeps growing with every tick. The runtime slowly decays the per-entry confidence score that `learn()` attaches to each unvalidated knowledge row (`knowledge.confidence_decay_rate`, default 0.01/hr, floor `knowledge.confidence_decay_min` 0.05; validated entries are left alone), which is a separate dial from the per-agent promotion level — it affects how much weight an old entry carries inside an agent, not which behavior gradient the agent is running at.

## Auto-confidence from feedback (#106)

Suggestions don't just sit in logs — participating agents score themselves against what you actually did. The loop is:

1. Agent emits a suggestion at confidence 0.6–0.84 (SUGGEST mode) and stashes a "pending verdict" — issue/MR id plus the payload it proposed.
2. On a later tick, agent fetches the current GitLab state of the artifact and compares.
3. Exact match → confidence `+0.02`. Partial match → `+0.005`. Mismatch → `-0.01`. Still no operator action → leave pending, re-check next tick.
4. Verdicts that age past 24 h without operator action are dropped without scoring — absence is not evidence of wrong suggestion.

**Autonomy cap**. Auto-promotion stops at **0.85**. Positive deltas above the cap are clipped; the agent has to earn *suggestion trust* automatically, but you still have to manually bump it from 0.85 (via the dashboard ▲ button or `agentis memo set <agent>:confidence 0.85`) before it starts writing to GitLab. This is deliberate — the auto-loop earns suggestion trust from matching your style; autonomy is your call. Negative deltas are not capped, so a confident agent that goes off the rails can still be pulled back down.

**Phase 1 scope** (what ships today). The feedback loop is wired into the `labeler` agent as the reference implementation. Suggested labels are compared against the labels you actually apply to the issue (set overlap). The remaining four reference agents — `style_reviewer`, `plan_reviewer`, `code_writer`, `version_bumper` — will follow in separate PRs using the same pattern. Each needs its own matcher (did the MR get merged? was the plan followed? was the version tagged?) but the infrastructure (`clamp_auto`, `signal_to_delta`, `apply_feedback`, `record_*_verdict`, `evaluate_*_verdict`, `get-issue` gitlab-api subcommand) is in place.

**Config knobs** live in each colony's `config/colony.toml` under `[feedback]`. The current shipment reads the defaults directly from the agent source (`match_rate = 0.02`, `partial_rate = 0.005`, `mismatch_rate = 0.01`, `timeout_s = 86400`, `autonomy_cap = 0.85`). The TOML section is declared so you can see where runtime-configurable knobs will land without a future config rewrite being disruptive.

**Observability**. Every delta prints one line to the agent's log: `[labeler] feedback delta 0.02 confidence 0.62 -> 0.64`. Grep that prefix to audit every confidence change the agent made to itself. The dashboard's per-agent confidence bar reflects the current memo value regardless of how it moved.

**Why not promote straight through to 0.85**. The cap makes the honest claim match the observed behavior: *agents learn to suggest well*. Promoting them past that line ought to be an explicit operator decision, not a drift that happened while you weren't looking.

## Colonies

| Colony | Agents | What it learns |
|--------|--------|---------------|
| [Triage](./triage/) | 4 | Issue creation, labeling, prioritization, routing |
| [Code Review](./code-review/) | 5 | Style, logic, security, test coverage review, approval decisions |
| [Planning](./planning/) | 4 | Scope estimation, risk assessment, task decomposition, plan review |
| [Implementation](./implementation/) | 4 | Code generation, test writing, refactoring, commit conventions |
| [Release](./release/) | 4 | Pre-release checks, ship decisions, changelogs, versioning |

Cross-colony wiring: Triage routes issues to Implementation. Implementation signals Code Review and Release when an MR is ready. See individual colony READMEs for internal event wiring.

## Knowledge portability

Every `learn()` call in the federation's agents tags entries with one of `observed` (passive learning from GitLab activity), `emitted` (suggestion logged at confidence 0.6-0.84), or `acted` (autonomous action taken at ≥ 0.85) plus the colony name (`triage`, `code-review`, `planning`, `implementation`, `release`).

**Personal vs team (`#104`).** If you set your GitLab username during `./install.sh` (or in `colony.toml` under `[gitlab] me = "..."`), three agents (`labeler`, `prioritizer`, `style_reviewer`) additionally tag their `acted` learn calls as either `personal` (the issue/MR author matches your username) or `team` (anyone else). The remaining agents still tag only `observed|emitted|acted` + colony; widening coverage is tracked as future work. If you leave the username empty, every entry keeps the legacy `team` tag so exports stay stable.

Bulk export/import is available at the runtime level and will carry all entries as-is:

```bash
agentis knowledge export > fed-knowledge.json
agentis knowledge export --tags personal > my-preferences.json  # carry just your style
agentis knowledge import fed-knowledge.json --merge
```

Filtering by `--tags observed`, `--tags emitted`, `--tags acted`, `--tags <colony>`, `--tags personal`, or `--tags team` works once the matching agents have acted at least once with the relevant author context.

## Troubleshooting

**Agents are silent after starting**: Expected at confidence 0.5. Check `agentis daemon list`. If running, check logs: `tail -f .agentis/logs/router.log`.

**"GitLab poll failed"**: Token lacks `api` scope, or the project path is wrong.

**"Config not found"**: Run `./install.sh` or copy the template: `cp config/colony.example.toml config/colony.toml`

**LLM errors**: Check your backend configuration in `.agentis/config`. For CLI backends, verify the command works in your terminal. For HTTP backends, verify the endpoint is reachable and the API key is set.

**Agents not learning**: Run `agentis knowledge list`. If empty after several ticks, verify the GitLab project has recent activity.

**Log growth**: Logs go to `.agentis/logs/<agent>.log` with no built-in rotation. Volume is low (a few lines per tick per agent), but with 21 agents running continuously and occasional error loops (e.g. a bad GitLab token causing one log line per retry × 6 retries × per tick) individual logs can reach tens of megabytes per day. A sample logrotate config lives at `ops/logrotate.conf` — copy it into `/etc/logrotate.d/` (requires sudo) and adjust the path to your federation root, or adapt it for a user-level cron if you prefer not to touch system logrotate.

As a zero-config fallback, `start-federation.sh` can be asked to truncate logs on start by setting `TRUNCATE_LOGS=1` in the environment. This keeps disk usage bounded between manual restarts but loses history — use logrotate for long-running federations.

## Extension points

Terminal colony bus events with no internal listener, meant for external consumption (webhooks, dashboards, custom agents):

| Event | Emitter | When |
|-------|---------|------|
| `triage:label_suggestion` | labeler | Confidence 0.6-0.84: label suggestion for human review |
| `triage:priority_suggestion` | prioritizer | Confidence 0.6-0.84: priority suggestion for human review |
| `review:decision_suggestion` | approval_decider | Confidence 0.6-0.84: approve/reject suggestion |
| `review:escalation` | approval_decider | Confidence >= 0.85: MR requires human attention |
| `planning:draft_plan` | plan_reviewer | Confidence 0.6-0.84: assembled plan for human review |
| `release:version_bumped` | version_bumper | After tag/release creation or version bump suggestion |
