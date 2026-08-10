# Corpus bug-class coverage / rarity map

First cut of the taxonomy-driven lens program (issue #1787, epic #1782). Every High-severity
ground-truth finding in the run corpus is tagged with its `bug-taxonomy.md` class (C1–C18),
its rarity (`found-by` = how many contest watsons found it; lower = rarer = more money), and
the deep-hunt lens's current status on it.

**Method.** Tags are assigned from each finding's `truth.tsv` signature against the C1–C18
definitions in `../../auditor/bug-taxonomy.md`. Lens status is read from the live A/B runs
(2026-07-23, `deep-hunt-ab.sh --live --ensemble-candidates 3`). This is human-checkable, not
auto-derived; refine as `tag-bug-classes` (a #1787 deliverable) is built.

**Lens-status legend**
- `CAUGHT` — the invariant lens FINDINGs it (witness-verified).
- `REDUNDANT` — lens finds it but breadth already caught it (no net recall).
- `OUT-OF-CLASS` — no lens template expresses this class yet.
- `HARNESS-ERROR` — lens's generated harness did not compile/run on this target (harness-robustness gap, not template gap).
- `REFUTED` — the lens GENERATES a candidate at the GT location, but the adversarial refute gate (#1699) drops it (candidate not airtight enough to survive a hostile read) — a verify-gate gap, not a coverage or generation gap.
- `IN-FLIGHT` — a lens class for this is being built.

> **Measured lens status is from the #1879 re-run (2026-08-10), not the 2026-07-23 A/B.** Ruler: `--zone-depth-cells 4`, semantic judge `--judge-min-confidence 60`, GT-equivalence off, scoped to the 3 lens-target notional zones. Result: **notional rare recall 1/14 (was 0/14)** — **H-9 CAUGHT by C23** (judge conf 93; the same candidate was REFUTED under the C22 framing, CONFIRMED under C23), **H-8 REFUTED** (C22 fired + generated PT/sUSDe-accounting candidates, but not H-8's oracle SY==YT bug, and the refute gate dropped them), **M-12 REFUTED** (C2 candidate at `PendlePTOracle._getPTRate`, dropped). The bottleneck for the rest is the refute gate, not coverage/generation. NB: this run required restoring the #1877/#1881 `experience.enabled` regression on `run-discovery.sh` + `run-refute.sh`, which otherwise zeroes the whole pipeline.

## Per-finding tags (5 of 8 contests run so far)

| Contest | Finding | fb | Class | Lens status |
|---------|---------|----|-------|-------------|
| yieldoor | H-1 liquidation fee decimal handling | 7 | C9 decimals | OUT-OF-CLASS |
| yieldoor | **H-2 ticks from slot0** | **1** | **C2 oracle** | IN-FLIGHT (#1783) |
| yieldoor | **H-3 uint16 overflow → DoS** | **1** | **C17 slot / C16 liveness** | OUT-OF-CLASS (#1784) |
| yieldoor | H-4 isLiquidateable base calc | 3 | C10 liquidation | OUT-OF-CLASS |
| yieldoor | H-5 high-leverage vs liquidation | 24 | C10 liquidation | OUT-OF-CLASS |
| yieldoor | H-6 tick param in collectFees | 19 | C1 vault / C6 | OUT-OF-CLASS |
| yieldoor | H-7 uninitialized feeRecipient | 16 | C5 access | OUT-OF-CLASS |
| plaza | H-1 LevETH redeem rate | 18 | C1 vault accounting | REDUNDANT |
| plaza | H-2 anyone can get funds (redeem) | 5 | C1 vault accounting | REDUNDANT |
| plaza | H-3 transferReserveToAuction revert | 60 | C16 liveness | OUT-OF-CLASS |
| plaza | H-4 BondOracleAdapter loss | 3 | C2 oracle | IN-FLIGHT (#1783) |
| plaza | H-5 leverage avoids fees before auction | 3 | C18 auction-grief | OUT-OF-CLASS |
| plaza | H-6 flash-loan claim all coupons | 28 | C12 MEV / C8 | OUT-OF-CLASS |
| plaza | H-7 funds locked in BalancerRouter | 12 | C15 integration | OUT-OF-CLASS |
| plaza | H-8 fee charged on current balance | 41 | C6 accounting | OUT-OF-CLASS |
| plaza | H-9 COLLATERAL_THRESHOLD 125 vs 120 | 4 | C10 config | OUT-OF-CLASS |
| plaza | H-10 sell BondToken by manipulating collat | 8 | C1 / C10 | OUT-OF-CLASS |
| plaza | H-11 incorrect price representation | 5 | C2 oracle / C9 | IN-FLIGHT (#1783) |
| yearn | **H-1 steal 25% of first depositor** | **1** | **C11 first-depositor** | **CAUGHT** ✅ |
| yearn | **H-2 deposit after keeper loss report** | **2** | C1 / C6 accounting-timing | OUT-OF-CLASS |
| notional | H-1 cross-contract reentrancy theft | 4 | C8 reentrancy | OUT-OF-CLASS |
| notional | **H-2 drain Morpho by inflating** | **1** | **C2 oracle / C15** | IN-FLIGHT (#1783) |
| notional | H-3 overwithdrawal via batch | 10 | C6 / C4 | OUT-OF-CLASS |
| notional | **H-4 borrow direct, collateral mispriced** | **2** | **C2 oracle** | IN-FLIGHT (#1783) |
| notional | H-5 migrateRewardPool storage design | 5 | C17 slot-overwrite | OUT-OF-CLASS |
| notional | H-6 DoS DineroWithdrawRequestManager | 7 | C16 liveness | OUT-OF-CLASS |
| notional | H-7 claimAccountRewards missing param check | 5 | C5 access | OUT-OF-CLASS |
| notional | **H-8 Pendle SY 1:1 assumption** | **2** | **C22 x-protocol unit** | REFUTED (#1879) |
| notional | **H-9 hardcoded useEth in remove_liquidity** | **2** | **C23 hardcoded-param** | **CAUGHT** ✅ (#1879) |
| notional | **H-10 TradeType change to steal** | **2** | **C5 access** | OUT-OF-CLASS (#1785) |
| notional | H-11 missing slippage PT redemption | 11 | C12 slippage | OUT-OF-CLASS |
| mellow | H-1 checkSignatures duplicate signers | 44 | C7 signature | OUT-OF-CLASS |
| mellow | H-2 RedeemQueue accounting mismatch | 16 | C4 queue / C6 | HARNESS-ERROR |
| mellow | H-3 withdraw native tokens hooks | 15 | C16 / C15 | OUT-OF-CLASS |
| mellow | H-4 protocol fee multiple accrual | 9 | C6 / C2 | OUT-OF-CLASS |
| mellow | H-5 performance fee calc | 5 | C6 accounting | OUT-OF-CLASS |
| mellow | **H-6 redeems avoid fees** | **3** | C18 / C6 | HARNESS-ERROR |

## Class coverage summary (across the 5 run contests)

| Class | Highs | rarest fb | Lens status | Priority note |
|-------|-------|-----------|-------------|---------------|
| C11 first-depositor / inflation | 1 | 1 | **CAUGHT** ✅ | shipped (#1778) — the proof the approach works |
| C1 vault / share accounting | 6 | 2 | CAUGHT (redundant w/ breadth) | breadth already strong here |
| C2 oracle integrity | 5 | 1 | IN-FLIGHT (#1783) | 5 Highs incl. 2 rare (fb=1) — highest ROI |
| C5 access control | 3 | 2 | OPEN (#1785) | 3 Highs incl. notional H-10 (fb=2 rare) |
| C6 accounting / rounding | 7 | 3 | OUT-OF-CLASS | large but mostly non-rare; breadth-adjacent |
| C15 integration-seam | 1 | 2 | OUT-OF-CLASS | plaza H-7; notional H-8/H-9 retagged to C22/C23 (#1879) |
| C22 x-protocol asset/unit | 1 | 2 | REFUTED (#1879) | notional H-8 (fb=2): C22 fired + generated PT/sUSDe candidates, refute gate dropped them |
| C23 hardcoded ext-param | 1 | 2 | **CAUGHT** ✅ (#1879) | notional H-9 (fb=2): judge conf 93 — first C22/C23-family catch, end-to-end |
| C16 liveness / stuck-state | 4 | 3 | OPEN (#1784 overlaps) | DoS class |
| C17 index/slot-overwrite | 2 | 1 | OPEN (#1784) | yieldoor H-3 (fb=1 rare, overflow) |
| C10 liquidation / redemption | 4 | 3 | OUT-OF-CLASS | |
| C8 reentrancy | 2 | 4 | OUT-OF-CLASS | classic critical class, not yet rare here |
| C12 slippage / MEV | 3 | 5 | OUT-OF-CLASS | |
| C9 decimals / scaling | 2 | 7 | OUT-OF-CLASS | |
| C18 auction-griefing | 2 | 3 | OUT-OF-CLASS | |
| C4 withdrawal queue | 2 | 16 | HARNESS-ERROR (mellow) | harness-robustness blocked |
| C7 signature / replay | 1 | 44 | OUT-OF-CLASS | non-rare |

Not yet observed in the run subset: C3 (cross-chain), C13 (pause/freeze), C14 (fork-delta).
Three corpus contests remain to tag: dodo, crestal, symm.

## Prioritization (rarity × corpus-occurrence × not-yet-caught)

1. **C2 oracle** — 5 corpus Highs, 2 rare (fb=1: yieldoor H-2, notional H-2). **In flight (#1783).** Transfer pair: derive on notional H-4 → hold out yieldoor H-2 (or plaza H-4).
2. **C23 hardcoded ext-param** — notional H-9 (fb=2) **CAUGHT end-to-end (#1879)**, judge conf 93; the pattern (hardcoded `useEth`/`dexId`/pool-index on an external call) should transfer to other integration-adapter targets. **C22 x-protocol unit** (notional H-8, fb=2) fires + generates but is **REFUTED** — the remaining gap there is candidate airtightness vs. the refute gate, not coverage or generation.
3. **C5 access control** — notional H-10 (fb=2 rare) + H-7 + yieldoor H-7. Issue #1785.
4. **C17 slot-overwrite / overflow** — yieldoor H-3 (fb=1), notional H-5. Issue #1784.

Each class is declared functional only after the **transfer test** (#1787): derive on one contract of the class → the lens must also FINDING on a *different* corpus contract of the same class. `HARNESS-ERROR` rows (mellow C4) are tracked on the separate harness-robustness axis, not the template axis.
