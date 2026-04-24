---
id: ADR-0003
title: Federation portability contract — what every federation in this repo must provide
status: Accepted
date: 2026-04-24
accepted-date: 2026-04-24
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [portability, platform, scaffolding, multi-federation]
---

# ADR-0003: Federation portability contract — what every federation in this repo must provide

## Context

Today the repository ships exactly one federation, `dev-apprenticeship/`,
and almost every doc, script, and code path in the repo reads as
"`dev-apprenticeship` is the federation, `agentis-colonies` is its
home." That framing is true for the v1.x.x line but structurally wrong:

- `federation-dashboard/` is a separately-versioned, federation-agnostic
  component ([#252](https://github.com/Replikanti/agentis-colonies/issues/252)).
- `tools/auto-promote.sh` reads only the experience store + tier
  contract; it does not know what a "merge request" is.
- `doc/adr/ADR-0001-confidence-tiers.md` is normative for any
  federation, not just coder ones.
- `tools/kill-federation.sh` operates on PIDs and ports.

The platform supports any federation type — coder, data-ops, research,
support-triage, monitoring-ops — but the contract that makes a
federation "platform-compliant" is implicit. It exists in the
heads of the maintainers and in the shape of the dev-apprenticeship
tree. Waiting for the second federation to land before writing the
contract guarantees a retroactive abstraction under deadline pressure.

This ADR codifies the contract while there is slack. It does not
introduce a second federation, does not change any runtime behaviour,
and does not impose new obligations on the existing
`dev-apprenticeship/` tree (which already complies — that is how the
contract was derived).

## Decision

Adopt a **federation portability contract**: a fixed set of files and
behaviours every federation in this repo MUST provide, plus a smaller
set of OPTIONAL contracts whose absence degrades a specific platform
feature without affecting the rest.

The contract is the union of what `federation-dashboard`, `auto-promote`,
`kill-federation`, `colony-lint`, and `make-federation-bundle` already
inspect on `dev-apprenticeship/`. Nothing more, nothing less. A future
federation that satisfies this contract is automatically supported by
every platform tool the same day it lands.

### Required surface

Every `<federation>/` directory in the repo MUST contain:

| Path | Contract |
|------|----------|
| `<federation>/VERSION` | Single line, SemVer. Bumping triggers `tools/check-changelog.sh`. |
| `<federation>/CHANGELOG.md` | Keep-a-Changelog format. Each release section starts with `## [X.Y.Z] — YYYY-MM-DD` and carries a `**Requires:** agentis >= <version>` line; trailing section carries Keep-a-Changelog comparison links. |
| `<federation>/README.md` | Operator-facing intro. First paragraph identifies the federation's domain (what real-world workflow it learns) so the top-level `README.md` and `doc/federation-patterns.md` can cross-link. |
| `<federation>/BUNDLE.manifest` | Newline-separated list of paths (relative to repo root) that go into the release tarball. Validated by `tools/test-make-federation-bundle.sh`. |
| `<federation>/install.sh` | Operator-facing setup. Idempotent. Exit 0 = ready to start. Free to delegate prerequisite checks, prompt for credentials, seed memos, install sidecars. No prescribed argument shape — operator-facing UX is per-federation. |
| `<federation>/<colony>/agents/*.ag` | One or more `.ag` agent files per colony. Tier-gated per ADR-0001. |
| `<federation>/<colony>/config/colony.example.toml` | Per-colony config template. Operator copies to `colony.toml` and edits. |
| `<federation>/<colony>/scripts/start-colony.sh` | Per-colony launcher. Contract below. |

`<colony>` count is not constrained. A federation may ship one colony
or twenty; `colony-lint`, `auto-promote`, and the dashboard discover
them by directory scan.

### `start-colony.sh` contract (normative)

Every per-colony `start-colony.sh` MUST:

1. **Resolve `$0` symlink-safely** so the script can be invoked through
   `${XDG_BIN_HOME:-$HOME/.local/bin}/...` or via a relative path
   without breaking colony-relative paths. The canonical idiom (used by
   every dev-apprenticeship colony) is `python3 -c 'import os, sys;
   print(os.path.realpath(sys.argv[1]))' "$0"`.
2. **Source `tools/parse-toml.sh`** to read `<colony>/config/colony.toml`.
   The shared helper is resolved as `<fed>/tools/parse-toml.sh` first,
   then `<fed>/../tools/parse-toml.sh` (the latter so the federation
   works whether checked out as a sibling tree or a standalone
   tarball).
3. **Export `COLONY_DIR`** plus whatever federation-specific env vars
   the colony's `.ag` agents consume via `exec sh`. Forge-specific env
   wiring is per-federation (codified separately in
   [ADR-0002](./ADR-0002-forge-abstraction.md) for forge-bound
   federations); other federations are free to export whatever their
   agents need (data-source URL, runbook path, helpdesk endpoint, …)
   — the platform does not know or care.
4. **Launch `agentis daemon`** for each agent in the colony with
   `--colony <name> --tick-interval <ms>`. Tick interval is
   per-agent, looked up via a local `tick_interval_for()` case
   function with a fallback (60000ms for active agents, 180000–
   300000ms for reactive ones is the dev-apprenticeship convention,
   not a platform requirement).
5. **Support `--restart-agent <name>` mode**
   ([#257](https://github.com/Replikanti/agentis-colonies/issues/257))
   that respawns exactly one agent with the full colony env, skipping
   memo seeding and log truncation. On success, prints exactly one line
   `started <agent> pid=<n> tick=<ms>` on stdout.
6. **Use the documented exit codes:** `0` = ok, `2` = unknown flag /
   missing arg, `3` = unknown agent name for this colony, `4` = daemon
   launch failure. Anything else is undefined and may be surfaced to
   the operator as a transport error.
7. **Reject unknown flags with exit 2.** This is what makes the
   `--restart-agent` and `--rate-limit-status` flags safe to roll out
   incrementally — older federations exit 2 cleanly, the platform tool
   reports "feature not available" rather than crashing.

Optional flags (federations MAY support, platform tools MAY consume):

- `--rate-limit-status` ([PR 7 of #256](https://github.com/Replikanti/agentis-colonies/issues/256),
  shipped in dev-apprenticeship 1.1.0): execs the colony's
  forge/data-source rate-limit primitive and prints
  `{"remaining", "limit", "reset_at"}` JSON on stdout. Consumed by
  `federation-dashboard` 0.3.0's Forge Rate Limits tile. Federations
  whose underlying data source has no rate-limit concept (e.g. a local
  filesystem watcher) MAY omit this flag; the dashboard tile renders
  `err: exit 2` per colony in that case but the rest of the dashboard
  keeps working.

### Optional surface (degrades gracefully when absent)

| Path | Feature it enables | Behaviour when absent |
|------|--------------------|------------------------|
| `<federation>/.dashboard-version` | Pins the minimum `federation-dashboard` version `install.sh` will install. | Operator chooses the dashboard version manually; `install.sh` skips the dashboard prompt. |
| `<federation>/start-federation.sh` | One-command "launch every colony" entry point for operators. | Operator runs `<colony>/scripts/start-colony.sh` per colony manually. |
| `<federation>/kill-federation.sh` | One-command shutdown wrapper. | Operator runs `tools/kill-federation.sh --fed-dir <fed>` directly. |
| `<federation>/watch-suggestions.sh` | Live log-tail UX for operators. | Operator runs `tail -F .agentis/logs/*` themselves. |
| `<federation>/dashboard.sh` | Resolver wrapper that exec's the standalone `federation-dashboard` binary. | Operator runs the binary directly with `--fed-dir <fed>`. |
| `tools/auto-promote-config.yaml` (shared, but federations MAY override per-agent thresholds via the same file) | `auto-promote` sidecar promotes/demotes/evolves agents. | Tier transitions happen by operator-driven memo writes only; no automated promotion. |

The dashboard, `auto-promote`, and `kill-federation` MUST treat every
optional contract as opt-in. Missing files = feature off, not a hard
failure. `federation-dashboard-collector.py` already follows this
pattern for `.dashboard-version` and `auto-promote-decisions.py`; new
optional contracts MUST do the same.

### Non-prescriptive (federation chooses)

The contract deliberately does NOT prescribe:

- **Agent roles, colony names, or bus event names.** Triage / planning
  / implementation / code-review / release are dev-apprenticeship's
  decomposition of *coder* work; a data-ops federation might decompose
  into ingest / detect / alert / annotate. The platform does not know
  what an agent does, only that it ticks.
- **Forge or data source.** ADR-0002 governs forge-bound federations;
  a federation that does not talk to a forge has no obligation to that
  ADR. A federation might read from arXiv, Grafana, a helpdesk API, a
  filesystem watcher, a Kafka topic, or nothing at all.
- **LLM backend.** The `[llm]` section in `colony.toml` is informational;
  the actual backend is read by `agentis daemon` from `.agentis/config`.
- **Trigger labels, prompt vocabulary, memo keys.** Per-federation
  conventions, codified inside the federation's own README + agents.

### Versioning and release

Each federation is versioned independently per the existing release
process in [`CLAUDE.md`](../../CLAUDE.md#release-process). Tags use
`<federation>-v<X.Y.Z>`. The platform-wide release workflow
(`.github/workflows/release.yml`) fires on any `<federation>-v*` tag
push and runs `tools/make-federation-bundle.sh <federation> <version>`,
which expects the `BUNDLE.manifest` contract above. Adding a new
federation requires zero workflow changes — the matrix is `<federation>`
× `<version>` extracted from the tag name.

`colony-lint.sh` (via `check-changelog.sh`) loops over every versioned
component listed in its `COMPONENTS` array. Adding a new federation is
one line in that array.

## Consequences

### What changes in this PR

- ADR-0003 (this document) ratifies the contract.
- `tools/new-federation.sh` (new) generates a compliant federation
  skeleton: `VERSION`, empty `CHANGELOG.md` with a fresh `[Unreleased]`
  block, single-line `BUNDLE.manifest`, stub `README.md`, one scaffolded
  colony with a `start-colony.sh` that already conforms to the
  contract above. Output passes `colony-lint.sh` clean.
- `doc/federation-patterns.md` (new) sketches three non-coder
  federation types as proof the contract works beyond
  dev-apprenticeship. Patterns only — no code.
- Top-level `README.md` reframes from "dev-apprenticeship is the
  federation" to "agentis-colonies is a home for federations,
  dev-apprenticeship is the first one." Federations table stays;
  Components table stays; new "Starting a new federation" pointer.
- `CLAUDE.md` is split into a "Platform invariants" section (federation-
  agnostic: tier contract, release process, agent conventions, script
  conventions, scaffolding, ADRs) and a "dev-apprenticeship specifics"
  section (the bus-wiring table, the 21-agent inventory, the
  trigger-label vocabulary, the confidence-key index).
- `dev-apprenticeship/README.md` gains a one-paragraph framing intro
  identifying it as one example federation built on the platform, with
  pointers to `doc/federation-patterns.md` and `tools/new-federation.sh`
  for operators building their own.
- ADR-0001's tier table examples ("merge, tag, publish") are augmented
  with non-coder examples ("ack alert, post reply, trigger runbook")
  so the tier contract reads applicable across federation types.

### What is deferred (triggered by the second federation landing)

These are real design decisions that this ADR deliberately does not
answer, because the answer is unknowable without a second federation
to pressure-test it:

- **Multi-federation install on one machine.** Memo namespace
  collisions, port collisions, dashboard discovery — all
  federation-of-one today. The fix is per-federation memo prefixes
  + dashboard `--fed-dir` plurality + a multi-federation install flow,
  but the right shape will be obvious only when a real second
  federation surfaces the conflicts.
- **Dashboard plurality.** Does one dashboard process host N
  federations simultaneously, or is dashboard-per-federation the
  norm? Both are plausible; both have UX consequences.
- **Per-federation README enforcement** via `colony-lint`. A linter
  rule that "README.md must exist with a domain-identifying first
  paragraph" is mechanical to add but pointless before the platform has
  multiple federations to lint.
- **Per-federation autonomous-warning vocabulary** in the dashboard
  ("merging changes, tagging releases, publishing artifacts" is
  dev-apprenticeship-flavoured even after [#257](https://github.com/Replikanti/agentis-colonies/issues/257)).
  Future federations may want their own copy.

These are tracked in the issue body of
[#258](https://github.com/Replikanti/agentis-colonies/issues/258) under
"Later"; they are explicitly out of scope for this ADR.

### Migration of `dev-apprenticeship/`

None required. The contract was derived from `dev-apprenticeship/`'s
existing shape, so the federation already complies. The only
dev-apprenticeship-facing change in this PR is one paragraph in its
README clarifying it is an example federation, not the platform.

### Lints

`colony-lint.sh` gains no new rules in this PR. The existing
`tools/check-changelog.sh`, `tools/test-make-federation-bundle.sh`,
and start-colony exec-safety lints already enforce the bulk of the
contract on `dev-apprenticeship/`. Per-federation lint rules
(README-shape enforcement, mandatory `tick_interval_for()` case
function, etc.) are in the deferred bucket above — premature without a
second federation.

## Alternatives considered

### Per-federation contract files (`portability-contract.toml`)

Have each federation declare its compliance via a TOML file the
platform reads (similar to `BUNDLE.manifest`). Rejected because the
contract is binary — either the federation directory shape matches or
it doesn't — and a declaration file would just restate what
`colony-lint` already checks structurally. The cost (one more file per
federation, drift between declaration and reality) outweighs the
benefit (machine-readable compliance).

### Runtime-layer federation manager in `agentis-core`

Move federation discovery + per-federation state into the runtime as a
first-class concept. Rejected for the same reason ADR-0002 rejected a
runtime forge adapter: federations are a directory-shape convention,
not a runtime concept. The dashboard and platform tools already work
purely off the directory shape; promoting it to a runtime concern
would ossify it without removing duplication.

### Nest federations under `federations/<name>/` instead of top-level

Move `dev-apprenticeship/` to `federations/dev-apprenticeship/` for
"obvious" multi-federation framing. Rejected because (a) it would
break every external link to the federation's README/CHANGELOG/install
script that has accumulated since v0.1.0, (b) it would invalidate
the install command in every release notes blob, and (c) the framing
gain is cosmetic — the top-level README's reframing in this PR
achieves the same readability outcome without the migration tax.
A future ADR may revisit this if the federation count climbs past
three.

### Defer ADR until the second federation actually exists

The "natural" point to write a portability contract is when porting
forces it. Rejected explicitly per the issue: writing the contract
under a deadline + against an existing implementation produces the
same kind of retroactive abstraction ADR-0002 was designed to avoid
on the forge side. The cost of writing it now is one ADR + one
scaffolding script + a doc-reframing pass; the benefit is that the
second federation has a target to aim at.

## References

- GitHub issue:
  [Replikanti/agentis-colonies#258](https://github.com/Replikanti/agentis-colonies/issues/258)
  (motivates this ADR; carries the "Later" deferred-work bucket).
- [`doc/adr/ADR-0001-confidence-tiers.md`](./ADR-0001-confidence-tiers.md)
  — tier contract, federation-agnostic by construction.
- [`doc/adr/ADR-0002-forge-abstraction.md`](./ADR-0002-forge-abstraction.md)
  — forge-coupling contract for forge-bound federations.
- [Replikanti/agentis-colonies#252](https://github.com/Replikanti/agentis-colonies/issues/252)
  — `federation-dashboard` extracted as a federation-agnostic component.
- [Replikanti/agentis-colonies#257](https://github.com/Replikanti/agentis-colonies/issues/257)
  — `start-colony.sh --restart-agent` contract, codified in this ADR
  as the platform-required restart shape.
- [`CLAUDE.md`](../../CLAUDE.md) — release process, agent conventions,
  script conventions (split into "Platform invariants" and
  "dev-apprenticeship specifics" in this PR).
- [`doc/federation-patterns.md`](../federation-patterns.md) —
  non-coder federation patterns built against this contract.

## Supersedes

(none)
