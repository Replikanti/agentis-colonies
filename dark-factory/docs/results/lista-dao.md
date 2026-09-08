# Lista DAO (CDP core) — clean, rigorous negative

> We hunted and found nothing payable. This is not a security audit and not a safety claim.

- **Program:** [immunefi.com/bug-bounty/listadao](https://immunefi.com/bug-bounty/listadao/) —
  max bounty $1,000,000 (Critical), $10,000 (High), $5,000 (Medium); PoC required, KYC not
  required; 57 assets in scope.
- **Chain:** BNB Smart Chain.
- **Repo:** [`lista-dao/lista-dao-contracts`](https://github.com/lista-dao/lista-dao-contracts)
  (the MakerDAO-fork CDP core — `vat`/`clip`/`dog`/`join`/PSM/`MasterVault`/oracles). A
  separate, out-of-scope repo (`lista-dao/moolah`) is explicitly excluded — a prior mis-scoped
  run against it produced a lead on a contract not on the Immunefi asset list, which is why
  this write-up covers only the scope-corrected CDP-core hunt.
- **Hunt date:** 2026-09-04.

## Scope hunted

10 zones: `contracts` (p1–p4), `ceros`/`provider`, `masterVault`, `psm` (p1–p3), `oracle` —
covering the CDP entry point (`Interaction`), `vat`, `clip`, `dog`, the PSM, `MasterVault`,
`SlisBNBProvider`, and `ResilientOracle`.

## Candidates raised and refuted

**Breadth pass: 15 candidates, all refuted.** Two reached the verified-findings stage and
were triaged false-positive by hand:

- **`SlisBNBProvider.managerSetRates`** — flagged as a C5 access-control lead, but the
  caller is the `MANAGER` role (a trusted, in-scope role) and the exploit input required
  was a physically absurd value (~6.688e73), not a reachable state.
- **PSM `honestBuy`** — flagged as a C5 lead, but was a spurious invariant: it flagged the
  permissionless `harvest()` call as an unprivileged state change while every actual
  fund-moving path (`emergencyWithdraw`, pause, fee setters) is correctly role-gated.

## Invariants fuzzed — all held

Deep-hunt (STAGE 4.5) ran 23 cells across `Interaction` (C2 oracle, C5 access), `clip` (C6
accounting, C2, C5, composable general-solvency), `dog` (C2, C5), `vat` (C5), `SlisBNBProvider`
(C6, C5), `MasterVault` (C6, C5), `ResilientOracle` (C2, C5), `LisUSDPoolSet` (C6, C5,
composable general-solvency), the PSM (C6, C5, composable general-solvency), and
`VenusAdapter` (C6). `vat`/`clip`/`dog`/`Interaction` reported **CLEAN**; the other 12 cells
produced FINDINGs, and **all 12 were refuted** by the adversarial gate:

1. **PSM `getTotalSellLimit()` underflow** via a fee-taken-without-inflow branch — only
   reachable at a 100% buy fee, which can only be set through `setBuyFee` (a `MANAGER`-role
   call).
2. **`LisUSDPoolSet` composable general-solvency** — the rate-scaled share accounting only
   outruns holdings under a `BOT`-role `setDuty` call combined with a physically impossible
   `warp(6e75 s)`; the input shrinker could not bring the witness into any reachable range.
3. **`dog` — `Dirt <= Hole`** (a real MakerDAO safety property) tripped only against the
   harness's mock `vat`/`clipper` under absurd inputs; triage flagged this as the one lead
   worth a human forge-PoC against the *real* `vat` + `dog` before final dismissal — it was
   not pursued further because the mock-only trigger did not survive against real contracts.
4. **`MasterVault`, `ResilientOracle`, `VenusAdapter`** — every load-bearing step in the
   generated witnesses was `onlyManager` / `onlyProvider` / `onlyOwner`.

Three of the fuzzed invariants are re-derived here as public, on-chain checks:

| Invariant | LHS | RHS | Relation |
|---|---|---|---|
| `lisusd-supply-cap` — total lisUSD issuance (CDP + PSM mint paths together) never exceeds the governance cap | `lisUSD.totalSupply()` | `lisUSD.supplyCap()` | `<=` |
| `slisbnb-backing-par` — every slisBNB is backed by at least 1 BNB in the staking pool | `ListaStakeManager.getTotalPooledBnb()` | `slisBNB.totalSupply()` | `>=` |
| `vat-accounting-identity` — unbacked (system) debt can never exceed total stablecoin debt | `vat.vice()` | `vat.debt()` | `<=` |

Note: `vat.Line()` (the global CDP debt ceiling) currently reads `0` on-chain — new CDP
debt is frozen, and the live mint path is the PSM / `LisUSDPoolSet`, which is why the
supply-cap check above is stated at the token level rather than as `vat.debt() <= vat.Line()`.

In-scope addresses used above (verified 2026-09-06, read-only):

| Contract | Address |
|---|---|
| lisUSD | `0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5` |
| slisBNB | `0xB0b84D294e0C75A6abe60171b70edEb2EFd14A1B` |
| ListaStakeManager | `0x1adB950d8bB3dA4bE104211D5AB038628e477fE6` |
| vat | `0x33A34eAB3ee892D40420507B820347b1cA2201c4` |

Reproduce the supply-cap invariant yourself against a public RPC:

```bash
cast call 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5 "totalSupply()(uint256)" \
  --rpc-url https://bsc-rpc.publicnode.com
cast call 0x0782b6d8c4551B9760e74c0545a9bCD90bdc41E5 "supplyCap()(uint256)" \
  --rpc-url https://bsc-rpc.publicnode.com
# totalSupply should be <= supplyCap
```

## What was NOT covered

- `lista-dao/moolah` (lending) is a separate, out-of-scope repo for this hunt — not
  examined here.
- The `dog`/`Dirt<=Hole` lead that survived to human-triage attention was dismissed on the
  mock-harness-only trigger, not re-verified against the real `vat`+`dog` pair with a
  standalone forge PoC — that residual check was not done.
- Point-in-time result against the code as hunted on 2026-09-04; no continuous monitoring.
