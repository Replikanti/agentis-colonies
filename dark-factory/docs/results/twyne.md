# Twyne — clean, rigorous negative

> We hunted and found nothing payable. This is not a security audit and not a safety claim.

- **Program:** [immunefi.com/bug-bounty/twyne](https://immunefi.com/bug-bounty/twyne/) — max
  bounty $50,000 (Critical), $10,000 (High); PoC required, KYC not required; 16 assets in
  scope.
- **Chain:** Ethereum mainnet.
- **Repo / commit:** [`0xTwyne/twyne-contracts-v1`](https://github.com/0xTwyne/twyne-contracts-v1) @ `ac8e546`
  (single-auditor history — Electisec, 7 prior reviews — which is exactly the profile
  where a fresh hunt has the best odds of finding something an earlier, narrower review
  missed; it did not here).
- **Hunt dates:** 2026-09-04 (core) and 2026-09-05 (`src/operators` — the flashloan-leverage
  operator zone, breadth-hunted separately).

## Scope hunted

- Core: `src_twyne` (p1/p2), `src_TwyneFactory`, `src_Periphery` — the collateral-vault
  factory, `CollateralVaultBase`, `AaveV3CollateralVault`, `EulerCollateralVault`, and
  `VaultManager`.
- Operators: `src_operators` (flashloan-leverage operators), breadth-hunted with a 4-cell
  discovery pass.

## Candidates raised and refuted

- **Breadth pass (core): 0 candidates.** No lead reached the refute gate — the discovery
  agent's cell-by-cell read of the factory/vault/manager surface did not surface an
  attack-path sketch worth adjudicating.
- **Breadth pass (operators): 0 candidates** across 4 discovery cells.

With zero candidates raised, there was nothing for the adversarial refute gate to kill on
this target — the depth record for Twyne is entirely in the invariant-fuzz stage below.

## Invariants fuzzed — all held

Severity-first deep-hunt (STAGE 4.5) ran a stateful-invariant lens over every value-custody
contract: `CollateralVaultFactory` (C5 — access control), `CollateralVaultBase` (C6
accounting, C2 oracle, C5 access), `AaveV3CollateralVault` (C6, C2, C5), `EulerCollateralVault`
(C6, C2, C5), the composable general-solvency lens across `CollateralVaultBase` +
`AaveV3CollateralVault`, and `VaultManager` (C2 value-conservation, C5 privileged-state on
the LTV / liquidation-buffer parameters). All cells reported **CLEAN** — no unprivileged
witness broke any derived invariant across the fuzz budget.

Three of those invariants are re-derived here as public, on-chain checks anyone can run:

| Invariant | LHS | RHS | Relation |
|---|---|---|---|
| `awsteth-icv-par` — the aWSTETH intermediate credit vault's share price never drops below 1.0 (no socialised bad debt) | `aWSTETH-ICV.totalAssets()` | `aWSTETH-ICV.totalSupply()` | `>=` |
| `awsteth-icv-custody` — the wrapped-aToken the vault says it holds idle is physically there | `wstataWSTETH.balanceOf(aWSTETH-ICV)` | `aWSTETH-ICV.cash()` | `>=` |
| `ewsteth-icv-par` — same par invariant on the Euler-backed wstETH credit vault | `eWSTETH-ICV.totalAssets()` | `eWSTETH-ICV.totalSupply()` | `>=` |

In-scope addresses used above (verified 2026-09-06, read-only):

| Contract | Address |
|---|---|
| aWSTETH intermediate credit vault (largest) | `0x75029a47f28550C93Ad5A3BbD2d9b5315204B561` |
| eWSTETH intermediate credit vault | `0x7613D202Af490c3d1cE1873b0a7022a34E89815f` |
| wstataWSTETH (Aave aToken wrapper, in scope) | `0xFaBA8f777996C0C28fe9e6554D84cB30ca3e1881` |
| GenericFactory (Euler-Vault-Kit beacon) | `0xB5Eb1d005e389Bef38161691E2083b4d86FF647a` |

Reproduce the first invariant yourself against a public RPC:

```bash
cast call 0x75029a47f28550C93Ad5A3BbD2d9b5315204B561 "totalAssets()(uint256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
cast call 0x75029a47f28550C93Ad5A3BbD2d9b5315204B561 "totalSupply()(uint256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
# totalAssets should be >= totalSupply (both 18-decimal)
```

## What was NOT covered

- No new invariant has been derived for the operator (flashloan-leverage) zone yet — it
  cleared breadth (0 candidates) but has not been through the stateful-invariant fuzz
  stage.
- The hunt covers the code as of commit `ac8e546`; any code shipped after that commit is
  unexamined.
- This is a point-in-time result, not continuous monitoring — the invariants above can be
  re-checked at any later block, but nothing here re-runs automatically.
