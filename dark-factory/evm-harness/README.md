# Dark Factory — EVM harness (revm)

The EVM counterpart of [`solana-harness-anchor`](../solana-harness-anchor). Drives a Solidity
target through the **real EVM** (`revm` — the Rust EVM that powers Foundry and reth), fully
offline, and gates the verdict on the same **two-sided contract** the colony uses:

- `CONTROL OK:` — the honest flow works on this exact target (the harness is not rigged).
- `INVARIANT VIOLATED:` — the exploit breaks a safety/economic invariant → `exit 101` → VERIFIED.

## Why this exists

Code4rena wound down (May 2026) and **Immunefi absorbed its bounty programs and researchers**
(see agentis-core#857). Immunefi is a continuous-bounty model — **first valid PoC wins, no
duplicate dilution**, severity-tier payouts — and it requires a **reproducible PoC** to pay. That
is exactly what this harness produces, and the EVM funnel is ~5–10× the Solana contest funnel.
Building it was the highest portfolio-EV lever identified in the backtests; this is that build.

## Calibration result (real revm execution, solc 0.8.26)

Class: **reentrancy** (checks-effects-interactions violation — the EVM canonical, and a
high-paying low-duplicate class). Two-sided gate over `revm`:

| Target | Verdict | Evidence |
|---|---|---|
| `ReentrancyVaultInsecure.sol` | **VERIFIED** | CONTROL OK + `INVARIANT VIOLATED`: attacker stakes **1 ETH**, ends holding **6 ETH** (stole 5), vault drained 5 ETH → 0. exit 101 |
| `ReentrancyVaultSecure.sol` | **SAFE** | CONTROL OK + `invariant held`: reentrant `withdraw()` reverts (balance zeroed first), attacker nets 0, vault retains 5 ETH |

**True-positive 1/1, false-VERIFIED 0** — same calibration bar as the Solana
`sealevel-scorecard.md` (3/3, 0 false-VERIFIED).

## Layout

```
evm-harness/
  Cargo.toml  Cargo.lock  .cargo/config.toml   # revm 14 crate, offline-pinned
  src/bin/poc.rs                               # the two-sided harness (revm)
  contracts/
    ReentrancyVaultInsecure.sol                # the audited target (vuln)
    ReentrancyVaultSecure.sol                  # the fixed control
    Attacker.sol                               # reentrancy exploit contract
    bin/*.bin                                  # derived creation bytecode (regenerate via compile.js)
  compile.js                                   # solcjs -> creation bytecode
```

## Run

```bash
# one-time: compile the Solidity targets to bytecode (needs node + `npm i solc`)
npm i solc && node compile.js

# one-time host-side dependency warm (network ON), then builds run offline in the sandbox
cargo fetch

# run the two-sided gate against a target (vault .bin, attacker .bin)
cargo run --bin poc -- contracts/bin/ReentrancyVaultInsecure.bin contracts/bin/Attacker.bin
#   insecure -> "INVARIANT VIOLATED" + exit 101 ; secure -> "invariant held" + exit 0
```

The PoC takes the vault creation-bytecode as `argv[1]` and the attacker bytecode as `argv[2]`,
so a real audit points `argv[1]` at the in-scope contract's compiled bytecode (host-side solc,
mirroring the Solana V4 RPC-snapshot-is-host-side split). Submission stays **human-gated** — the
harness verifies; a human submits to Immunefi.

## Status / next steps (tracked in #857)

Foundation proven end-to-end on reentrancy. To turn it into a live Immunefi engine:
1. Broaden the target ingestion: point `compile.js` at an in-scope repo (solc standard-JSON over
   the whole source tree), not three hand-written contracts.
2. Add EVM detection classes to the colony detector (reentrancy, access-control, unchecked-call,
   oracle/AMM rounding) — the low-duplicate profile Immunefi pays for.
3. Wire `auditor.ag` to select this harness when the target is Solidity (chain dispatch), the
   same way `SOLANA_ANCHOR_HARNESS_DIR` selects the Anchor harness today.
4. Optional: a Foundry (`forge test`) emitter for reviewer-facing PoCs — `forge` was unreachable
   in this sandbox (GitHub release API blocked), so the engine is revm-native; a forge wrapper is
   purely a presentation layer over the same exploit.
