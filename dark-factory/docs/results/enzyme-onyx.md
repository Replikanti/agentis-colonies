# Enzyme Onyx — clean, rigorous negative

> We hunted and found nothing payable. This is not a security audit and not a safety claim.

- **Program:** [immunefi.com/bug-bounty/enzyme-onyx](https://immunefi.com/bug-bounty/enzyme-onyx/) —
  max bounty $200,000 (Critical, 10% of funds at risk, minimum $20,000), $20,000 (High),
  $5,000 (Medium); PoC required, KYC not required; 44 assets in scope.
- **Chain:** Ethereum mainnet (Onyx release v1 is also live on Arbitrum, Base, BSC,
  MegaETH, Plume, and Rayls).
- **Repo:** [`enzymefinance/protocol-onyx`](https://github.com/enzymefinance/protocol-onyx)
  @ `7b48d24` (the 2026-07-30 issuance batch) — a hardened target: ChainSecurity-audited,
  trusted-operator design.
- **Hunt date:** 2026-08-26.

## Scope hunted

15 of 15 mapped zones: the issuance deposit and redeem handlers, the value/valuation
handler, shares, five fee modules, Chainlink-ACE hooks and extractors, transfer validators,
and position trackers. (The breadth pass needed a resume after a laptop crash and one
transient tooling fault on the fees zones; both were cleared on re-hunt with no scope
reduction.)

## Candidates raised and refuted

**Breadth pass: 3 candidates, all refuted:**

1. **Two non-atomic `setAssetRate` sequences** — the attack path relies on calling
   `setAssetRate` in isolation, but this is a trusted-operator action, an atomic
   `setAssetRatesThenUpdateShareValue` entrypoint exists for the same purpose, and the
   staleness guard reads `lastShareValueTimestamp`, which plain `setAssetRate` never
   touches — the described sequence does not create the staleness window it claims.
2. **`AccountERC20Tracker.init` front-run** — the real deployer, `SharesDeployer`,
   initializes every tracker atomically via encoded `initData` in the same transaction as
   deployment; the front-run window the lead described does not exist in the actual
   deployment path (the lead's own control run conceded this).

**Deep-hunt breadth (STAGE 4.5, `--deep-hunt-only`, 13 targets): 6 CLEAN, 4
HARNESS_ERROR (base/helper contracts not custody-relevant and not standalone-instantiable
outside the full fund stack — a harness-robustness gap, not a finding), 3 FINDING, all
refuted:**

1. **`DepositQueue` "donateToFund"** — the harness's own action was fabricated: Onyx prices
   funds from a stored valuation update, not from `balanceOf`, so a bare token donation
   does not move NAV the way the candidate assumed. (This mirrors a risk documented in the
   protocol's own ChainSecurity report, CS-ONYX-011.)
2. **`RedeemQueue`** — the described path needs an admin-only `executeRedeemRequests` call
   combined with `setAssetRate`; async pricing at execution time is the protocol's
   documented design, not a bug.
3. **`ValuationHandler` (C2 oracle)** — the harness transacted at a stale price only
   because it bypassed the real `maxSharePriceStaleness` guard; against the real guard the
   path does not exist.

All four value-custody zones — deposit, redeem, value, and shares — received real verdicts
(clean or refuted-with-mechanism), not harness errors. 0 of 6 total candidates (3 breadth +
3 deep) verified.

## Invariants fuzzed — all held

The largest live fund (Markov Funding Rate Arb Vault, "mkFRA," ~$547k NAV at the time of
sampling) and the second-largest USDC fund (BONDL USDC Yield Vault I) both had their
position-tracker-vs-real-balance identity fuzzed and held; the composable value-conservation
lens across `ValuationHandler`/ERC7540 issuance queues cleared with no unprivileged witness.

Three of the fuzzed invariants are re-derived here as public, on-chain checks:

| Invariant | LHS | RHS | Relation |
|---|---|---|---|
| `tracker-backing-mkfra` — the position value the valuation handler aggregates is backed by USDC the fund actually holds | `USDC.balanceOf(mkFRA) × 1e12` | `AccountERC20Tracker.getPositionValue()` | `>=` |
| `share-price-floor-mkfra` — the stored NAV per share never records an unpaged >5% drawdown | `mkFRA.sharePrice()` | `0.95e18` | `>=` |
| `tracker-backing-bondl-usdc` — the same backing identity on the second-largest USDC fund | `USDC.balanceOf(bUSDCY1) × 1e12` | `AccountERC20Tracker.getPositionValue()` | `>=` |

In-scope addresses used above (verified 2026-09-06, read-only; Onyx prices from a stored
valuation, so the on-chain-attestable part is the tracker-vs-real-balance identity, not the
NAV itself):

| Contract | Address |
|---|---|
| Markov Funding Rate Arb Vault (mkFRA) Shares | `0x64423193CFdB25bF87b0fc63aFEC2575c61f6bc0` |
| mkFRA AccountERC20Tracker | `0x019bE25B88284Da1053f729e42b4b521cc3D9aA6` |
| BONDL USDC Yield Vault I (bUSDCY1) Shares | `0x895b715705492d9385A5BaC217098fDbE77b61af` |
| bUSDCY1 AccountERC20Tracker | `0xfC25f8cf347a4005ba840b18eCcA1CE73f3a01a4` |
| USDC | `0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48` |

Reproduce the mkFRA backing invariant yourself against a public RPC:

```bash
cast call 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 "balanceOf(address)(uint256)" \
  0x64423193CFdB25bF87b0fc63aFEC2575c61f6bc0 \
  --rpc-url https://ethereum-rpc.publicnode.com
cast call 0x019bE25B88284Da1053f729e42b4b521cc3D9aA6 "getPositionValue()(int256)" \
  --rpc-url https://ethereum-rpc.publicnode.com
# scale the USDC balance (6-decimal) by 1e12 before comparing to the 18-decimal tracker value
```

## What was NOT covered

- 4 of 13 deep-hunt targets errored out on harness instantiation (base/helper contracts not
  meant to be standalone) — they are non-custody surfaces, but were not independently
  fuzzed.
- Onyx prices shares from a stored, admin-attested valuation rather than live balances by
  design; this hunt checked the tracker-vs-real-balance identity and a NAV drawdown band,
  not the correctness of the admin's off-chain valuation inputs themselves.
- The handler-registry, `SharesFactory` beacon, and each fund's fee-handler registry are
  intended for a separate governance-change watcher, not this hunt's invariant set.
- Point-in-time result against commit `7b48d24`; the 20+ other live Ethereum funds deployed
  through the same `SharesFactory` were not individually invariant-fuzzed (only mkFRA and
  bUSDCY1 were).
