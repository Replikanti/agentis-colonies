# mETH Protocol — clean, rigorous negative

> We hunted and found nothing payable. This is not a security audit and not a safety claim.

- **Program:** [immunefi.com/bug-bounty/mETH](https://immunefi.com/bug-bounty/mETH/) — max
  bounty $500,000 (Critical), $100,000 (High), $5,000 flat (Medium); PoC required, KYC not
  required; 10 assets in scope.
- **Chain:** Ethereum mainnet (Mantle's ETH liquid-staking protocol).
- **Repo:** [`mantle-lsp/contracts`](https://github.com/mantle-lsp/contracts). Source was
  pulled **keylessly** via the Blockscout API against the implementation behind each
  ERC1967 proxy and rebuilt locally (`forge build` green — 45 files, solc 0.8.20, 1,000,000
  optimizer runs, Shanghai target).
- **Hunt date:** 2026-09-05.

## Scope hunted

`src` (`Staking` + `METH`) and `src_interfaces`.

## Candidates raised and refuted

**Breadth pass: 5–6 candidates, 0 verified, 1 refuted, 2 dropped below the program's pay
floor, 0 errored.** The two dropped leads were Medium-severity (`C13`) leads on
`METH.mint` / `METH._transfer` — below this program's payable floor, so not pursued.

## Invariants fuzzed — mostly held, one FINDING refuted

Deep-hunt (STAGE 4.5) covered `Staking` (C6 accounting, C5 access), `METH` (C6, C5), and a
composable general-solvency lens across `Staking` + `METH` (the backing / exchange-rate
identity). Result: `Staking` C6 clean, `METH` C6 clean, the composable general-solvency
lens **held** (640 seconds of harness generation, no unprivileged witness found). `METH` C5
produced one FINDING, which the adversarial refute gate killed:

- **`installBlockList → setSanction → forceMintSanctioned`** — every step in the generated
  witness is role-gated (`ADD_BLOCK_LIST_CONTRACT_ROLE`, `MINTER_ROLE` for the real
  `forceMint`), and the witness's own named function `forceMintSanctioned` does not exist
  in source at all — it was a fabricated function name, auto-refuted by the invariant-mode
  refute gate.

Three of the fuzzed invariants are re-derived here as public, on-chain checks:

| Invariant | LHS | RHS | Relation |
|---|---|---|---|
| `backing-par` — every mETH is backed by at least 1 ETH under protocol control (composable Staking+mETH solvency; this is the invariant that held) | `Staking.totalControlled()` | `mETH.totalSupply()` | `>=` |
| `supply-cap` — the governance-set mint cap is never exceeded | `mETH.totalSupply()` | `Staking.maximumMETHSupply()` | `<=` |
| `unstake-queue-solvency` — ETH paid out to unstakers never exceeds ETH allocated to the claim queue | `UnstakeRequestsManager.allocatedETHForClaims()` | `UnstakeRequestsManager.totalClaimed()` | `>=` |

In-scope addresses used above (verified 2026-09-06, read-only):

| Contract | Address |
|---|---|
| Staking (core) | `0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f` |
| mETH token | `0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa` |
| UnstakeRequestsManager | `0x38fDF7b489316e03eD8754ad339cb5c4483FDcf9` |
| Oracle | `0x8735049F496727f824Cc0f2B174d826f5c408192` |

Reproduce the backing invariant yourself against a public RPC:

```bash
cast call 0xe3cBd06D7dadB3F4e6557bAb7EdD924CD1489E8f "totalControlled()(uint256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
cast call 0xd5F7838F5C461fefF7FE49ea5ebaF7728bB0ADfa "totalSupply()(uint256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
# totalControlled should be >= mETH.totalSupply (both 18-decimal wei)
```

## What was NOT covered

- The two Medium (`C13`) blocklist/transfer-restriction leads on `METH.mint` /
  `METH._transfer` were dropped as below this program's payable floor, not refuted on the
  merits — they remain unresolved leads, just out of scope for a payable finding here.
- Only `src` and `src_interfaces` were mapped; other repo directories were not zoned for
  this hunt.
- Point-in-time result against the code as hunted on 2026-09-05; no continuous monitoring.
