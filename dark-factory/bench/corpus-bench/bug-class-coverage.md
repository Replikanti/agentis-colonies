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

Two clean entries stayed in the lens because they name no contest: C2's and C11's non-corpus observations
(a custom Chainlink+sequencer oracle, KiloLend, Curve scrvUSD, a virtual-balance savings vault) are live-hunt
history, not corpus ground truth.

**Consequence for every number on this page.** C16/C17/C18/C19/C20/C21 were designed with the contest's own
mechanism in the lens (2026-07-24, #1783/#1784/#1785 and the C19/C20/C21 PRs), C22/C23 on 2026-08-10 and C24
on 2026-09-16 with the GT ids only. Any recall claim on `notional`, `yieldoor`, `yearn-ybold`, `crestal` or
`plaza` measured after those dates is **in-distribution** — see the `role` column of `corpus.tsv` and the
hold-out policy in [`README.md`](README.md).
