# doc/ index

Reference documentation for the agentis-colonies repository. The role-based entry points
are in the top-level [README's Documentation map](../README.md#documentation-map); this is
the flat index.

## Normative contracts

| Doc | What it decides | Mainly for |
|-----|-----------------|------------|
| [`adr/`](./adr/README.md) | Architecture Decision Records — the source of truth for cross-repo contracts | Architects, contributors |
| [`adr/ADR-0001-confidence-tiers.md`](./adr/ADR-0001-confidence-tiers.md) | The four-tier confidence ladder every `.ag` agent gates on — also the repo's safety model | Everyone; security reviewers |
| [`adr/ADR-0002-forge-abstraction.md`](./adr/ADR-0002-forge-abstraction.md) | GitLab-shape wire contract + `forge-api.sh` dispatch that lets one agent body serve GitLab and GitHub | Contributors touching forge scripts |
| [`adr/ADR-0003-federation-portability-contract.md`](./adr/ADR-0003-federation-portability-contract.md) | What makes a directory a platform-compliant federation (VERSION, CHANGELOG, BUNDLE.manifest, install/start/kill surface) | Federation authors, infra |
| [`adr/ADR-0008-compute-first-novelty.md`](./adr/ADR-0008-compute-first-novelty.md) | Compute-first novelty discovery strategy behind research-foundry | Architects |

## Operations

| Doc | What it covers | Mainly for |
|-----|----------------|------------|
| [`federation-dashboard.md`](./federation-dashboard.md) | The standalone web dashboard: install, tabs, operator controls (promote / demote / evolve / restart / kill) | Operators |
| [`auto-promote.md`](./auto-promote.md) | Unattended tier governance: DMN decision table, fitness signal, acting-floor derivation, operator overrides | Operators, architects |
| [`replay-mode.md`](./replay-mode.md) | Scoring a candidate `.ag` against captured history before deploying it (side-effect-free) | Operators, contributors |
| [`cross-fed-memo.md`](./cross-fed-memo.md) | The `cross-fed:*` shared memo namespace — how proven methods cross-pollinate between federations on one host | Architects, operators |

## Patterns and worked examples

| Doc | What it covers | Mainly for |
|-----|----------------|------------|
| [`ag-first-guide.md`](./ag-first-guide.md) | Building a federation `.ag`-first: which side of the `exec sh` boundary a decision belongs on, what moving work in costs, and the runtime traps that pass `agentis commit` | Federation authors; anyone writing `.ag` |
| [`federation-patterns.md`](./federation-patterns.md) | Sketches of federations beyond the coder workflow (data-ops, support-triage, monitoring-ops, …) | Architects, federation authors |
| [`feedback-loop.md`](./feedback-loop.md) | The reality-check pattern: how an acting agent learns its suggestion was wrong (required for honest auto-promote fitness) | Agent authors |
| [`dev-apprenticeship-first-task.md`](./dev-apprenticeship-first-task.md) | Pre-commitment contract + post-run triage for the federation's first real end-to-end task | End users, operators |
