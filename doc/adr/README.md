# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for the
agentis-colonies repository. Each ADR captures a single normative
design decision: its context, the decision itself, its behavioural
contract, its consequences, and the alternatives that were rejected.

## Conventions

ADRs are **append-only**. To change a decision, write a new ADR that
references and supersedes the old one — never edit the status of an
already-merged ADR in place. Fix typos and broken links freely; do
not rewrite decisions.

## Index

- [ADR-0001: Confidence tiers for autonomous agent behaviour](./ADR-0001-confidence-tiers.md) — Proposed, 2026-04-17
- [ADR-0002: Forge abstraction — normalized wrapper dispatch for multi-forge federations](./ADR-0002-forge-abstraction.md) — Accepted, 2026-04-24
- [ADR-0003: Federation portability contract — what every federation in this repo must provide](./ADR-0003-federation-portability-contract.md) — Accepted, 2026-04-24
- [ADR-0008: Compute-first novelty discovery as the canonical pattern for novelty-requiring Agentis federations](./ADR-0008-compute-first-novelty.md) — Proposed, 2026-05-17

## Evaluation records

Pre-decision evaluations whose recommended decision lands outside this
repository (typically in agentis-core). Numbered ADRs they lead to should
reference them.

- [Single-agent restart supervision — where the kill/poll/verify machine should live](./daemon-restart-supervision.md) — Proposed, 2026-07-02
