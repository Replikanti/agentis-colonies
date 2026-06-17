# Prospector Colony

> Part of the [Dark Factory](../) federation.

A **monitoring-target qualifier**. Four cooperating agents take a list of
candidate EVM protocols and decide which ones are worth standing up the
[`monitor`](../monitor/) colony on — and why. The colony is **non-custodial /
read-only**: every agent only **reads** public source / ABI and on-chain state
via `cast` / a verified-source explorer — it never signs a transaction and never
touches funds.

The qualification verdict is a **fact** (a source/ABI read + a read-only
on-chain value read + a deterministic comparison), never an LLM opinion. A
candidate **qualifies** as a monitoring target only when all three hard gates
hold:

1. **verified-source** — the contract exposes a real, readable source / ABI
   surface;
2. **DeFi value-invariants** — that surface matches a known value-invariant
   family (lending / vault-4626 / AMM / stablecoin / perps / staking / bridge);
3. **value-floor** — its read-only on-chain value clears a configured floor.

The handoff to the `monitor` colony is the per-target **dossier**: for a
qualifying target it names the value-invariant family and the **suggested
invariant to watch** (phrased in the `monitor`'s `MONITOR_INV_*` terms), so an
operator can stand up the monitor on exactly the right property.

## Agents

| Agent | Role | Output |
|-------|------|--------|
| `intake` | Ingests the candidate protocol list (`PROSPECTOR_CANDIDATES`, `<address>\|<chain>[\|<metadata>]` per line) onto the blackboard; validates + dedups each candidate | `prospector:candidates`, `prospector:intake` (tier-gated) |
| `source-classifier` | Reads each candidate's verified source / ABI surface and classifies whether it exposes a DeFi value-invariant family (the monitorability gate) | `prospector:classified:<addr>`, `prospector:classified` (tier-gated) |
| `value-scorer` | Reads a read-only on-chain value proxy (balance / TVL via `cast call`) for each candidate and decides whether it clears the value floor | `prospector:value:<addr>`, `prospector:value` (tier-gated) |
| `coordinator` | Fuses the three hard gates into a ranked qualification verdict and writes the per-target dossier + ranked index (the monitor handoff) | `prospector:qualified:<addr>`, `prospector:qualified` (tier-gated) |

Each agent runs as its own `agentis daemon`. The agents coordinate via durable
blackboard memos (the `prospector:*` namespace); the coordinator reads the
per-candidate verdicts the classifier and value-scorer posted and fuses them.

```mermaid
flowchart LR
    ENV[PROSPECTOR_CANDIDATES<br/>address + chain + metadata] --> IN[intake]
    IN -->|prospector:candidates| SC[source-classifier]
    IN -->|prospector:candidates| VS[value-scorer]
    SRC[cast interface / explorer<br/>read-only] --> SC
    CHAIN[cast call / balance<br/>read-only] --> VS
    SC -->|prospector:classified:addr| CO[coordinator]
    VS -->|prospector:value:addr| CO
    CO -->|prospector:qualified<br/>ranked dossier| MON[monitor colony<br/>handoff]
```

## Confidence-tiered qualification (ADR-0001)

Every agent makes ONE `tier()` call per tick and branches once. The tier gates
**publication only** — the verdict is computed identically at every tier:

- `shadow` / `dormant` — score only: classify / score + `learn()` a baseline and
  write the per-target dossier; **no publish on the bus**.
- `propose` — emit a **draft** shortlist on the bus for review.
- `review-gated` / `autonomous` — publish the **ranked dossier** index directly,
  once the qualifier has proven reliable.

This is the false-positive control: a fresh agent seeded at `shadow` learns the
candidate set's normal shape before its shortlist is ever published, and
auto-promotion lifts it as its verdicts prove out.

## Hand off to the `monitor` colony

A qualifying target's dossier (`prospector:qualified:<addr>`) carries the matched
value-invariant family and a **suggested invariant to watch**, mapped to the
`monitor` colony's invariant contract. For example, a `vault-4626` target's
dossier suggests `totalAssets() ge totalSupply() (share solvency)` — which an
operator wires into the monitor as:

```bash
# from the prospector dossier for a qualifying vault-4626 target:
export MONITOR_TARGET=0xVAULT
export MONITOR_INV_LHS_SIG="totalAssets()"
export MONITOR_INV_RHS_SIG="totalSupply()"
export MONITOR_INV_REL="ge"
export MONITOR_CAST="$(command -v cast)" MONITOR_RPC_URL=https://rpc.example/x
../monitor/scripts/start-colony.sh
```

The prospector decides **which** targets and **which** property; the
[`monitor`](../monitor/README.md) colony does the continuous watching, and the
[`monitor` live-watch runtime](../monitor/README.md) can derive the full
invariant set for the chosen target.

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Export the candidate list + the read tools (see the env contract below), then
   start the colony:
   ```bash
   export PROSPECTOR_CANDIDATES="0xVAULT|1|some vault
   0xPOOL|1|some pool"
   export PROSPECTOR_CAST="$(command -v cast)" PROSPECTOR_RPC_URL=https://rpc.example/x
   export PROSPECTOR_VALUE_SIG="totalAssets()" PROSPECTOR_VALUE_FLOOR=1000000000000000000000
   export PROSPECTOR_ABI_CMD='cast interface --rpc-url "$PROSPECTOR_RPC_URL" "$PROSPECTOR_ADDR" 2>/dev/null'
   ./scripts/start-colony.sh
   ```

3. Add each `PROSPECTOR_*` var (plus `PROSPECTOR_ADDR` / `PROSPECTOR_CHAIN`, which
   `source-classifier` exports into its reader) to `exec.env_passthrough` in
   `.agentis/config` so the sandboxed `exec sh` readers can see them. With no
   reader configured, a candidate classifies `no-read` and is never qualified.

dark-factory is a non-forge federation (`forge.type = "none"`); no forge
credentials are required.

## Environment contract

Inputs are passed via the environment (all optional). Export them before
launching, and add each to `exec.env_passthrough` in `.agentis/config` so the
sandboxed `exec sh` readers can read them. With no reader configured a candidate
classifies `no-read` and is never falsely qualified.

| Var | Meaning | Default |
|-----|---------|---------|
| `PROSPECTOR_CANDIDATES` | Newline-joined `<address>\|<chain>[\|<metadata>]` list of candidate protocols. address = `0x` + 40 hex; chain = EVM chain id; metadata optional. | unset (no candidates) |
| `PROSPECTOR_ABI_CMD` | Reader command template that, given a candidate's address + chain (exported as `PROSPECTOR_ADDR` / `PROSPECTOR_CHAIN`, never interpolated), prints the verified function-signature surface, one signature per line (e.g. `cast interface`, or a keyless Sourcify ABI fetch). | unset (observe only) |
| `PROSPECTOR_CAST` | Absolute path to the `cast` binary (foundry), the value-read tool. | unset (observe only) |
| `PROSPECTOR_RPC_URL` | Chain RPC endpoint `cast` reads from (read-only). | unset (observe only) |
| `PROSPECTOR_VALUE_SIG` | `cast call` signature returning the value proxy (e.g. `totalAssets()`); `""` ⇒ use the contract's native balance (`cast balance`). | unset (native balance) |
| `PROSPECTOR_VALUE_FLOOR` | Minimum value (decimal integer, in the read's own units) a candidate must hold to clear the floor. | `0` (any non-zero read clears) |

## Status

Experimental, lint-clean foundation. This colony ships the scaffold
(`prospector/{agents,config,scripts,README.md}`, `[forge] type = "none"` per
ADR-0003), the four agents, and the confidence-tiered qualification pipeline in
[#871](https://github.com/Replikanti/agentis-colonies/issues/871). Follow-ups
(out of scope here): off-chain qualification signals (web-research scoring), and
freshness via deploy-time indexing. The colony is **read-only**, **never** signs
or touches funds, and uses **only** `cast call` / `cast balance` (never
`cast send` / a key / a write-RPC).
