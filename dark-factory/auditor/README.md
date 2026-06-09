# Auditor Colony

> Part of the [Dark Factory](../) federation.

The autonomous Solana/Anchor bounty auditor. A single `.ag` file
([`agents/auditor.ag`](./agents/auditor.ag)) wires four cooperating agents over
the substrate emit/listen bus as a one-shot `agentis go` pipeline: ingest a
program → detect a finding → synthesize a two-sided PoC → validate through the
real Solana SVM offline → write a human-gated Immunefi report.

## Agents

| Agent | Role | Output |
|-------|------|--------|
| `reconn` | Dependency recon + DAG distillation of handler sub-graphs (content-addressed dedup cache); audit-once verdict/blacklist lookup | `guard:target` / `guard:th` / `guard:cached`, `tracker:target` |
| `tracker` | Dataflow trace: does a signer/authority guard dominate the state-mutation sink? | `synth:trace` |
| `guard` | Reuse the cached verdict on a DAG hit; else run structural detection (MissingSignerCheck / IntegerOverflow) | `synth:class` / `synth:target` / `synth:th` / `synth:hit` |
| `synthesis` | Generate + compile + run a two-sided PoC, validate (`CONTROL OK:` + `INVARIANT VIOLATED:`), cache the verdict, write the report | `report.md`, `submission:pending` (tier-gated) |

All four agents live in the one `auditor.ag` file and run in a single
`agentis go` invocation; there is no per-agent daemon.

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. (One-time, network ON) build the offline Solana toolchain from the
   federation root:
   ```bash
   bash ../setup-solana-toolchain.sh [WORKDIR]
   ```
   This warm-builds the harness dependency graph so the PoC compiles + runs
   fully offline. See [`../solana-harness/README.md`](../solana-harness/README.md).

3. Run one audit (one-shot pipeline):
   ```bash
   ./scripts/start-colony.sh
   ```
   The report and PoC artifacts land under `<rundir>/.agentis/sandbox/`.

dark-factory is a non-forge federation (`forge.type = "none"`); no forge
credentials are required.

## Environment contract

The audit inputs are passed via the environment (all optional). Export them
before launching, and add each to `exec.env_passthrough` in `.agentis/config`
so the sandboxed `exec sh` can read them.

| Var | Meaning | Default |
|-----|---------|---------|
| `SOLANA_HARNESS_DIR` | Warm offline `solana-program-test` harness dir (staged by `setup-solana-toolchain.sh`). When set, PoCs run through the **real** Solana SVM; otherwise a std-only `rustc` harness is used. | unset (std-only) |
| `BOUNTY_TARGET` | Path to the in-scope program to audit. | embedded vulnerable vault |
| `BOUNTY_POC` | Path to a human-supplied PoC candidate (gated by the same two-sided `assess()` check as a generated one). | unset (generate) |
| `BOUNTY_SNAPSHOT` | Path to a host-side RPC account dump, replayed offline. | embedded frozen state |

## Tiers and human-gated submission

The colony follows the [ADR-0001](../../doc/adr/ADR-0001-confidence-tiers.md)
tier contract via `tier("auditor")`. A verified finding is ALWAYS written as a
standardized Immunefi-shaped `report.md`. The submission marker is tier-gated:

- at `review-gated` / `autonomous` tier the colony stages the finding by
  writing a `pending_human_review` submission marker and emitting
  `submission:pending`;
- at `propose` / `shadow` / `dormant` it writes the report only.

In every case **submission is human-gated**: the colony NEVER posts to a bounty
platform. Staging a finding means a human reviewer reads the report and submits
it to Immunefi / Code4rena / Sherlock manually as a separate, explicit action.
