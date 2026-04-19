---
id: ADR-0001
title: Confidence tiers for autonomous agent behaviour
status: Proposed
date: 2026-04-17
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [confidence, autonomy, governance, dev-apprenticeship]
---

# ADR-0001: Confidence tiers for autonomous agent behaviour

## Context

Agents in the Agentis runtime keep a per-topic `confidence` value as a
runtime memo (JSONL at `~/.agentis/memo/<agent>:confidence.jsonl`). The
value is not a compile-time constant; it drifts as the agent observes
outcomes and as the auto-promotion scheduler steps it along. Agent programs
written in the `.ag` DSL branch on this value to decide what the agent
is allowed to do at a given moment: typically a low branch that merely
emits a suggestion, and a high branch that performs a real side effect.

The initial dev-apprenticeship federation — 21 agents spread across
five colonies (triage, code-review, planning, implementation, release)
— settled on a two-threshold pattern that has since shown four
correlated failures:

1. **Dead-zone seed.** New agents are spawned with `confidence = 0.5`
   on every topic. No `.ag` scenario in the federation branches at
   `>= 0.5`. The agent is therefore active but inert: it consumes its
   cognitive budget, writes memos, but produces no observable signal
   that evolution or the auto-promotion script can feed on. This is
   the "money pump" pattern — spend is incurred before any learning
   surface exists. On a fresh federation, 17 of 21 agents sit at this
   dead zone.

2. **Flat `[0.6, 0.85)` interval.** Between the emit/suggest floor at
   `0.6` and the act/write ceiling at `0.85`, behaviour is constant.
   An agent at `0.61` and an agent at `0.84` are behaviourally
   indistinguishable. A quarter of the useful confidence range carries
   no information, and auto-promotion steps across that range are
   therefore unobservable.

3. **One threshold pair for every risk profile.** A style reviewer's
   "act" (leave a comment) and a release agent's "act" (push a tag)
   are gated by the same `0.85`. The failure modes are orders of
   magnitude apart — a wrong comment is noise, a wrong tag is an
   incident — yet the DSL encodes them identically. Operators have
   no vocabulary in which to say "this action needs more evidence
   than that one."

4. **Autonomy-or-silence for the reviewer quartet.** The four
   code-review reviewers (style, logic, security, test) only have a
   `>= 0.85` branch. Below it they are silent; at it they comment on
   the MR directly. There is no intermediate mode in which a
   reviewer can post a draft finding, mark it for human triage, or
   write to a shadow channel. The planning trio (risk_assessor,
   task_decomposer, scope_estimator) exhibits the mirror pathology:
   their confidence is capped at `0.6`, so a `>= 0.85` branch —
   if they had one — would never fire. They cannot graduate.

The common root is that the federation is trying to express a
four-stage trust gradient (not running → observing → proposing →
acting under review → acting alone) with only two thresholds and no
shared normative contract about what each stage permits. This ADR
introduces that contract.

The scope of this ADR is the semantic definition of tiers only. It
does not change the representation of `confidence` (still a JSONL
memo), does not change the `confidence` keyword in the `.ag`
language, and does not prescribe runtime enforcement beyond stating
what future work must preserve.

## Decision

Adopt four named **confidence tiers** with the following boundaries
and a shared seed:

| Tier            | Range           | Seed? |
|-----------------|-----------------|-------|
| `shadow`        | `[0.4, 0.6)`    | yes (spawn at `0.4`) |
| `propose`       | `[0.6, 0.8)`    | no |
| `review-gated`  | `[0.8, 0.95)`   | no |
| `autonomous`    | `[0.95, 1.0]`   | no |

Agents below `0.4` are **dormant**: the runtime treats them as not
yet admitted to the tier ladder. Seeding at `0.4` places a fresh
agent directly inside `shadow`, eliminating the dead zone.

The tier boundaries (`0.4 / 0.6 / 0.8 / 0.95`) are the canonical
numeric promotion thresholds for this ADR. Future ADRs may refine
the within-tier confidence update rule, but the boundaries are
fixed by this decision.

Every `.ag` scenario that currently branches on `confidence` must be
re-expressed in terms of these four tiers. The DSL keyword
`confidence` is retained; tiers are a convention layered on top of
it, exposed through a `tier(agent_name)` builtin that returns one of
the four tier names (plus `"dormant"` below `0.4`).

## Behavioural contract per tier

The following contract is **normative**. An author of an `.ag`
scenario should be able to answer "what is this tier allowed to do?"
from this section alone, without reading any implementation.

Four action classes are distinguished:

- **LLM call** — invoking a `prompt` or `delegate` expression that
  consumes real external compute.
- **Memo write** — updating any file under `~/.agentis/memo/`,
  including confidence, experience records, and learning entries.
- **Bus emit** — publishing on the federation bus (`emit`,
  inter-colony message, behaviour-log entry visible to peers).
- **External write** — any side effect outside the local node:
  GitLab comment/MR/tag, registry push, artefact upload, shell
  escape. "Draft" means the artefact is created in a non-published
  state (e.g. GitLab draft MR, comment to a triage-only channel)
  such that no external party is notified as if the agent had
  acted in its own name. "Direct" means the artefact is
  immediately visible to its intended external audience.

### `shadow` — `[0.4, 0.6)`

The agent is learning the shape of the problem. It produces data
for itself and for evolution, and nothing else.

- **MAY:** perform LLM calls; write memos, including experience
  records tagged `observed`; read the bus.
- **MUST NOT:** emit on the bus; perform any external write, draft
  or direct; call `learn(..., tags=["emitted"|"review-gated"|"acted"])`.

### `propose` — `[0.6, 0.8)`

The agent has enough signal to contribute to the federation but not
enough to be trusted on its own.

- **MAY:** everything allowed at `shadow`; emit on the bus; create
  **draft** external writes (e.g. draft GitLab MR, comment to a
  shadow channel, advisory annotation) explicitly marked as
  non-authoritative; call `learn(..., tags=["emitted"])`.
- **MUST NOT:** create direct external writes; merge, approve, or
  close external artefacts.

### `review-gated` — `[0.8, 0.95)`

Proposals have accumulated enough successful outcomes that the agent
is trusted to act externally, but only under a human-or-peer review
gate.

- **MAY:** everything allowed at `propose`; create **direct**
  external writes (post a real review comment, open a non-draft MR,
  publish a non-tag artefact); call `learn(..., tags=["review-gated"])`.
- **MUST NOT:** take any action that is terminal for a release
  artefact without a separate approver — specifically: merging an
  MR, pushing a release tag, promoting a package in the registry,
  rotating a credential, or any other action whose effect cannot
  be withdrawn by a subsequent automated step.

### `autonomous` — `[0.95, 1.0]`

The agent has demonstrated sustained, high-evidence success and may
act as the final authority for its action class.

- **MAY:** everything allowed at `review-gated`; perform terminal
  external writes (merge, tag, publish, rotate); act without a
  second gate; call `learn(..., tags=["acted"])`.
- **MUST NOT:** escalate beyond its own action class — an
  autonomous code-review agent does not thereby acquire release
  authority. Tier is per topic, not per colony.

### Cross-tier invariants

- A decrease in confidence that crosses a boundary **immediately**
  demotes the agent for future decisions; in-flight actions are
  unaffected.
- Tier does not shortcut OCap. An agent lacking a capability cannot
  perform the corresponding action even at `autonomous`. Tier is a
  necessary, not sufficient, condition for the action.
- An agent MAY call `learn` with `status ∈ {success, partial, fail}`
  at every tier. Only the `tags` set is restricted as above.

## Consequences

### Migration of existing `.ag` scenarios

All 21 federation agents currently branch on the two literals `0.6`
and `0.85`. Each such branch must be rewritten:

- `confidence >= 0.6` branches that produce a suggestion without
  external side effect map to a `propose` branch.
- `confidence >= 0.85` branches that perform a direct external
  write map to `review-gated`.
- Scenarios whose `>= 0.85` branch is a **terminal** action
  (release tag, merge, registry publish) must be split: the
  non-terminal part stays at `review-gated`, the terminal part
  moves to `autonomous`.
- Every agent must additionally gain an explicit `shadow` branch
  whose body performs observation and memo writes but no emit.
  This replaces the implicit dead zone.
- The planning trio's `0.6` cap is lifted as a consequence of this
  ADR: they must be allowed to climb through `propose` into
  `review-gated` on topics where evidence warrants it.

A scenario using a raw numeric threshold outside
`{0.4, 0.6, 0.8, 0.95}` should be flagged by colony-lint as
drifting from the ADR. The canonical way to gate behaviour is
`tier(<agent_name>) == "<tier>"`.

### Runtime changes in `agentis-core`

- The confidence memo format stays JSONL. No schema break.
- Spawn seeding moves from `0.5` to `0.4`. Existing memos at `0.5`
  remain valid and place the agent in `shadow`.
- A new `tier(agent_name: string) -> string` builtin is added,
  returning one of `"dormant" | "shadow" | "propose" |
  "review-gated" | "autonomous"`.
- The auto-promotion script (`tools/auto-promote.sh`) must be
  retargeted from its current `0.5 → 0.6 → 0.85` ladder to
  `0.4 → 0.6 → 0.8 → 0.95`.

### Impact on evolution and experience-store semantics

- Evolution gains a usable gradient in `[0.4, 0.6)` because agents
  in `shadow` emit experience records without acting.
- The `learn(..., tags=...)` vocabulary acquires a concrete meaning:
  `observed` at `shadow`, `emitted` at `propose`, `review-gated` at
  `review-gated`, `acted` at `autonomous`. The authoritative
  classification table consumed by the auto-promote heuristic
  (acting vs. observe buckets) lives in
  [`doc/auto-promote.md`](../auto-promote.md#classification); this
  ADR governs the emission side, that document governs the
  consumption side.
- Downstream retrieval heuristics SHOULD prefer records tagged
  `acted` or `review-gated` for action recommendations and records
  tagged `observed`/`emitted` for context-building.

## Alternatives considered

### Per-action risk weighting

Instead of four tiers, attach a risk weight to each action class
(comment = 0.1, MR = 0.3, tag = 0.9, etc.) and require
`confidence >= risk_weight`. Rejected because (a) the weights would
multiply the governance surface rather than shrink it — every
action class needs a calibration — and (b) the `.ag` author would
still need a vocabulary for *what kind* of trust the agent has,
not just *how much*. Tiers solve the vocabulary problem;
per-action risk weighting only reshuffles it. A follow-up ADR may
layer per-action overrides on top of the tier contract.

### Evolution-driven band adjustment

Let evolution choose each agent's own thresholds as part of its
genome. Rejected because it makes the governance contract
unreadable: two agents of the same colony would have different
notions of what "act" means, and peer review between them becomes
impossible. Evolution is still free to move the agent *within* the
ladder; it must not move the rungs.

### Keep the status quo (`0.5 / 0.6 / 0.85`)

Rejected on the four grounds in the Context section. Tuning within
the existing two-threshold scheme does not address the dead-zone
seed or the autonomy-or-silence reviewer pattern.

## References

- GitHub issue: Replikanti/agentis-colonies#173 (motivates this ADR)
- `CLAUDE.md` — runtime and federation conventions for `.ag` scenarios
- [`doc/auto-promote.md`](../auto-promote.md) — how agents move between these tiers (auto-promote / auto-evolve scheduler; installed by `dev-apprenticeship/install.sh`, see [#216](https://github.com/Replikanti/agentis-colonies/issues/216))

## Supersedes

(none)
