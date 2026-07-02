---
id: daemon-restart-supervision
title: Single-agent restart supervision — where the kill/poll/verify machine should live
status: Proposed
date: 2026-07-02
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [tooling, supervision, restart, dev-apprenticeship, agentis-core]
---

# Single-agent restart supervision — where the kill/poll/verify machine should live

Evaluation record for [#1357](https://github.com/Replikanti/agentis-colonies/issues/1357)
(part of the [#1353](https://github.com/Replikanti/agentis-colonies/issues/1353)
"less bash, more runtime" survey). This is not yet a numbered, normative ADR:
the decision it recommends lands in **agentis-core**, outside this repository.
It records the evaluation the issue asks for and the interim consolidation
shipped alongside it, so the eventual upstream ADR has its context in one place.

## Context

Every colony's `start-colony.sh` `--restart-agent` path (added in
[#257](https://github.com/Replikanti/agentis-colonies/issues/257), hardened in
[#285](https://github.com/Replikanti/agentis-colonies/issues/285)) reimplemented
**process supervision in bash**, five times over, byte-identically:

1. Query the daemon registry (`agentis daemon list --json`), parsed by an
   embedded `python3` snippet matching by colony + `/agents/<name>.ag`
   source suffix — the registry collapses duplicates by `agent_id`, so the
   PID must be dug out of the JSON, not the human listing.
2. SIGTERM the live PID.
3. Poll `kill -0` every 0.2 s × 25 iterations (5 s) for exit.
4. SIGKILL survivors, then a 1 s settle.
5. Best-effort removal of the registry sidecar files (`pid`, `watchdog.pid`,
   `colony`, `heartbeat`, `status`, `stop`) so the registry does not keep a
   stale pointer to the dead `agent_id`.

That is a kill/poll/verify restart machine — supervisor logic — living in
operator shell scripts. The same scripts also carry the multi-repo
`GITHUB_REPOS_JSON` assembly loop ([#316](https://github.com/Replikanti/agentis-colonies/issues/316) M2),
a parse/transform job that is similarly heavier than typical bootstrap shell.

The question #1357 asks: should this move behind an `agentis daemon restart`
subcommand (agentis-core), or into an `.ag` supervisor agent?

## Options evaluated

### Option A — `agentis daemon restart` subcommand in agentis-core

The runtime already owns every ingredient: the registry (it writes the
sidecar files this machine cleans up), the daemon lifecycle (spawn,
watchdog, stop), and the process table. A `daemon restart <agent-id|--source
<path>>` subcommand would:

- eliminate the registry round-trip through JSON + embedded python — the
  runtime can look its own daemons up in-process;
- own the TERM → poll → KILL escalation with correct semantics (it knows
  the watchdog PID relationship; the bash machine can only guess from
  sidecar file names);
- make sidecar cleanup transactional instead of best-effort `rm -f`;
- serve every federation, not just `dev-apprenticeship` — the same five-way
  duplication would otherwise be re-scaffolded into each new federation by
  `tools/new-federation.sh`.

Cost: an upstream change with its own release cycle, and the colonies must
keep a fallback until their runtime floor (`Requires: agentis >= X.Y.Z`)
rises past the version that ships it. Precedent for that dance exists — the
`--config-override` flag (#351) taught this repo not to consume upstream
flags before they demonstrably exist on the binary.

### Option B — an `.ag` supervisor agent

A supervisor colony agent that watches liveness memos and restarts dead or
duplicated siblings via `exec sh`. Rejected:

- **Wrong direction.** The machine exists to make *restarting an agent*
  reliable; parking it inside an agent recreates the bootstrap problem one
  level up (who restarts the supervisor?).
- **Wrong cost profile.** `.ag` scenarios run on tick intervals with
  cognitive-budget accounting and (potentially) LLM round-trips. Process
  supervision is deterministic OS work; paying `cb` for it violates the
  compute-first principle (ADR-0008) for zero judgement gained.
- **Capability mismatch.** The supervisor would still shell out for
  `kill`/`rm` via `exec sh` — the same bash, now wrapped in an agent, plus
  the `exec sh` env-sanitisation boundary (#1343) in the way.
- **The dashboard contract.** `/restart` delegates to `start-colony.sh
  --restart-agent` (#257) precisely so restart works when daemons are *down*;
  an in-federation supervisor is unavailable in exactly the states it is
  needed most.

### What stays shell regardless

- The `agentis daemon <source> --colony ... --tick-interval ...` **launch**,
  its liveness verification, and the parseable `started <agent> pid=<n>
  tick=<ms>` stdout line the dashboard's `/restart` endpoint consumes —
  irreducibly shell until the runtime grows a supervisor mode, and the #1357
  issue text already scopes them out.
- `agentis memo set` seeding — a CLI-shaped bootstrap concern.
- The `GITHUB_REPOS_JSON` assembly loop: it is **config parsing**, not
  supervision. It must run before any daemon exists, its inputs are
  colony.toml `[[forge.github]]` tables that the runtime deliberately knows
  nothing about (ADR-0002/ADR-0003 keep forge wiring on the federation
  side), and tokens are threaded through the environment — never argv — a
  property easiest to audit in the current one-place shell loop. Folding it
  into the runtime would leak forge schema into agentis-core; folding it
  into python-behind-a-helper is possible but buys nothing today because it
  is written once per colony boot, not per restart. It stays in
  `start-colony.sh` unchanged.

## Recommendation

**Option A is the end state**: propose `agentis daemon restart` upstream in
agentis-core, and once a released version ships it, replace the helper's
body with a thin call to the subcommand and raise the federation's runtime
floor in the same PR.

**Interim (shipped with this evaluation, #1357):** the five identical
inline machines are consolidated into one shared library,
[`tools/lib/daemon-restart.sh`](../../tools/lib/daemon-restart.sh)
(`daemon_restart_kill_existing <fed_root> <colony> <agent>`), sourced by
each colony's `--restart-agent` path. Behaviour is unchanged by
construction — the library body is the extracted block, parameterised by
federation root, colony name, and agent name — and is now covered by a
fixture-driven test (`tools/test-daemon-restart.sh`: TERM path, SIGKILL
escalation, no-match no-op, malformed-registry-JSON degradation, and
per-colony wiring). This removes the five-way duplication today, gives the
upstream subcommand a single call site to replace tomorrow, and keeps the
operator-facing contract (`--restart-agent` flags, exit codes 0/2/3/4, the
`started ...` line) byte-stable.

This is deliberately a **lower-priority** consolidation, as the issue notes:
the restart machine is a bootstrap/operator path exercised by the dashboard's
`/restart` endpoint and manual recovery — not a per-tick hot path.

## Consequences

- One copy of the kill/poll/verify machine instead of five; colony
  `start-colony.sh` scripts shrink by ~50 lines each and can no longer
  drift apart (test 5 of `tools/test-daemon-restart.sh` enforces the wiring).
- `tools/lib/daemon-restart.sh` becomes a runtime dependency of the
  federation and ships in the release bundle (`dev-apprenticeship/BUNDLE.manifest`).
- New federations scaffolded with an ADR-0003-conformant `--restart-agent`
  mode can source the same library instead of copying the block.
- When `agentis daemon restart` lands upstream, only the library body and
  the runtime floor change; the five colony scripts and the dashboard are
  untouched.
