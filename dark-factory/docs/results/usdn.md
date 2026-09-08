# USDN (SmarDex) — clean, rigorous negative

> We hunted and found nothing payable. This is not a security audit and not a safety claim.

- **Program:** [immunefi.com/bug-bounty/usdn](https://immunefi.com/bug-bounty/usdn/) — max
  bounty $50,000 (Critical), $5,000 (High), $3,000 flat (Medium), $1,000 flat (Low); PoC
  required, KYC not required; 9 assets in scope.
- **Chain:** Ethereum mainnet.
- **Repo:** [`SmarDex-Ecosystem/usdn-contracts`](https://github.com/SmarDex-Ecosystem/usdn-contracts).
  Source was pulled **keylessly** from Sourcify against the implementation behind the
  `UsdnProtocol` ERC1967 proxy and rebuilt locally (`forge build` green) rather than from a
  local checkout — anyone can repeat this by resolving the same proxy's implementation slot
  and pulling its verified source from Sourcify.
- **Hunt date:** 2026-09-05.

## Scope hunted

`src_UsdnProtocol` (the facade + upgrade proxy), `src_UsdnProtocol_libraries` (p1–p5), and
`src_libraries` (math + pending-action queue) — 6 of 7 mapped zones.

## Candidates raised and refuted

**Breadth pass: 0 candidates** across the zones covered — no lead reached the adversarial
refute gate on this target.

## Invariants fuzzed — all held

Deep-hunt (STAGE 4.5, stateful-invariant lens) covered `UsdnProtocolActions` (C2
oracle-integrity, C5 access), `UsdnProtocolImpl` (C2, C5), `UsdnProtocolLong` (C2, C5 — the
liquidation path, re-run under a resumed deep-hunt pass), `UsdnProtocolCoreLibrary` (C16
liveness), `UsdnProtocolConstantsLibrary` (C16), and `UsdnProtocolVaultLibrary` (C2). All
cells reported **CLEAN** — 0 findings, 0 needs-PoC. This was the first end-to-end clean run
of the keyless-Sourcify source pipeline, with zero infrastructure failures across the whole
hunt.

Three of the fuzzed invariants are re-derived here as public, on-chain checks:

| Invariant | LHS | RHS | Relation |
|---|---|---|---|
| `long-expo` — total long exposure never falls below the long side's own balance (every open position keeps leverage >= 1x) | `UsdnProtocol.getTotalExpo()` | `UsdnProtocol.getBalanceLong()` | `>=` |
| `asset-custody` — the vault side's book balance is physically held by the protocol | `wstETH.balanceOf(UsdnProtocol)` | `UsdnProtocol.getBalanceVault()` | `>=` |
| `wusdn-backing` — every wrapped USDN share is backed by USDN shares the wrapper actually holds | `wUSDN.totalUsdnShares()` | `USDN.sharesOf(wUSDN)` | `<=` |

In-scope addresses used above (verified 2026-09-06, read-only):

| Contract | Address |
|---|---|
| UsdnProtocol (ERC1967 proxy) | `0x656cb8c6d154aad29d8771384089be5b5141f01a` |
| USDN token | `0xde17a000ba631c5d7c2bd9fb692efea52d90dee2` |
| wUSDN | `0x99999999999999cc837c997b882957dafdcb1af9` |
| wstETH (protocol asset) | `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0` |

Reproduce the custody invariant yourself against a public RPC:

```bash
cast call 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0 "balanceOf(address)(uint256)" \
  0x656cb8c6d154aad29d8771384089be5b5141f01a \
  --rpc-url https://ethereum-rpc.publicnode.com
cast call 0x656cb8c6d154aad29d8771384089be5b5141f01a "getBalanceVault()(uint256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
# wstETH balance should be >= getBalanceVault() (the strict form also adds getBalanceLong()
# and the pending protocol fee — see the watch-spec notes)
```

## What was NOT covered

- One of the 7 mapped zones was not part of this breadth pass.
- `sUSDN` (an Enzyme v4 vault holding USDN, listed on the Immunefi scope page) is not a
  SmarDex-authored contract and was not part of this hunt's zone map.
- Point-in-time result against the code as hunted on 2026-09-05; no continuous monitoring.
