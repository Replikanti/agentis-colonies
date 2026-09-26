# Corpus bug-class coverage / rarity map

First cut of the taxonomy-driven lens program (issue #1787, epic #1782). Every High-severity
ground-truth finding in the run corpus is tagged with its `bug-taxonomy.md` class (C1–C18),
its rarity (`found-by` = how many contest watsons found it; lower = rarer = more money), and
the deep-hunt lens's current status on it.

**Method.** Tags are assigned from each finding's `truth.tsv` signature against the C1–C18
definitions in `../../auditor/bug-taxonomy.md`. Lens status is read from the live A/B runs
(2026-07-23, `deep-hunt-ab.sh --live --ensemble-candidates 3`). This is human-checkable, not
auto-derived; refine as `tag-bug-classes` (a #1787 deliverable) is built.

> **⚠️ in-distribution (#2231).** Until 2026-09-16 the lens (`../../auditor/bug-taxonomy.md`) carried the
> corpus contests' own GT ids and mechanisms in its `seen:` lines, and `gen-briefs.sh` folded them into the
> frozen briefs. Every `CAUGHT`/recall claim below that was measured on `notional`, `yieldoor`, `yearn-ybold`,
> `crestal` or `plaza` (the `dev` contests in `corpus.tsv`) is therefore **in-distribution** — inflated where
> the mechanism was given, suppressed where the brief's known-findings clause excluded the row. The C11 and
> C23 `CAUGHT` rows are marked accordingly. `dodo`, `mellow` and `symm` are the held-out contests; recall
> claims belong there. The removed contest text is parked verbatim under "Contest examples" at the bottom of
> this file.

**Lens-status legend**
- `CAUGHT` — the invariant lens FINDINGs it (witness-verified).
- `REDUNDANT` — lens finds it but breadth already caught it (no net recall).
- `OUT-OF-CLASS` — no lens template expresses this class yet.
- `HARNESS-ERROR` — lens's generated harness did not compile/run on this target (harness-robustness gap, not template gap).
- `REFUTED` — the lens GENERATES a candidate at the GT location, but the adversarial refute gate (#1699) drops it (candidate not airtight enough to survive a hostile read) — a verify-gate gap, not a coverage or generation gap.
- `IN-FLIGHT` — a lens class for this is being built.

> **Measured lens status is from the #1879 re-run (2026-08-10), not the 2026-07-23 A/B.** Ruler: `--zone-depth-cells 4`, semantic judge `--judge-min-confidence 60`, GT-equivalence off, scoped to the 3 lens-target notional zones. Result: **notional rare recall 1/14 (was 0/14)** — **H-9 CAUGHT by C23** (judge conf 93; the same candidate was REFUTED under the C22 framing, CONFIRMED under C23), **H-8 REFUTED** (C22 fired + generated PT/sUSDe-accounting candidates, but not H-8's oracle SY==YT bug, and the refute gate dropped them), **M-12 REFUTED** (C2 candidate at `PendlePTOracle._getPTRate`, dropped). The bottleneck for the rest is the refute gate, not coverage/generation. NB: this run required restoring the #1877/#1881 `experience.enabled` regression on `run-discovery.sh` + `run-refute.sh`, which otherwise zeroes the whole pipeline.

### Refute-gate false-negative measurement (#1886, 2026-08-10)

A fresh live re-run scoped to the same 3 zones (same ruler; effective per-zone depth **4**, semantic judge min-conf 60, GT-equivalence off) to characterize the refute-gate false-negatives per anchor. Durable, scrubbed artifacts (verified_findings, judge-log, all 29 per-candidate refute rationales): [`runs/1886-notional-refute-fn/`](runs/1886-notional-refute-fn/). Headline: **rare recall 2/14** (29 candidates → 2 REAL; overall 3/37; the confidence gate @60 dropped 1 MATCH at conf 55, costing 1 row — #1841). This run's per-anchor picture is **not** the "all-refute-gate" read #1879's single row suggested:

| anchor | GT class | generated? | refute | credited | cause |
|---|---|---|---|---|---|
| H-9 hardcoded `useEth` | C23/**C22** | yes (4 sibling framings) | 1 REAL + 3 REFUTED | **HIT H-9** | **CAUGHT but framing-fragile** — refuter killed 3 of 4 framings as "privileged config"; one precise framing survived (CONFIRMED under C22 here, vs C23 in #1879) |
| H-8 Pendle SY 1:1 | C22 | **no** | — | miss | **generation miss** (was generated in #1879) |
| H-4 Morpho direct-borrow | C21 | yes | REFUTED | miss | **refute false-negative** — refuter rebutted a different attack path (deposit re-entry) than the GT mechanism (direct Morpho borrow) |
| M-12 `_getPTRate` decimals | C2 | **no** | — | miss | **generation miss** |

Plus two non-anchor confirms: **M-2** (consensus — `Ethena._finalizeCooldown` zero-payout, REAL) and **M-22** (rare — credited from the H-9 lead, mechanically adjacent WETH/Curve loss).

**Conclusion (updates the #1879 read):** the refute-gate false-negative is real (H-4) but is **not the dominant loss** — of the 4 anchors, generation miss (H-8, M-12) cost as many as the refute gate (H-4), and the one catch (H-9) was framing-fragile. So the store row for H-8/M-12 is a **generation/coverage** gap this run, not a refute-gate `REFUTED` — the #1879 `REFUTED` tags for those two are stochastic-run-specific, not stable. The candidate-side half (H-4 refute-FN + H-9 framing-fragility) is what **#1887** (refuter→hunter knowledge transfer) targets; the generation-miss half is upstream of the refute gate and #1887 does not address it.

### Refuter→hunter constraint transfer (#1887, 2026-08-11)

Held-out A/B of the #1887 refuter→hunter channel: a constraint corpus **derived on `notional`** (27 rows, frozen at `8e5476c`) injected into a **`yieldoor`** hunt (treatment) vs. the same hunt with no corpus (control). Durable, scrubbed artifacts (both arms' scorecards, verified_findings, judge-logs, GT): [`runs/1887-yieldoor-refute-transfer/`](runs/1887-yieldoor-refute-transfer/). Ruler (identical both arms): `--zone-depth-cells 4 --total-depth-cells 36`, semantic judge `--judge-min-confidence 60`, GT-equivalence off, `--backend flat-cyborg`. One run per arm (stochastic).

**The result is class-mismatch-bounded, not a transfer verdict.** The corpus carries constraints only in C15/C21/C23/C2/C22 (the classes `notional`'s refutations exercised). `yieldoor` hunts C20/C19/C10/C15/C6/C5/C11/C14, and its rare money-tier Highs are **H-2 (C20 slot0 tick-centering)** and **H-3 (C19 uint16-overflow DoS)** — classes with **zero corpus constraints**. The hunter injects class-filtered, so overlap is **C15 only** (and `yieldoor` has no C15 GT). The treatment therefore had no reachable rare-bug surface, and the primary number cannot move by construction.

| bucket | OFF (control) | ON (treatment) | Δ |
|---|---|---|---|
| **rare(1-2) — primary** | **1/8** | **1/8** | **0** |
| overall | 6/17 | 3/17 | −3 |
| High | 4/7 | 2/7 | −2 |
| consensus(9+) | 4/6 | 1/6 | −3 |
| confirm rate | 64.3% | 63.2% | −1.1 |
| cells | 19 | 24 | +5 |

**Verdict:** primary rare recall **flat, Δ=0** — no transfer, structurally impossible here. **Goodhart gate not triggered** (confirm rate did not rise). Overall/consensus came out lower on this single run, but it is confounded and NOT attributed as treatment harm: **cell-count parity failed** (24 vs 19 — the plan voids the strict comparison on unequal counts; the ON arm's 12 confirmed leads collapsed onto 3 distinct GT rows vs OFF's 9→6), plus n=1 stochasticity. **Outcome: a structurally-bounded null** — the mechanism imports+injects correctly (verified: 27 rows in the run store), but derivation↔held-out class profiles are disjoint. Default stays off, corpus stays checked in, #1887 closes on this negative. The lever is a **multi-target / class-broad corpus** so a held-out target's money classes are covered → **#1895**.

### Multi-target constraint corpus (#1895)

The #1887 null was a **class non-overlap**, not a mechanism failure, so the lever is a corpus derived across a
class-broad set of targets and a **precheck that refuses to spend compute on a null-by-construction pairing**.
The precheck is `refute-corpus-coverage.sh` — an offline gate that computes the triple intersection

```
{ ∪ derivation-corpus classes }  ∩  { held-out hunted classes }  ∩  { held-out rare(1-2) GT classes }
```

and prints `COVERAGE-GATE: GO` **iff** it is non-empty (and therefore carries at least one class with a
`found-by ≤ 2` GT row on the held-out — the only classes on which the primary metric can move). Otherwise it
prints `NO-GO`, names the empty leg, and exits non-zero. All three legs are cheap and checked-in / archived:
derivation classes from the refute-derivation manifests (`cut -d'|' -f2`), the held-out's hunted classes from
field 4 of a `map-zones` `scope.tsv`, and its rare-GT classes from a class-tagged `truth.tsv` (`found-by ≤ 2`
rows) — the same human-checkable `bug-taxonomy.md` assignment this table records, materialised into a column.
The corpus is still built the #1887 way — multiple `--in` TSVs into `refute-to-knowledge.sh`, which sums
`samples` on a shared `(class, sentence)`, keeps distinct sentences separate, and stays byte-stable modulo
`created_ms` and independent of `--in` order (asserted by `demo-refute-feedback.sh` 3e/3f) — so every #1887
invariant (frozen/checked-in, class-keyed injection, byte-identical prompt when a class has no constraints,
determinism, default-off) is preserved for free; multi-target is *just more `--in`*, not a code change.

**The C2 transfer axis.** Across the 8 corpus contests the only class carrying a `found-by ≤ 2` money bug on
**more than one** target is **C2 (oracle integrity)** — notional (H-2 fb1, H-4 fb2), yieldoor (H-2 fb1), plaza
(H-4, H-11). Every other rare class is target-idiosyncratic (C19/C20 only on yieldoor, C11 only on yearn,
C22/C23 only on notional). So C2 is the one axis on which a derived-here → measured-there transfer test is not
null by construction; the recommended config derives C2 from notional (archived, free) + plaza (fresh) and
holds out yieldoor's oracle zone.

**The C2/C20 granularity crux (the load-bearing empirical fact).** Whether that config actually clears the gate
hinges on how yieldoor's oracle/slot0 zone resolves: this table tags H-2 as **C2 oracle** (coarse), but the
#1887 `map-zones` pass produced the granular **C20 (Uniswap-V3 slot0 tick-centering)**, and H-3 as **C19
(uint16 overflow)** rather than C17. The probe run on the archived data confirms the split is decisive:

| Candidate config (held-out = yieldoor) | oracle-zone tag | TRIPLE | Gate |
|---|---|---|---|
| notional-only corpus | granular (C20/C19) | ∅ (overlap is C15 only, no rare GT) | **NO-GO** — reproduces #1887 |
| notional + plaza(C2 predicted) | granular (C20/C19) | ∅ (rare GT C20/C19 in no derivation source) | **NO-GO** |
| notional + plaza(C2 predicted) | coarse (C2) | {C2} | GO |

Under the granular reality the map-zones run actually produced, yieldoor is **unreachable** — its rare Highs
are C20/C19 and no *other* corpus target produces C20/C19 candidates. The probe therefore (correctly) refuses
yieldoor, and the documented fallback is **held-out = notional**, with C2 derived from **plaza + mellow** (both
fresh, higher compute; notional's fb1/fb2 C2 GT becomes the held-out ground truth). The decision is made before
compute, not after. The fresh plaza/mellow derivation and the held-out A/B are gated on a human/orchestrator
seeing a `GO`, and the A/B result (rare(1-2) OFF vs ON, the Goodhart confirm-rate fail-gate, cell-count parity)
will be appended here under the #1887 burn rule (frozen corpus + this coverage report committed before either
arm).

## Per-finding tags (5 of 8 contests run so far)

| Contest | Finding | fb | Class | Lens status |
|---------|---------|----|-------|-------------|
| yieldoor | H-1 liquidation fee decimal handling | 7 | C9 decimals | OUT-OF-CLASS |
| yieldoor | **H-2 ticks from slot0** | **1** | **C2 oracle** | IN-FLIGHT (#1783) |
| yieldoor | **H-3 uint16 overflow → DoS** | **1** | **C19 narrow-overflow** | IN-FLIGHT (#2111) |
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
| yearn | **H-1 steal 25% of first depositor** | **1** | **C11 first-depositor** | **CAUGHT** ✅ `in-distribution` (#2231) |
| yearn | **H-2 deposit after keeper loss report** | **2** | C1 / C6 accounting-timing | OUT-OF-CLASS |
| notional | H-1 cross-contract reentrancy theft | 4 | C8 reentrancy | OUT-OF-CLASS |
| notional | **H-2 drain Morpho by inflating** | **1** | **C2 oracle / C15** | IN-FLIGHT (#1783) |
| notional | H-3 overwithdrawal via batch | 10 | C6 / C4 | OUT-OF-CLASS |
| notional | **H-4 borrow direct, collateral mispriced** | **2** | **C2 oracle** | IN-FLIGHT (#1783) |
| notional | H-5 migrateRewardPool storage design | 5 | C17 slot-overwrite | OUT-OF-CLASS |
| notional | H-6 DoS DineroWithdrawRequestManager | 7 | C16 liveness | OUT-OF-CLASS |
| notional | H-7 claimAccountRewards missing param check | 5 | C5 access | OUT-OF-CLASS |
| notional | **H-8 Pendle SY 1:1 assumption** | **2** | **C22 x-protocol unit** | REFUTED (#1879) |
| notional | **H-9 hardcoded useEth in remove_liquidity** | **2** | **C23 hardcoded-param** | **CAUGHT** ✅ (#1879) `in-distribution` (#2231) |
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
| C11 first-depositor / inflation | 1 | 1 | **CAUGHT** ✅ `in-distribution` | shipped (#1778) — the proof the approach works; the catch is on a `dev` contest whose GT mechanism was in the lens (#2231) |
| C1 vault / share accounting | 6 | 2 | CAUGHT (redundant w/ breadth) | breadth already strong here |
| C2 oracle integrity | 5 | 1 | IN-FLIGHT (#1783) | 5 Highs incl. 2 rare (fb=1) — highest ROI |
| C5 access control | 3 | 2 | OPEN (#1785) | 3 Highs incl. notional H-10 (fb=2 rare) |
| C6 accounting / rounding | 7 | 3 | OUT-OF-CLASS | large but mostly non-rare; breadth-adjacent |
| C15 integration-seam | 1 | 2 | OUT-OF-CLASS | plaza H-7; notional H-8/H-9 retagged to C22/C23 (#1879) |
| C22 x-protocol asset/unit | 1 | 2 | REFUTED (#1879) | notional H-8 (fb=2): C22 fired + generated PT/sUSDe candidates, refute gate dropped them |
| C23 hardcoded ext-param | 1 | 2 | **CAUGHT** ✅ (#1879) `in-distribution` | notional H-9 (fb=2): judge conf 93 — first C22/C23-family catch, end-to-end; `dev` contest, GT ids were in the lens when it was measured (#2231) |
| C24 stale state assumption | 3 | 1 | IN-FLIGHT (#2218) | 3 Mediums, all generation misses in #2213: yieldoor M-2, notional M-8, notional M-16 — class + zone-mapper route landed, recall unmeasured until M2 |
| C25 empty distribution / zero participation | 2 | 1 | IN-FLIGHT (#2245) | design twin dev notional M-8 (in-distribution), test twin held-out superfluid-locker M-2 — class + zone-mapper route landed, recall unmeasured until the held-out run |
| C26 admitted parameter / unenforced bound | 3 | 1 | IN-FLIGHT (#2245) | design twins dev notional M-3/M-5/M-22 (in-distribution), test twin held-out malda M-5/M-10/M-12 — class + zone-mapper route landed, recall unmeasured until the held-out run; the second held-out cluster (superfluid-locker M-3/M-5) is a recorded routing MISS |
| C27 variant coverage gap | — | — | IN-FLIGHT (#2265) | designed from two dev targets by role only (no contest text in the lens or in this row) — class + single-zone zone-mapper route landed, recall unmeasured until the sealed reserve-set run |
| C16 liveness / stuck-state | 4 | 3 | OPEN (#1784 overlaps) | DoS class |
| C17 index/slot-overwrite | 1 | 5 | OPEN (#1784) | notional H-5 (H-3 retagged to C19 #2111) |
| C19 narrow-int overflow / downcast | 1 | 1 | IN-FLIGHT (#2111) | yieldoor H-3 (fb=1 rare) — liveness lens + zone-mapper C19 net wired |
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
4. **C19 narrow-int overflow / downcast** — yieldoor H-3 (fb=1 rare, `uint16` observation-counter overflow → `checkPoolActivity` DoS). **In flight (#2111)**: C19 reuses the "liveness" generation lens (WRAP-BOUNDARY + NARROW-INT-NO-WRAP, now + a DOWNCAST-TRUNCATION bullet) via a one-line `class_to_keyword` map, and a deterministic `contains_narrow_int_signal()` zone-mapper backstop force-includes C19. **C17 slot-overwrite** — notional H-5 remains under #1784.

Each class is declared functional only after the **transfer test** (#1787): derive on one contract of the class → the lens must also FINDING on a *different* corpus contract of the same class. `HARNESS-ERROR` rows (mellow C4) are tracked on the separate harness-robustness axis, not the template axis.

### State-assumption lens (#2218)

The #2213 generation misses cluster into one root — a value written, snapshotted or DEFINED at touchpoint A
is consumed at touchpoint B as if nothing changed in between — and **C24** (`auditor/bug-taxonomy.md`) is the
class for it, with a deterministic `zone-mapper.ag` route so it reaches the zone that owns the touchpoint
rather than only the zone the breadth LLM happened to label. Unlike C1–C23 it targets an INVARIANT the
analysis never verifies, so its guard rails (the four-part required-evidence rule, the
C2/C9/C22/C23/C8/C21/C6/C10 `NOT this class` list, the two named sub-shapes) do the work a tactical class
gets from its code tells.

**Target rows** — all three are `found-by` 1 (the rarest tier) and all three were pure GENERATION misses in
the #2213 A/B, in both arms:

| target row | mechanism | #2213 status |
|---|---|---|
| yieldoor M-2 | the accrual applies a borrow rate captured at the last update across the whole elapsed interval, and only re-prices it after | generation miss (never named, both arms) |
| notional M-8 | an emission accrual divides by a supply whose floor is defined in a different contract in scope | generation miss (never named, both arms) |
| notional M-16 | a pending-request state blocks the position owner's remedy while a third party's path stays live against it | generation miss (never named, both arms) |

**Measured offline fan-out of the C24 net** on the two frozen #2213 base maps, driving the shipped net
directly (no LLM) over each zone's WHOLE file set:

| contest | zones | C24 fires on | carrying net |
|---|---|---|---|
| yieldoor | 4 | 2 — `src_libraries` (holds M-2's accrual), `src__p1` | accrual-update |
| notional | 9 | 5 — `src` (M-16's request gate), `src_rewards` (M-8's emission accrual), `src_staking`, `src_routers`, `src_single_sided_lp` | emission-per-supply, request-gated-solvency, accrual-update |

**7 of 13 zones, i.e. +1 cell per firing zone — it does not fire on every zone** (6 stay silent: yieldoor
`src__p2`, `src_types`; notional `src_oracles`, `src_proxy`, `src_utils`, `src_withdraws`).

Of the two zones that carry the **CAUGHT C23** row, only `src_oracles` stays silent; `src_single_sided_lp`
FIRES (a request/cooldown predicate plus a `_preLiquidation(` consumer in the same contract). So "the C23
zones stay silent" is **not** a property of this net and is not claimed — the C23 catch is argued safe by the
#2191-carried no-regression gate in M2, not by construction. The three zones beyond the three target rows are
an accepted, disclosed cost: each owns an interest-accrual or request-gated touchpoint, so each is
mechanism-plausible rather than noise.

The count is **input-dependent**, which is worth recording for anyone re-measuring: over the function-SLICED
blob the mapper is actually handed on these maps (`scope_files` — a >120-LOC contract cut to its top 16
functions) the count is **6 of 13**, because `src_single_sided_lp`'s slice keeps the request predicate and
drops the `_preLiquidation(` consumer. 7 of 13 is the number quoted here: the slice is a prompt-budget
artefact of one particular map, the whole-file reading is the net's own selectivity.

**M2's rehunt zones are unaffected either way** — the measurement stages `C24` into `scope.tsv` by hand on
`src_libraries` / `src_rewards` / `src` and never re-maps, so neither reading changes the arms.

**Status: IN-FLIGHT — recall is UNMEASURED.** M1 ships the class, the route and the offline guards only.
Whether C24 recovers any of the three rows is #2218 M2: a zone-restricted `--rehunt-gaps` A/B on the SAME
frozen bases (control = staged map untouched, treatment = `,C24` appended to that zone's `scope.tsv` row),
2 arms x 2 repeats per row first, scored by an operator read of the cell logs, with the #2191-carried
no-regression gate (every GT row the control arm names stays named; C11/C23 unaffected) blocking a GO
regardless of the delta.

### Zero-participation lens (#2245, iteration 1 of the miss-shape lens program)

#2218 wrote its class from a CLUSTER of misses; #2231's held-out baseline then showed that a lens written as
a general category does not transfer (#2218's own follow-up, 0/7 on held-out). This iteration inverts the
method: **one lens per ONE concrete miss shape, with a dev-corpus twin (the design source, in-distribution)
and a held-out twin (the test)**, measured only on the held-out twin. **C25** (`auditor/bug-taxonomy.md`) is
the class for the ZERO edge of an aggregate participation total, in two named directions — a `require(total >
0)` gate that blocks a legitimate user action on a leg whose allocation weight is legitimately zero, and a
total FLOORED by a virtual/minimum constant so the "no participants, stop distributing" branch is dead while
the emission keeps accruing. A deterministic `zone-mapper.ag` route puts it on the zone that owns the gate or
the denominator rather than only the zone the breadth LLM happened to label.

**The twin pair** — both rows are Mediums and both were generation misses (no cell named the mechanism):

| role | target | mechanism | status |
|---|---|---|---|
| design source (in-distribution, NEVER a recall number) | dev notional | an emission accrual divides by a supply floored by a virtual-shares constant, so the zero branch is dead | generation miss |
| test (the measurement) | held-out superfluid-locker | an exit path reverts while a distribution pool's unit count is zero, although that pool's allocation weight is configured to zero and it is owed nothing | generation miss |

**Measured offline fan-out of the C25 net**, driving the SHIPPED token lists (extracted from
`zone-mapper.ag`, no LLM) over each zone's WHOLE file set across all six frozen maps:

| role | target | zones | C25 fires on | carrying surface |
|---|---|---|---|---|
| dev | notional | 9 | 3 — `src`, `src_oracles`, `src_rewards` (the design row's emission accrual) | floor constant, division |
| dev | yieldoor | 4 | 2 — `src__p1`, `src__p2` | zero gate, division |
| held-out | superfluid-locker | 4 | 2 — `src__p2` (the test row's exit gate), `src__p1` | zero gate |
| held-out | lend-v2 | 16 | 1 — `src__p3` | zero gate, division |
| held-out | malda | 19 | 2 — `src_mToken__p1`, `src_mToken__p2` | zero gate, division |
| held-out | mellow | 11 | 0 | — |

**10 of 63 zones, +1 cell per firing zone — it does not fire on every zone**, and it is silent on a whole
target (mellow). Both zones the measurement needs are in the firing set. The route is a token net over the
whole-file blob; the count over the function-SLICED blob the mapper is actually handed can differ, and for
the two zones that matter it does not (both gates sit inside functions the frozen `scope.tsv` slices keep).

**Status: IN-FLIGHT — recall is UNMEASURED.** This iteration ships the class, the route and the offline
guards only (`../../demo-zero-total-lens.sh`, wired into `tools/colony-lint.sh`). Whether C25 recovers the
held-out row is the follow-on measurement: inject `C25` into the frozen `scope.tsv` row of the held-out
target's exit zone, 2 repeats against the #2231 control rows, plus ONE dev-zone sanity run reported
explicitly as in-distribution and never as recall.

### Dismissal-rubric lens (#2245, iteration 2 of the miss-shape lens program)

Iteration 1 closed the generation gap on this shape and exposed the next one exactly. **3 of 3 runs reached the
ground-truth mechanism, 0 of 3 kept it**, and every loss applied ONE criterion at one of the two decision points
downstream of generation:

| run | role | reached the GT mechanism? | where it was lost | ground given |
|---|---|---|---|---|
| held-out `src__p2` r1 | test | yes (emitted as a candidate) | refute gate | owner-only intentional guard; no external attacker; the max-period exit bypasses it, so "no funds locked" |
| held-out `src__p2` r2 | test | yes (written out, then SAFE) | hunter dismissal | trusted-owner config trigger; the alternate exit remains; "recoverable liveness degradation, not exploitable by an unprivileged attacker" |
| dev `src_rewards` r1 | dev twin (in-distribution) | yes (written out, then SAFE) | hunter dismissal | dust / stranded-to-void; no attacker gain; blocks no user action |

Reading: what the machine and the contest disagree on is **what counts as a Medium**. Three rows, two contests,
one criterion — *no unprivileged attacker gain and no funds locked ⇒ not a bug* — while the contest rubric
accepted all three as *core functionality broken / value misaccounted under a state the protocol's own validation
admits*, attacker-free and alternative-path-irrelevant. That is a **severity-model** gap, not another mechanism
gap, which is why iteration 2 is NOT a new taxonomy class: a severity judgment is cross-class (it cannot be
routed to a zone) and is not a code shape, so writing it as a class would put the rubric in the lens of ONE class
while every other class kept the old one.

**The lens** is therefore a rubric installed at BOTH decision points (`auditor/agents/hunter.ag` and
`auditor/agents/refuter.ag`, one byte-identical source string), with a **closed ground list**, a structured
output line per side, a bounded named re-ask in each driver, and — on the hunt side only — promotion of a
still-insufficient dismissal to a tier-1 `Medium` candidate:

| half | rubric shapes offered | insufficient grounds (alone AND in any union) | sufficient grounds (each needs its citation) | gate action |
|---|---|---|---|---|
| hunter (`run-discovery.sh`) | valid-input liveness loss / attacker-free misaccounting / alternative-path rule | `no-attacker`, `trusted-config`, `alt-path`, `dust-unquantified` | `guard`, `unreachable`, `no-loss`, `known-issue`, `immaterial-quantified` | `DISMISS\|` line per unreported lead → grouped by location → 1 re-ask naming the open locations → PROMOTE the survivor to `Medium` |
| refute gate (`run-refute.sh`) | identical text | identical list | identical list | `REFUTE-GROUND\|` ahead of a REFUTED verdict → 1 re-ask naming the ground → verdict STAYS `REFUTED`, reason prefixed `rubric-insufficient: `, row in `rubric-dismissals.tsv` |

No mechanical `REFUTED → REAL` flip: escalating a held refutation would make the pre-registered gate
mechanically reachable and therefore meaningless. The knob `SEVERITY_RUBRIC` is independent of
`OPERATIONALIZE_LENS` so the arm stays single-variable, and is default OFF (both prompts byte-identical, both
drivers inert without the agents' own sentinel).

**Pre-registered measurement.** Arm `rubric` = the iteration-1 `c25` arm plus `export SEVERITY_RUBRIC=1` and
nothing else changed. Same frozen held-out base and zone, **×2 repeats**, **GO iff the target row SURVIVES to
`verified_findings.json` in 2/2** — read from the cell logs, the refute verdicts, `rubric-dismissals.tsv` and the
per-cell `dismissals` / `insufficient_dismissals` / `rubric_promoted` keys. Pair-exact scoreboard credit stays
SECONDARY for the reason recorded in iteration 1 (the report link resolves to the config setter, not the bug
site). Dev-twin sanity ×1 each, reported as in-distribution only and never as recall. Also reported per arm:
compliance dosage (`dismissals` per cell — a SAFE reply with zero `DISMISS` lines is non-compliance, and that is
the honest limit of an output gate), the re-ask count, and promotions-confirmed vs promotions-refuted so the
precision cost is measured rather than assumed.

**Status: IN-FLIGHT — recall is UNMEASURED.** This iteration ships the rubric, both output gates, the promotion
rule and the offline guards only (`../../demo-severity-rubric.sh`, wired into `tools/colony-lint.sh`).

### Ground-evidence gate (#2245, iteration 3 of the miss-shape lens program)

Iteration 2 worked where it was applied honestly and exposed the next constraint just as exactly. On the
held-out shape the hunter kept the row **0/2 → 2/2** and the refute gate **0/1 → 1/2** (registered gate 1/2 =
NO-GO, but the first held-out rare row ever to reach `verified_findings.json` on this bench). All three
remaining losses have **ONE shape**: a *sufficient* ground id attached to evidence that does not establish that
ground's definition.

| # | half | ground claimed | what the evidence actually was | reachable mechanically? |
|---|---|---|---|---|
| 1 | refute gate, held-out repeat 1 | `no-loss` | a reachability argument — no path, no zero delta, and it never engaged the state the candidate described | yes: `no-loss` requires the explicit `delta=0:` token + a path, and reachability vocabulary in a `no-loss` line fails (that claim is `unreachable`, which needs its own citation) |
| 2 | hunter, dev twin (accrual shape) | `no-loss` **+** `immaterial-quantified` on one location | no zero delta on the first line; a ratio of internal counters, not a loss amount, on the second | partly: the `no-loss` line fails its contract, the second line passes the FORM check — the location stays open only under the **taint rule**. A semantic mislabel of a quantity is NOT mechanically decidable, and that is stated, not hidden |
| 3 | hunter, dev twin (deployed-config shape) | `no-loss` | a correct on-chain read of the markets as DEPLOYED, for a code-level assumption the code ADMITS in every other configuration | yes: the admitted-vs-deployed rule — deployed-state evidence closes nothing unless the same line cites a validating line that rejects every other admitted state |

**The lens** is therefore not new text but a per-ground EVIDENCE **contract** on the same two output gates,
behind its own knob `GROUND_EVIDENCE=1` (independent of `SEVERITY_RUBRIC`, effective only inside a rubric-ON
cell, so `SEVERITY_RUBRIC=1` alone still renders exactly what the iteration-2 arm was measured with).
`severity_rubric_block()` is FROZEN; every new sentence lives in the new block.

| ground | what the contract demands (checked by ONE shared decider in both drivers) | contract ids it can fail with |
|---|---|---|
| `guard` | a `path:line` that EXISTS in the code the cell was given, whose cited text IS a check | `cite-missing`, `cite-unresolved`, `cite-not-a-guard` |
| `unreachable` | a *validating* line in a constructor/initializer/setter — never a deployment script (deliberately the INVERSE of the #2225 configuration rule: that rule asks what the repo SHIPS, this one what it REFUSES) | `cite-missing`, `cite-unresolved`, `cite-not-validating` |
| `no-loss` | the path AND the literal token `delta=0:<quantity>`; a reachability argument fails | `no-zero-delta`, `cite-missing`, `reachability-as-no-loss` |
| `known-issue` | a quoted fragment of the brief that resolves in the brief | `cite-missing`, `cite-unresolved` |
| `immaterial-quantified` | the literal token `loss=<amount> <unit>` plus a comparison bound in the same units | `unquantified` |
| all of them | ADMITTED IS NOT DEPLOYED — deployed-state evidence closes nothing without a resolved validating citation | `admitted-vs-deployed` |

A contract failure is folded into the EXISTING insufficient path (one bounded re-ask naming `<ground>: <what is
missing>`, hunt-side promotion to a tier-1 `Medium`, gate-side `REFUTED` + `rubric-insufficient: ` + a sidecar
row now carrying the contract id). The one new rule is the **taint rule**: a contract-failing sufficient line
keeps its location open even beside a passing sibling — the single recall-for-precision trade of this iteration,
bounded by the refute gate, the PoC gate, the `Medium` cap and one promotion per location. The checks are
**mechanical only**: citation existence plus a per-ground token shape. Whether a correctly-shaped guard really
settles the lead stays an operator read; an LLM second opinion was deferred rather than added as a second
variable.

**Pre-registered measurement.** Arm `evidence` = the iteration-2 `rubric` arm plus `export GROUND_EVIDENCE=1`,
nothing else changed, at the merge commit of this change. Same frozen held-out base and zone, **×2 repeats**,
**GO iff the target row SURVIVES to `verified_findings.json` in 2/2** — the same registered gate as iteration 2,
now aimed at loss 1. Dev-twin sanity ×1 each for the loss-2 and loss-3 shapes, reported as in-distribution only
and never as recall. Also reported per run: contract failures by ground id and contract id (the per-cell
`contract_failed_dismissals` key and column 5 of `rubric-dismissals.tsv`), re-asks, promotions and how many the
refute gate then confirmed, compliance dosage, and **precision vs iteration 2** as the verified count per zone.
The anti-Goodhart limit is recorded in advance: the contract is a floor on the FORM of the evidence, so a sudden
all-pass with unchanged verdicts is a Goodhart signal, not a win — which is why the readout is per contract id
and the verdict is ground-truth survival, never confirm rate.

**Status: IN-FLIGHT — recall is UNMEASURED.** This iteration ships the contract, both gates, the taint rule and
the offline guards only (`../../demo-severity-rubric.sh`, wired into `tools/colony-lint.sh`).

### Admitted-parameter lens (#2245, iteration 4 of the miss-shape lens program)

Iterations 2-3 closed the JUDGMENT half on one held-out shape; the remaining held-out loss is still
GENERATION. **C26** (`auditor/bug-taxonomy.md`) is the class for a value the design CONSTRAINS entering the
consuming function from OUTSIDE it and never being checked there, in two named directions — an **unenforced
bound / unchecked admitted value** (a route/set id or a numeric bound supplied by a caller, decoded out of a
`bytes` payload, or supplied by a role that is NOT the owner, then forwarded into an external call with no
`require` in that function) and an **unvalidated combination** (two individually valid configuration choices,
an asset representation and a pool/route type, accepted separately and never validated as a PAIR). A
deterministic `zone-mapper.ag` route puts it on the zone that admits the value.

**The twin pair.** The design source is the three in-distribution `dev` rows below; the held-out cluster is
the test.

| role | target | GT rows | mechanism | status |
|---|---|---|---|---|
| design source (in-distribution, NEVER a recall number) | dev notional | M-3, M-5, M-22 | a single-sided strategy cannot trade when the configured pool is a native-ETH pool; minting single-sided is impossible when one route id is configured for redemptions; a wrapped-native asset paired with a pool holding native ETH loses user funds | generation misses |
| test (the measurement) | held-out malda `src_rebalancer_bridges` | M-5, M-10, M-12 | a non-owner role sends to a destination the design does not admit, and forwards an unenforced fee cap and time-to-live into the bridge call | generation misses (#2231; routing was necessary but not sufficient) |
| second cluster (recorded routing MISS) | held-out superfluid-locker `src__p1` | M-3, M-5 | the initial-deposit / buffer arithmetic of a program lifecycle is never examined | generation misses — **the shipped net is silent on this zone** |

**Design discipline (decision 1 at STOP 1, and the reason the numbers look the way they do).** Both halves —
the class TEXT and the mapper NET — are derived ONLY from the dev design rows and from vocabulary this repo's
own class text already ships (C23's route-id / pool-type / coin-index / unit-selection-bool list and its
"magic amount (`minOut = 0`, fixed deadline, fixed slippage)" line; C12's user-supplied-bound class). Every
token in the net carries a `(D)` (dev-attested) or `(T)` (class-text) tag in the source, and
`../../demo-admitted-param-lens.sh` fails if any token is untagged. Candidate tokens that were observable ONLY
in held-out code — `maxFee`, `ttl`, `dstChainId`, `dstEid`, `destinations` and a period/duration declaration
surface — were REJECTED and are pinned absent by the same test. The cost is explicit: the second held-out
cluster above is **not routed** and is scored as a routing MISS for C26, not repaired by hand.

**Measured offline fan-out of the C26 net**, driving the SHIPPED token lists (extracted from `zone-mapper.ag`,
no LLM) over each zone's WHOLE file set across all six frozen maps. Zones are counted after the mechanical
test / interface / mock / script path exclusion `map-zones.sh` applies, which is why the denominator is 62
rather than iteration 1's 63:

| role | target | zones | C26 fires on | carrying surface |
|---|---|---|---|---|
| dev (design source) | notional | 9 | 5 — **`src_single_sided_lp`** (the three design rows), `src`, `src_staking`, `src_withdraws`, `src_rewards` | route id, asset-representation selector, bound |
| dev | yieldoor | 3 | 1 — `src` | bound + non-owner role gate |
| held-out | malda | 19 | 1 — **`src_rebalancer_bridges`** (the test zone) | bound + role gate / decoded payload |
| held-out | superfluid-locker | 4 | 1 — `src__p2` (**not** `src__p1`) | bound + role gate |
| held-out | mellow | 11 | 1 — `src_queues` | bound + decoded payload |
| held-out | lend-v2 | 16 | 0 | — |

**9 of 62 zones (15 %), +1 cell per firing zone** — it fires on the design zone, it is silent on a whole
held-out target, and it is silent on 53 of the 62 zones. The held-out column is an OBSERVATION about
generalisation, not a design target: that the test zone routes on its own (it carries a bound token and a
non-owner role gate) was measured after the token lists were frozen, and no token was added, removed or
reshaped to make a held-out zone fire.

**Status: IN-FLIGHT — recall is UNMEASURED.** This iteration ships the class, the route and the offline guards
only (`../../demo-admitted-param-lens.sh`, wired into `tools/colony-lint.sh`). The pre-registered measurement:
both arms on the iteration-3 ON-baseline (`SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1`); treatment = the test zone
×2 with `C26` staged into its frozen `scope.tsv` row (legitimate only because the shipped net routes that zone
on its own); ON-control = the same zone ×1 with no C26; **GO iff at least ONE of the three test rows survives
to `verified_findings.json` in 2/2 repeats**. The second cluster is reported as a routing MISS and is NOT
staged. `src__p2` and `src_queues` may be run ×1 each as informational generalisation probes; neither enters
the verdict. One dev-twin sanity run on `src_single_sided_lp`, reported as in-distribution and never as recall.

### Parameter audit (#2245, iteration 5 of the miss-shape lens program)

Iteration 4 exposed a GENERATION loss that a class cannot reach: on its zone the cell arrived at the function
that admits the value and never listed that function's arguments — it ruled the function out on other grounds,
and the lead living in one argument was never written down. Three per-shape classes (C24/C25/C26) did not change
that, and a gate-less "check where every argument is bounded" paragraph is the #2213 shape (Delta=+0). So this
iteration writes **no class text, no route, no new judge and no refuter change**. It gives generation the
mechanism that worked on the dismissal side — an emission contract, a deterministic OUTPUT gate on the cell's own
lines, one named re-ask, and promotion of whatever survives — behind its own knob `PARAM_AUDIT=1` (default OFF,
independent of `SEVERITY_RUBRIC`, `GROUND_EVIDENCE` and `OPERATIONALIZE_LENS`).

**Grammar** (hunter.ag, pure-meta; at most 20 ids per cell, arguments of non-view external calls first):

```
PARAM|#<k>|<file:function>|<parameter as written>|<caller|role|config|derived>
PARAM-TRACE|#<k>|bounded-at:<path>:<line>[-<line>]|<the check at that line>
PARAM-TRACE|#<k>|unbounded|<the call or write that consumes it, and what an out-of-range value does there>
```

`#k` is its own id namespace (not `TRACE|`, which would collide with the #2223 OPCHECK pairing); pairing is by id
through the shipped `_check_ids`, never by text.

**The gate** (`run-discovery.sh`, armed ONLY by the honesty-gated `PARAM-AUDIT|` sentinel):

| component | fires when | armed |
|---|---|---|
| G1 uncovered | a function the cell names in its own `DISMISS\|` / `CALLEE-VECTOR\|` lines has no `PARAM\|` line (suspended at the cap) | always |
| G2 unanswered | an id ≤ 20 has no well-formed `PARAM-TRACE\|` of that id, or a `PARAM\|` line has no number | always |
| G3 absent | a no-candidate cell wrote no `PARAM\|` line at all | always |
| G4 open lead | an id ≤ 20 answered `unbounded` (or demoted, below) with no `DISMISS\|` at that function naming the parameter or `#k` | only with `SEVERITY-RUBRIC\|` too |

**Bound contract** (`_param_bound_ok`, strict — STOP-1 decision 3): the cited range must CHECK the value
(require/revert/assert, a conditional, min/max/clamp, an allowlist or validity lookup, a modifier called with
arguments) AND NAME the parameter; the function signature is stripped first, so a role check — including a role
modifier on the declaration line — never bounds an argument. A deploy-script path or deployed-state wording bounds
nothing. Failure ids: `bound-cite-missing`, `bound-cite-unresolved`, `bound-cite-deploy`, `bound-not-a-check`,
`bound-names-other`, `bound-deployed-state`; a failing citation is DEMOTED to unbounded.

**Re-ask and promotion.** One re-ask (`DF_PARAM_MAX_REASKS`, default 1) names the open items; it runs after the
OPCHECK->TRACE loop and before the rubric gate, so a DISMISS written for it is judged by the unchanged rubric +
evidence gate. A G4 lead still open on the final log is promoted to a tier-1 `Medium` candidate, one per
resolvable location, never for a location the rubric gate already promoted (STOP-1 decision 4). The gate never
fails a cell. Per armed cell: `<log>.param-audit.tsv` (one row per parameter) and the additive keys `params`,
`params_unbounded`, `param_bound_failed`, `param_uncovered`, `param_untraced`, `param_over_cap`,
`param_promoted`.

**Pre-registered measurement** (operator step; methodology rules binding). Checkout = this change's merge commit;
the same frozen bases and the frozen `scope.tsv` rows **as-is** (the audit needs no routing); ruler
`--backend flat-cyborg --model claude-opus-4-8 --jobs 1` with the standard killswitches; every other knob as the
iteration-3/4 ON-baseline arm records it. Arms: `audit` = `SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1 PARAM_AUDIT=1`;
`on-control` = the same without `PARAM_AUDIT` (byte-identical prompts, demo-pinned). **Registered held-out test:
superfluid-locker `src__p1`** — `audit` ×2, `on-control` ×1 (this zone was never measured under rubric +
evidence). **GO iff, in BOTH `audit` repeats, at least one of its two rows survives to
`verified_findings.json`** (operator read of cell logs and refute verdicts; per-row replication reported
separately). Exposure stated: the zone ran in two earlier arms, all generation misses; nothing in this design reads
its code. Dev-twin sanity ×1: notional `src_single_sided_lp`, `audit` arm, in-distribution only and never recall.
Tuning happens only on the dev twins; the held-out zone runs only its registered repeats. Reported per run: the
chain *enumerated → traced → unbounded → lead → CANDIDATE / DISMISS / promoted → refute verdict* per rare row and
where it stopped; per cell the `param*` keys (bound failures by id), param re-asks and the rubric keys; candidates
and verified vs `on-control`; cost (reply bytes, calls) vs `on-control`, flagged above 2×. Voids are re-run; any
fallback request voids a run. `src_managers` and `src_mToken__p1` stay unused (kept for later tests); the final
recall claim stays reserved for the never-touched final-exam set.

**Status: IN-FLIGHT — recall UNMEASURED.** This iteration ships the audit, the gate, the bound contract, the
promotion and the offline guards only (`../../demo-param-audit.sh`, wired into `tools/colony-lint.sh`).

### Deep-hunt REACH (#2245, iteration 6 — concrete multi-target selection + handler-coverage gate + inventory)

The measurement pivot for iterations 1-5 was the JUDGMENT and GENERATION halves of the breadth hunter. This
iteration measures the DEPTH engine instead: two frozen deep-hunt runs on the fixed harness both returned CLEAN
with the failure in target SELECTION, not the fuzzer — one deployed an abstract base whose concrete subclass
held the row, the other exercised a router harness with a single action, so neither verdict is informative. REACH
(the `DEEP_HUNT_REACH=1` knob, default OFF) gives the depth engine reach without touching the lens routing, the
fuzzer, the refute gate or the merge: up-to-3 CONCRETE targets per zone (greedy by owned/inherited entry points,
abstract base replaced by its concrete subclass), a pre-fuzz handler-coverage gate that re-asks once on any
uncovered entry point and labels an under-covered CLEAN `LOW_COVERAGE` (below `ceil(0.6 × total)`, total capped
at 20), and a deployment inventory re-injected into every repair round.

**Offline pre-flight on the two frozen diagnosis zones (role names only; no LLM):**

- Zone A (a token share-manager family): the selection picks the concrete token share-manager subclass and NOT
  its abstract base; that target's entry-point denominator includes the inherited vendored `transfer`/
  `transferFrom` path.
- Zone B (a cross-chain + core router pair): BOTH routers are selected; the cross-chain router's entry points
  include the liquidation and repay functions (its 7-line multi-line liquidation header parses correctly).

**Status: MEASURED — mechanics PASS, recall 0 on both diagnosis zones; recall gate NOT run (#2245 comment
5804784466).** The harness now deploys the concrete targets and calls the rows' entry points as handler actions
(zone A: 12 entry points on the first target, one lens `LOW_COVERAGE`; zone B: 9/9 and 7/7 after one re-ask), yet
every verdict stayed CLEAN: the invariant is chosen by lens class, and neither lens menu asks what the target
promises an individual user. The binding gap moved from reach to invariant selection, so the reserved recall zone
was left unspent (its row would meet the same class menu). The default stays OFF. The shipped pieces are the
selection, the gate, the inventory and the offline guards (`../../demo-deep-hunt-reach.sh`, wired into
`tools/colony-lint.sh`).

### Promise-derived invariants (#2245, iteration 7 — last before the final exam)

Iteration 6 fixed reach; the invariant still came from the lens-class menu. PROMISES (the `DEEP_HUNT_PROMISES=1`
knob, requires REACH, default OFF) adds a second, additive source of invariants inside STAGE 4.5: one extra prompt
per cell lists the target's user-facing promises as free-form `PROMISE|#k|<subject>|<statement>|<path:line>` lines
over a real-line-numbered listing (`lib/inheritance.py promise-sources`: target, ancestor contracts, ancestor
interfaces, up to 2 docs naming it); `evm-harness/promise-gate.py gate` keeps only promises whose ≤ 40-line
in-repo citation names the subject (cap 8); every accepted promise must become its own asserting
`invariant_p<k>_…` function (one re-ask), else the CLEAN is `LOW_PROMISE_COVERAGE`. The lens invariant stays and
the fuzzer's exit code stays the only verdict. **No kind vocabulary appears in any prompt** (STOP-1 decision 4):
the kind list drafted for the plan was written with the held-out rows in view, and one of its words names the
recall row's class, so the model lists promises free-form and `promise-gate.py` assigns a kind afterwards from a
fixed keyword map, for the readout only. `demo-deep-hunt-promises.sh` pins that the rendered extraction prompt,
the promise seed and the promise re-ask carry none of the kind words.

**Offline pre-check on the two frozen diagnosis zones (role names only; no LLM; the recall zone untouched):**

- Zone A (the token share-manager family), concrete token share-manager target: the promise listing (≈ 22 KB,
  target + its abstract base + 2 interfaces, no truncation) contains the per-account lockup-setting code in the
  base's issue path and the lockup check on the move path; an operator-written promise citing either range passes
  the citation gate.
- Zone B (the cross-chain + core router pair), cross-chain router target: the listing (≈ 44 KB, target + its
  math base + the repo README window, no truncation) contains the cross-chain repay entry point, the cross-chain
  liquidation entry point and both liquidation-outcome handlers; operator-written promises citing those ranges
  pass the citation gate.

**Status: IN-FLIGHT — recall UNMEASURED.** This iteration ships the listing, the extraction, both gates, the
wiring and the offline guards only (`../../demo-deep-hunt-promises.sh`, wired into `tools/colony-lint.sh`). The
pre-registered measurement (#2245 plan comment 5805207458, STOP-1 comment 5805211578) is an operator step: the
mechanics gate on the two diagnosis zones first (a FAIL on either records recall UNMEASURED and leaves the recall
zone unspent), then an offline pre-flight and the recall gate on the reserved zone ×2 plus one PROMISES-off
attribution control. After it the program goes to the final exam on the never-touched set regardless of the result.

### Breadth function-coverage gate (#2256 — generation misses of the "never looked" kind)

Every earlier gate constrains what a cell says about what it CHOSE to look at (derived checks, dismissal grounds,
audited parameters). The #2245 final exam showed a different generation miss: the row sat in a function that was
in the zone's own sliced function list, and none of the zone's cells mentioned that function at all — they all
converged on another subsystem of the same zone. `FUNCTION_COVERAGE=1` (default OFF) targets exactly that shape
and nothing else: cells write one `READ|<file:function>|<evidence>` line per traced function, the driver checks the
whole zone's final logs against the zone's gated function set (external/public, state-changing, with a body), and
a function no cell traced gets ONE focused coverage cell (narrowed payload, all zone classes, cap 12). It adds no
class, no lens text and no ground-truth knowledge; it cannot help a miss where the right function WAS read and the
bug was not seen, nor one in a function outside the zone's files.

**Status: IN-FLIGHT — recall UNMEASURED.** This change ships the READ contract, the enumeration, the gate, the
coverage cell, the budget half and the offline guards only (`../../demo-function-coverage.sh`, wired into
`tools/colony-lint.sh`). Any recall claim belongs to a new fresh set, measured by the operator.

### Breadth PROMISES (#2264 — breadth-side promise violations)

#2245 iteration 7 turned the target's cited user-facing promises into fuzzer invariants, but only the deep hunt
consumed them; the breadth cells — where the verified rare-row hits came from — never saw one. `BREADTH_PROMISES=1`
(default OFF) targets breadth-side promise violations: a guarantee the code states or enforces for one account or
position that a sequence of calls through the zone's own functions can break. Each zone line's promises are extracted
ONCE (the iteration-7 instruction, byte-identical, no kind vocabulary), kept only when cited and named by the line's own
files, and every breadth cell must settle each one with a `PTRACE|#k|held|<path:line>|..` or `PTRACE|#k|broken|..`
line; a `held` citation is re-opened and a rubric-ON open `broken` becomes one Medium lead. It adds no class, no lens
text and no ground-truth knowledge; it cannot help a miss whose invariant is not a stated or enforced per-account
promise, nor one whose promise the extraction does not list.

**Status: IN-FLIGHT — recall UNMEASURED.** This change ships the extraction pre-pass, the PTRACE contract, the gate,
the promotion and the offline guards only (`../../demo-breadth-promises.sh`, wired into `tools/colony-lint.sh`). Any
recall claim belongs to a new fresh set, measured by the operator.

### Variant-coverage lens (#2265)

**C27** (`auditor/bug-taxonomy.md`) is the class for a protocol that ADMITS several variants of one configurable
thing — an asset/token representation, a pool or market kind, an external interface version, a price-feed kind, a
staking/reward target, a route kind, an implementation behind a registry — while a consuming path handles only some
of them. Two named directions: a **missing branch** (a consumer falls through for the unhandled variants to a
default or zero, a revert or a skipped step) and **basic-variant handling applied** (a consumer never reads the
discriminator and treats every variant like the basic one). The admission and the consumer usually sit in different
contracts, so the class TEXT carries a repository-wide hunt (admitted sets from the constructor/setter/registry and
the repository's own deploy scripts, tests and docs; every consumer; a consumers x variants coverage grid with the
counterpart-pair asymmetry check). A deterministic **single-zone** `zone-mapper.ag` route force-includes C27 on a
zone that reads a variant DISCRIMINATOR (an enum member of a kind/type/variant/interface-version family, a type
flag, an ERC-165 probe) AND owns a VALUE PATH (pricing, swap, deposit/mint, withdraw/redeem, repay, close,
liquidation, reward claim). Cross-zone pairing through `lib/composition-surfaces.py` was rejected: that helper
only feeds deep-hunt target selection and never reaches `scope.tsv` classes. C26 (a PAIR of axes never validated
together) is left byte-unchanged; C27 is ONE axis whose admitted set is wider than what a consumer handles.

**Provenance.** The class text, the prompt rule and the net are written from generic vocabulary, this repo's own
class text and the two frozen DEV maps only; no contest identifier, example or wording is prompt-visible, and the
final-exam motivation is referenced only as #2265. Every net token carries an in-line tag:

| tag | meaning | tokens |
|---|---|---|
| (G) | generic Solidity / token-standard / issue-shape vocabulary | `Type.` `Kind.` `Variant.` `tokenType` `assetType` `isWrapped` `isRebasing` `supportsInterface(` `ERC165Checker`; consumer verbs `getPrice(` `convertTo` `swap` `deposit(` `mint(` `redeem(` `withdraw(` `repay(` `closePosition(` `liquidat` `claimReward` `getReward(` |
| (T) | already in this repo's class text | — (none needed) |
| (D) | attested in a dev design zone | `Interface.V` `feedType`; consumer verbs `_executeTrade(` `exitPosition(` |

The token list is FROZEN: `../../demo-variant-coverage-lens.sh` pins its digest, so any later widening is a
deliberate re-baseline in the same commit, never a silent edit after seeing a measurement set.

**Measured dev fan-out**, driving the SHIPPED token lists (extracted from `zone-mapper.ag`, no LLM) over each zone's
WHOLE file set after the map-zones test / interface / mock / script exclusion:

| role | zones | C27 fires on | carrying surface |
|---|---|---|---|
| dev target A | 9 | 3 — the core strategy zone and the staking zone (a trade-kind enum member), the pool-integration zone (an interface-version enum member) | enum ref (G) / (D) |
| dev target B | 3 | 1 — the main zone (a feed-kind discriminator) | enum ref (D) |
| **total** | **12** | **4 (33 %)** — exactly at the <= 1/3 ceiling | |

Apart from `Type.`, no (G) discriminator token fires on any dev zone; their rate on unseen code is unmeasured. The
consumer surface alone excludes only the proxy, utility and type-only zones — the discriminator is what makes the
net selective. **Known limits of a single-zone route**, recorded rather than repaired: dev target A's reward zone
holds a row of this shape whose admission lives in the pool-integration zone (the C27 cell there reaches it through
hunt steps 1-2), and dev target A's withdraw zone has implementation variants behind a registry with no
discriminator token. A measured routing MISS is followed up with a map-level cross-zone pairing, not a wider list.

**Status: IN-FLIGHT — recall UNMEASURED.** This change ships the class, the route and the offline guards only
(`../../demo-variant-coverage-lens.sh`, wired into `tools/colony-lint.sh`). The pre-registered measurement is an
operator step after merge, on the sealed reserve set from the fresh-set builder (#2263), untouched until the token
digest is frozen by the merge (re-run the builder's contamination scan against the merged tree first; expected
CLEAN):

- **Blind labels before any run** — the operator marks which rare rows (found-by <= 2) have the variant shape under
  the merged C27 text (either direction), from the GT titles only, sealed next to the reserve manifest outside the
  repo. **Zero labelled rows = VOID** (the set cannot test the lens), not NO-GO.
- **One shared map** with the merged mapper at the default configuration; the C27 fan-out (zones firing / zones
  mapped) is reported against the <= 1/3 ceiling as an observation, never tuned.
- **Arms (n=1 each)**, identical in commit, briefs, knob profile (current defaults), model and backend: control =
  that `scope.tsv` with `C27` removed from every row; treatment = the `scope.tsv` as mapped.
- **GO iff** at least one labelled variant-shape rare row reaches `verify/verified_findings.json` in the treatment
  and NOT in the control, marked `HIT-candidate` by `triage.py` (#2262) and confirmed by an operator read;
  otherwise **NO-GO**. An arm voided by the weekly limit, a transport failure or a hard stop is re-run once.
- **Report** (one comment on #2265): per rare row x arm the triage class, operator class and MISS cause with the
  labelled rows marked; rows verified only in control listed as regressions (observation, not part of GO); cost per
  arm (cells, C27 cells, wall clock); the reserve-set fan-out.
- Side effect shared by both arms: `hunter.ag`'s class slice for the LAST class runs to EOF, so before C27 the C26
  cells also carried the trailing usage-notes block; with C27 appended the C26 cells stop at `## C27` and C27 cells
  inherit that tail. Both arms share the taxonomy text, so the effect is identical in control and treatment, but
  it matters when comparing C26 cells with runs from before this change.

## Operationalize-before-you-hunt: measured NO-GO (#2213 M2, 2026-09-15)

The #2211 `OPERATIONALIZE_LENS` directive — a cross-class METHOD (derive code-grounded checks, write them
out as `OPCHECK|` lines, THEN trace each), not a taxonomy class — was measured against this corpus in a
pre-registered ON-vs-OFF A/B over two contests, with the STAGE 1/2 artifacts frozen so the flag was the only
variable. **Rare-tier generation recall moved by exactly 0 rows on both: `notional` 1/14 → 1/14, `yieldoor`
4/8 → 4/8 — identical row for row, not merely equal in count.** Overall recall came out LOWER in treatment
(−2 / −1 rows). Compliance was total (100 % of cells emitted the sentinel, 7.1-8.7 checks per cell), so the
null is about the method, not the wiring. Per the pre-registered rule the default stays OFF; archive with the
full per-rare-row tables: [`runs/2213-operationalize-ab/`](runs/2213-operationalize-ab/).

Two class-level findings fall out of the forensics and matter more than the null itself:

- **C22 (cross-protocol unit), notional H-8, is a ROUTING miss, not a generation miss.** The bug lives in
  `PendlePTOracle._calculateBaseToQuote` (`useSyOracleRate` → `getPtToSyRate` used as a PT→asset rate), but
  the zone map routes C22 to the staking zone only; the oracles zone carries C2,C9,C15,C23,C19,C8. The
  staking C22 cell operationalized the PT/SY units, traced them and honestly answered SAFE for ITS zone,
  while the oracles C2 cell WROTE the exact right check as an `OPCHECK|` and then never traced it. This
  refines the earlier reading above (H-8 "fires + generates but is REFUTED"): on a depth-off breadth sweep
  the binding constraint is class→zone routing plus check follow-through, not candidate airtightness.
- **C23 (hardcoded external-integration parameter), notional H-9, is a MATCHER false negative here.** Both
  arms generated it (`CurveConvex2Token.sol:_exitPool`, C23 and C15 candidates), but H-9's GT signature names
  only `remove_liquidity_one_coin` / `remove_liquidity` / `ETH_INDEX` and no `.sol` basename, so the
  location-first matcher credits the lead to the consensus row M-10 and scores H-9 MISS. Any rare-recall
  number quoted for `notional` with `--gt-dupes` OFF therefore UNDERSTATES C23: absolute rare generation is
  >= 2/14 in both arms. The #1840 GT-equivalence artifact is the fix when a run wants the true count.

## Contest examples (docs only — never prompt-visible)

The `**seen:**` lines of [`../../auditor/bug-taxonomy.md`](../../auditor/bug-taxonomy.md) used to carry the
corpus contest, the GT id and the mechanism of the finding each class was designed on. The taxonomy is read by
`hunter.ag` and folded verbatim into the frozen briefs by `gen-briefs.sh`, so every one of those lines was
ground truth handed to the hunter about a contest it was then scored on (#2231). The lens now carries only the
generic code shape; the contest-keyed originals are parked HERE, verbatim, because they are still the honest
provenance of each class — and this file is documentation the pipeline never reads.

`tools/colony-lint.sh` fails the build if any of this text reappears in a prompt-visible file (`auditor/**`,
`gen-briefs.sh`, `lib/*prompt*`, any `.ag` under `dark-factory/`).

| class | contest | GT rows | verbatim `seen:` text as it read in the lens before #2231 |
|---|---|---|---|
| C2 — oracle integrity | notional | M-12 | corpus-bench notional GT M-12 (`PendlePTOracle._getPTRate` presumes `ptRate` is 1e18-decimal for EVERY market, which does not hold for markets whose index token is not 18-decimal). |
| C11 — first-depositor / inflation | yearn-ybold | H-1 | corpus-bench yearn GT H-1 (a Yearn v3 strategy inheriting `TokenizedStrategy` whose factory/constructor performs no initial seed → first-depositor inflatable). |
| C16 — state-machine liveness | crestal | M-5 | corpus-bench Crestal GT M-5 (worker-induced DoS in deployment requests — no cancellation mechanism). |
| C17 — index/slot-overwrite | crestal | M-1 | corpus-bench Crestal GT M-1 (`createCommonProjectIDAndDeploymentRequest()` hardcodes the request-id index to 0, losing prior requests). |
| C18 — round/auction-griefing | plaza | M-1, M-10 | corpus-bench Plaza GT M-1 (a failed auction period still updates `sharesPerToken` as if it succeeded) and M-10 (a user can always inflate `totalSellReserveAmount` to block the auction from ending). |
| C19 — narrow-integer overflow → revert-DoS | yieldoor | H-3 | corpus-bench yieldoor GT H-3 (a strategy summed two `uint16` Uniswap-V3 slot0 observation counters in `uint16`; a pool with a large observation buffer overflowed the sum, reverting and permanently DoS'ing every pool-activity-gated operation). |
| C20 — concentrated-liquidity tick precision | yieldoor | H-2 | corpus-bench yieldoor GT H-2 (main position ticks are set from `slot0.tick` rather than the `sqrtPrice`-derived tick; at a boundary the tick lags by one, so the allocated range is asymmetric and the position loses fees). |
| C21 — context-flag valuation dispatch | notional | H-4 | corpus-bench notional GT H-4 (`convertToAssets` branches on the transient `t_CurrentAccount`: when it is set AND that account has a pending withdraw request, it returns the attacker-influenceable `getWithdrawRequestValue` escrow valuation instead of `super.convertToAssets` — a borrower steers their own position onto the favorable escrow-based value rather than the fair share price). |
| C22 — cross-protocol asset / unit equivalence | notional | H-8, M-3, M-22 | corpus-bench notional GT H-8, M-3, M-22. |
| C23 — hardcoded external-integration parameter | notional | H-9, M-5, M-18 | corpus-bench notional GT H-9, M-5, M-18. |
| C24 — stale state assumption between touchpoints | yieldoor, notional | M-2 / M-8, M-16 | corpus-bench yieldoor GT M-2, notional GT M-8, notional GT M-16. |
| C25 — empty distribution / zero participation edge | notional (dev, design source), superfluid-locker (held-out, test) | M-8 / M-2 | corpus-bench notional GT M-8 (`AbstractRewardManager` emissions accrue per unit of an `effectiveSupply` floored by a virtual-shares constant, so the no-participants branch never fires) and superfluid-locker GT M-2 (`unlock` reverts while `STAKER_DISTRIBUTION_POOL.getTotalUnits() == 0` although `stakerAllocationBP == 0`, so the pool is owed nothing). Never written into the lens: C25's `seen:` line carries only the generic code shape. |
| C26 — admitted parameter / unenforced bound | notional (dev, design source), malda (held-out, test), superfluid-locker (held-out, recorded routing MISS) | M-3, M-5, M-22 / M-5, M-10, M-12 / M-3, M-5 | corpus-bench notional GT M-3 (a single-sided Curve LP strategy cannot trade when the configured pool is an ETH pool), M-5 (minting yield tokens single sided is impossible when the `CURVE_V2` `dexId` is configured for redemptions) and M-22 (`asset = WETH` paired with a Curve pool holding native ETH loses user funds); corpus-bench malda GT M-5 (a rebalancer sends to unallowed destination chains), M-10 (unenforced fee-cap and time-to-live parameters) and M-12 (a rebalancer drains market funds via excessive bridge fees); corpus-bench superfluid-locker GT M-3 and M-5 (initial-deposit / buffer arithmetic). Never written into the lens: C26's `seen:` line carries only the generic code shape, and the malda-only token vocabulary was deliberately kept OUT of the mapper net. |
| C27 — variant coverage gap | dev target A, dev target B (design source only; roles, never a recall number) | not recorded here — identified by role in the #2265 thread | no `seen:` text was ever contest-keyed: C27's `seen:` line carries only generic code shapes. Dev target A's design rows are a reward-claim path that handles one of two admitted staking targets, a pool holding the native asset that is admitted but unsupported, a route variant accepted on one leg but unsupported on the reverse leg, and a rebasing-token variant admitted without the opt-in it needs; dev target B contributes a feed-kind price getter (a code shape, not a GT row). The final-exam motivation is referenced only as #2265, the test set only as the sealed reserve set. |
| — (iterations 6-7 deep-hunt REACH + PROMISES; no class) | mellow (held-out, diagnosis zone A), lend-v2 (held-out, diagnosis zone B), malda (held-out, reserved recall zone) | not recorded here — the implementer reads no ground-truth file; the rows are identified by role in the #2245 thread | no `seen:` text exists: REACH and PROMISES are depth-engine mechanics, not classes. Zone A's row is a per-account lockup of newly issued shares that a transfer path bypasses; zone B's row is a repay after a cross-chain liquidation that still takes the borrower's funds; the recall zone's row is a redeem rounding direction. None of these words appears in any prompt-visible file. |
| — (iteration 5 parameter audit; no class) | superfluid-locker (held-out, registered test), notional (dev sanity) | M-3, M-5 / M-3, M-5, M-22 | no `seen:` text exists: the audit is a pure-meta method, not a class. Its registered test is superfluid-locker GT M-3 and M-5 (program-lifecycle initial-deposit / buffer arithmetic that makes the cancel path and the start path revert, never examined in any earlier arm); the dev sanity zone carries notional GT M-3, M-5 and M-22 (the configuration-combination design rows of C26). Neither contest nor row is named anywhere prompt-visible. |

Two clean entries stayed in the lens because they name no contest: C2's and C11's non-corpus observations
(a custom Chainlink+sequencer oracle, KiloLend, Curve scrvUSD, a virtual-balance savings vault) are live-hunt
history, not corpus ground truth.

**Consequence for every number on this page.** C16/C17/C18/C19/C20/C21 were designed with the contest's own
mechanism in the lens (2026-07-24, #1783/#1784/#1785 and the C19/C20/C21 PRs), C22/C23 on 2026-08-10 and C24
on 2026-09-16 with the GT ids only. C25 and C26 (#2245) are the first classes written with NO contest text in the lens
at all — their design twins are named only here, and C26 additionally keeps every held-out-only token out of
its zone-mapper net. Any recall claim on `notional`, `yieldoor`, `yearn-ybold`, `crestal` or
`plaza` measured after those dates is **in-distribution** — see the `role` column of `corpus.tsv` and the
hold-out policy in [`README.md`](README.md).
