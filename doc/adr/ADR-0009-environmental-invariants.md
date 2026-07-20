---
id: ADR-0009
title: Environmental invariants as an optional per-federation evolve-loop surface
status: Proposed
date: 2026-07-19
accepted-date:
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [evolution, invariants, optional-surface, substrate-contract]
---

# ADR-0009: Environmental invariants as an optional per-federation evolve-loop surface

## Context

agentis-core designed **environmental invariants** — operator-defined,
content-addressed negative predicates that participate in selection
inside the evolution loop (inviolable predicates cause a hard cull,
costly predicates apply a graded fitness/ledger penalty). The RFC is
[Replikanti/agentis-core#929](https://github.com/Replikanti/agentis-core/issues/929);
the mechanism shipped as the MVP in agentis-core **v1.23.0**
([Replikanti/agentis-core#932](https://github.com/Replikanti/agentis-core/pull/932)):
content-addressed `.inv` predicate modules, fail-closed loading via
`evolution.invariants_dir`, inviolable cull + costly penalty/ledger
debit, an order-independent invariant-set hash, and full provenance
(lifecycle events + trace).

This repo needs an ADR to define how a federation adopts the surface,
for two reasons that both cut against the obvious framings:

- [ADR-0003](./ADR-0003-federation-portability-contract.md) explicitly
  rejected a runtime-layer federation manager in agentis-core:
  "federations are a directory-shape convention, not a runtime
  concept." Environmental invariants are evaluated **inside**
  agentis-core's evolve loop, not by any tool in this repo, so they
  must NOT be framed as a new portability-contract item that this
  repo's tooling implements or checks. The compatible framing is
  ADR-0003's **optional surface** pattern instead: a per-federation
  artifact the runtime consumes when present and ignores when absent,
  the same shape as `.dashboard-version` and
  `tools/auto-promote-config.yaml`.
- [ADR-0001](./ADR-0001-confidence-tiers.md) already establishes the
  philosophical precedent this ADR generalizes: "Evolution is free to
  move the agent within the ladder; it must not move the rungs."
  Environmental invariants are the same stance applied to substrate
  physics rather than confidence tiers — fixed laws the evolving
  population cannot renegotiate, because they are evaluated by the
  runtime, not by the agent code being evolved.

**Terminology note.** "Environmental invariants" (this ADR) is a
distinct concept from dark-factory's **protocol invariants** — the
`stateful-invariant-fuzz` method in
[`dark-factory/auditor/methods/registry.md`](../../dark-factory/auditor/methods/registry.md)
and the "watches read-only protocol invariants" line in
[`dark-factory/README.md`](../../dark-factory/README.md). Protocol
invariants are smart-contract solvency/safety properties a security
audit checks against; environmental invariants are evolve-loop
selection predicates the runtime evaluates against an evolving
population. Same English word, unrelated mechanisms — do not conflate
the two when reading either doc.

## Decision

Adopt environmental invariants as an **ADR-0003-style optional
surface**: a federation MAY point its runtime config at a directory of
`*.inv` predicate modules via `evolution.invariants_dir` in the
federation's `.agentis/config` (the same file that already carries
`llm.backend`, per this repo's `CLAUDE.md` LLM-backend section).

- **Absent = off.** If `evolution.invariants_dir` is unset, evolution
  behaves byte-identically to pre-#929 agentis-core: no invariant
  loading, no cull, no penalty.
- **Set = fail-closed.** Per PR#932, once the key is set, a missing
  directory, zero modules, or a parse error aborts the evolve run
  rather than silently degrading — this is deliberate substrate
  behaviour (a federation cannot half-adopt a safety law), not a gap
  this ADR is asking to soften.
- **Federations select, core enforces.** A federation's only
  responsibility is choosing (or authoring) an invariant-set directory
  and pointing `evolution.invariants_dir` at it. The predicate
  evaluation, inviolable-cull decision, costly-penalty math, and
  content-addressed hashing all happen inside agentis-core's evolve
  loop. No `.ag` scenario in this repo re-implements or re-checks an
  invariant the core loop already gates.

### Selection-surface coverage per federation type

The MVP hooks only the CLI `agentis evolve` generational loop
(`run_arena_variant` and the selection block in `evolve.rs`). Within
this repo, that loop is invoked solely from `tools/auto-promote.sh`'s
legacy `agentis evolve` else-branch (`:532–537`), taken when
`evolve.mutation.enabled=false` (the default). When
`evolve.mutation.enabled=true`, `auto-promote.sh:507–527` instead
routes to `tools/auto-evolve-ab.sh`'s mutation/A/B scheduler, which
spawns each candidate via `agentis daemon` (`tools/auto-evolve-ab.sh:469`)
and never calls `agentis evolve` — so that path does not reach
`cmd_evolve` and is not gated by the arena's runtime-behavior (payload
v1) evaluation. As of agentis-core **v1.24.0**, a second, narrower
gate exists for exactly this case: `agentis invariant check
<candidate.ag>` ([Replikanti/agentis-core#937](https://github.com/Replikanti/agentis-core/issues/937),
merged [PR#940](https://github.com/Replikanti/agentis-core/pull/940))
is a read-only, pre-spawn CLI command a daemon-A/B harness can call to
reject a candidate *before* spawning it, evaluating the same active
`evolution.invariants_dir` set against the payload-v2 source-shape
fields ([Replikanti/agentis-core#938](https://github.com/Replikanti/agentis-core/issues/938),
merged [PR#939](https://github.com/Replikanti/agentis-core/pull/939):
`parse_ok`, `tier_coverage_ok`, `has_cb_line`, plus `source_hash`) —
modules that reference a runtime-only field are skipped, not
evaluated. Since [PR#1753](https://github.com/Replikanti/agentis-colonies/pull/1753)
`tools/auto-evolve-ab.sh` invokes this gate as an **observe-only**
probe before each candidate spawn: the verdict is recorded to the
mutation ledger for parity comparison, while the harness's four bash
validity checks remain the authoritative gate until real-run parity
is proven.

| Federation type | Selection surface | Covered today? |
|---|---|---|
| Federations on the legacy `agentis evolve` path (`tools/auto-promote.sh`'s else-branch, `evolve.mutation.enabled=false`, e.g. observe-only agents) | Generational evolve loop | Yes — `evolution.invariants_dir` applies |
| `research-foundry`'s mutation/A/B scheduler (`tools/auto-evolve-ab.sh`, `evolve.mutation.enabled=true`, candidates spawned via `agentis daemon`) | Mutation/A/B daemon-spawn loop | Partially — the source-shape pre-spawn gate exists since agentis-core v1.24.0 (`agentis invariant check`) and the harness invokes it **observe-only** since [PR#1753](https://github.com/Replikanti/agentis-colonies/pull/1753) (verdict recorded to the mutation ledger; adoption was [Replikanti/agentis-colonies#1736](https://github.com/Replikanti/agentis-colonies/issues/1736)); the four bash validity checks in `auto-evolve-ab.sh` remain the authoritative gate until real-run parity is proven, and runtime-behavior (payload v1) invariants remain ungated on this path |
| `tribes-bench`, `trading-binance` (`replicate()`-grown daemon populations, no generational `agentis evolve` call in their scripts today) | `replicate()` / daemon-population growth | Not yet for runtime-behavior invariants — no enforcement at `replicate()` admission or population sweep ships today, tracked as [Replikanti/agentis-core#942](https://github.com/Replikanti/agentis-core/issues/942) (replicate-admission/sweep enforcement) and [Replikanti/agentis-core#943](https://github.com/Replikanti/agentis-core/issues/943) (capability-absence/egress-allowlist predicates). `agentis invariant check`'s pre-spawn source-shape gate is available to any harness that spawns candidates, but it is not the runtime-admission surface these federations need |

This ADR does not promise the `replicate()`/daemon-population surface
is gated; that is future core work ([Replikanti/agentis-core#942](https://github.com/Replikanti/agentis-core/issues/942)
and [Replikanti/agentis-core#943](https://github.com/Replikanti/agentis-core/issues/943),
the concrete follow-ups from agentis-core#929's original phase-2 note),
out of this ADR's authority to commit to.

## Behavioural contract

A federation that claims this optional surface:

MAY:
- Set `evolution.invariants_dir` in its `.agentis/config` to a
  directory of `.inv` predicate modules.
- Author its own `.inv` modules or reuse a shared set across
  federations.

MUST NOT:
- Implement invariant enforcement itself — no `.ag` scenario may
  re-check a predicate the core evolve loop already gates. Doing so
  would let an evolved agent route around a check implemented in its
  own evaluated language, defeating the "fixed law" property.
- Treat `evolution.invariants_dir` as a portability-contract
  requirement. It is optional; ADR-0003's required-surface table is
  unchanged by this ADR.

A federation that does NOT set `evolution.invariants_dir`:
- Gets pre-#929 evolve behaviour, unconditionally. This is not a
  degraded mode to fix — it is "feature off," the same posture
  ADR-0003 already normalizes for `.dashboard-version` and
  `auto-promote-config.yaml`.

The `.inv` predicate syntax itself is core-authored content; this ADR
does not restate it — see agentis-core's config reference for the
authoritative format.

## Consequences

**Positive:**

- No runtime code change lands in this repo as a result of this ADR;
  the artifact contract is documented ahead of any per-federation
  adoption work.
- Per-federation adoption issues can cite a stable contract instead of
  re-deriving it from the core RFC each time.
- The optional-surface framing keeps this repo's authority boundary
  clean: this repo documents federation-facing config, agentis-core
  owns predicate evaluation.

**Negative / known limitations:**

- `research-foundry`'s mutation/A/B path (`tools/auto-evolve-ab.sh`) is
  NOT gated by the arena's runtime-behavior evaluation, for the same
  reason as the table split above: candidates are spawned via `agentis
  daemon`, not `agentis evolve`, so `cmd_evolve`'s invariant gate never
  runs on this path. Since agentis-core **v1.24.0**, a pre-spawn
  source-shape substrate gate DOES exist —
  `agentis invariant check <candidate.ag>`
  ([Replikanti/agentis-core#937](https://github.com/Replikanti/agentis-core/issues/937),
  [PR#940](https://github.com/Replikanti/agentis-core/pull/940)) —
  evaluating the payload-v2 source-shape fields
  ([Replikanti/agentis-core#938](https://github.com/Replikanti/agentis-core/issues/938),
  [PR#939](https://github.com/Replikanti/agentis-core/pull/939)) — and
  since [PR#1753](https://github.com/Replikanti/agentis-colonies/pull/1753)
  (adoption tracked as [Replikanti/agentis-colonies#1736](https://github.com/Replikanti/agentis-colonies/issues/1736))
  `tools/auto-evolve-ab.sh` invokes it as an observe-only probe whose
  verdict lands in the mutation ledger. The probe never gates: the
  four bash validity checks remain the authoritative gate until
  real-run parity is proven (bash-check removal is a deferred
  follow-up), and runtime-behavior (payload v1) invariants remain
  ungated there regardless.
- `tribes-bench` and `trading-binance`'s `replicate()`-grown daemon
  populations are NOT covered by this MVP. A federation relying solely
  on `replicate()` gets no invariant gating today regardless of
  whether `evolution.invariants_dir` is set. This is a real gap,
  tracked as [Replikanti/agentis-core#942](https://github.com/Replikanti/agentis-core/issues/942)
  (`replicate()`-admission gating / population sweep) and
  [Replikanti/agentis-core#943](https://github.com/Replikanti/agentis-core/issues/943)
  (capability-absence and egress-allowlist predicates the same
  federations need), not papered over here.
- `install.sh` / orchestrators do not yet prompt for
  `evolution.invariants_dir`; wiring that prompt into any federation's
  setup flow is adoption work for a separate, later issue — not part
  of this ADR.
- No example `.inv` module ships from this ADR. It defines the
  contract, not sample content.

## Alternatives considered

- **Fold this into ADR-0003 as a new required- or optional-surface
  row.** Rejected: ADR-0003 explicitly excludes runtime/substrate
  concepts ("federations are a directory-shape convention, not a
  runtime concept"), and invariant evaluation happens inside
  agentis-core's evolve loop, not in any platform tool this repo owns.
  A dedicated ADR keeps that boundary explicit.
- **Let federations implement invariant checks in `.ag`.** Rejected:
  this defeats the "fixed law the population cannot renegotiate"
  property from ADR-0001 — an agent evolving inside its own evaluated
  language could evolve around a check implemented in that same
  language. The predicate must be evaluated outside the thing being
  evolved.
- **Wait for the `replicate()`/daemon phase-2 surface before writing
  any ADR.** Rejected for the same reason ADR-0003 rejected waiting
  for a second federation: the evolve-loop surface is settled and
  shipped now (v1.23.0), and per-federation adoption issues need a
  contract to cite before they can proceed. Waiting produces a
  retroactive ADR under deadline pressure instead of one written with
  slack.

## References

- [Replikanti/agentis-core#929](https://github.com/Replikanti/agentis-core/issues/929)
  — environmental invariants RFC.
- [Replikanti/agentis-core#932](https://github.com/Replikanti/agentis-core/pull/932)
  — MVP implementation, merged in agentis-core v1.23.0.
- [`doc/adr/ADR-0001-confidence-tiers.md`](./ADR-0001-confidence-tiers.md)
  — philosophical precedent for fixed substrate law the evolving
  population cannot renegotiate.
- [`doc/adr/ADR-0003-federation-portability-contract.md`](./ADR-0003-federation-portability-contract.md)
  — optional-surface pattern this ADR reuses; boundary this ADR
  respects (no runtime concept added to the portability contract).
- [`dark-factory/README.md`](../../dark-factory/README.md) and
  [`dark-factory/auditor/methods/registry.md`](../../dark-factory/auditor/methods/registry.md)
  — terminology disambiguation source for "protocol invariants."
- [Replikanti/agentis-colonies#1736](https://github.com/Replikanti/agentis-colonies/issues/1736)
  — scoping analysis that surfaced the legacy-path vs. mutation/A/B
  coverage gap corrected by this revision; its adoption work landed
  observe-only via [PR#1753](https://github.com/Replikanti/agentis-colonies/pull/1753).
- [Replikanti/agentis-core#937](https://github.com/Replikanti/agentis-core/issues/937)
  — mechanism decision for gating the `agentis daemon` mutation/A/B
  spawn path; shipped in agentis-core v1.24.0 as
  [PR#940](https://github.com/Replikanti/agentis-core/pull/940),
  the read-only pre-spawn `agentis invariant check` CLI gate.
- [Replikanti/agentis-core#938](https://github.com/Replikanti/agentis-core/issues/938)
  — extend the predicate payload with source-shape fields so
  `auto-evolve-ab.sh`'s validity checks are expressible as
  environmental invariants; shipped in agentis-core v1.24.0 as
  [PR#939](https://github.com/Replikanti/agentis-core/pull/939)
  (payload v2: `parse_ok`, `tier_coverage_ok`, `has_cb_line`).
- [Replikanti/agentis-colonies#1745](https://github.com/Replikanti/agentis-colonies/issues/1745)
  — deliverable-now slice adopting `evolution.invariants_dir` on the
  legacy `agentis evolve` path only.
- [Replikanti/agentis-core#942](https://github.com/Replikanti/agentis-core/issues/942)
  — concrete phase-2 follow-up: gate `replicate()` admission and/or a
  daemon-population sweep for runtime-field invariant enforcement
  (the surface `tribes-bench`/`trading-binance` need).
- [Replikanti/agentis-core#943](https://github.com/Replikanti/agentis-core/issues/943)
  — concrete phase-2 follow-up: capability-absence and
  egress-allowlist predicates, complementing #942.

## Supersedes

(none)
