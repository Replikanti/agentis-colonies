# Operationalize-lens generation-recall A/B (#2213 M2) — pre-registered archive

> **⚠️ in-distribution (#2231).** Both contests measured here — `notional` and `yieldoor` — are `dev` rows of
> `corpus.tsv`: when these arms ran, `auditor/bug-taxonomy.md` still carried their own GT ids and mechanisms in
> its `seen:` lines (C19/C20/C21 since 2026-07-24, C22/C23 since 2026-08-10), and `gen-briefs.sh` folded that
> text into the frozen briefs the arms shared. So the rare-row numbers below are **not** held-out recall: the
> hunter had been told the shape of several of the very rows it is scored on, and the briefs' known-findings
> clause pushed others out of scope. The A/B's INTERNAL comparison still holds (both arms read the identical
> contaminated briefs — the flag was the only variable, which is what the NO-GO rests on); the ABSOLUTE recall
> levels do not transfer. The lens was de-contaminated in #2231; held-out re-measurement belongs on `dodo`,
> `mellow` or `symm`.

The **measurement** half of #2213. It answers the one question #2211's M1 probe could not: does the
opt-in `OPERATIONALIZE_LENS` directive (shipped in PR #2212, default OFF) actually raise **rare-tier
generation recall** — isolated from the #2191/#2192 integration-lens directive that confounded the probe?

Everything below the "Result" heading was fixed **before any arm ran**, in the plan comment on #2213:
the metric, the matcher, the targets, the arm labels, the ruler and the GO/NO-GO rule. No number was
reinterpreted after it was seen.

## Headline: NO-GO. The directive is fully complied with and changes rare recall by exactly ZERO rows on both contests.

| | control | treatment | Δ rare |
|---|---|---|---|
| **PRIMARY `notional`** (confirmation target, burned by the M1 probe) | **1/14** | **1/14** | **0** |
| **TRANSFER `yieldoor`** (the independent gate) | **4/8** | **4/8** | **0** |

Not merely equal in COUNT — **identical row for row**: the same rare GT rows are named in both arms of
both contests (per-row tables below). Overall recall came out LOWER in treatment on both contests
(−2 rows on `notional`, −1 on `yieldoor`). Compliance is total (100 % of cells emitted the sentinel,
7.1-8.7 `OPCHECK|` per cell), so this measures the **method**, not a mis-wiring.

## The decision rule, as pre-registered, scored

| # | Gate | Result |
|---|---|---|
| 1 | rare Δ >= +1 row on PRIMARY **and** TRANSFER | ❌ **FAIL** — 0 and 0 |
| 2 | overall Δ >= 0 **and** consensus(9+) Δ >= 0 on both | ❌ **FAIL** — overall −2 / −1, consensus −1 / −1 |
| 3 | no new `failed` / `hunted_degraded` zone; breadth cell-count parity | ✅ PASS — every cell `ok` in all four arms; 42 = 42 and 15 = 15 |
| 4 | anti-Goodhart: confirm rate MUST NOT rise while rare recall is flat | ❌ **FAIL (recorded as one)** on the transfer contest — confirm rate 77.8 % → 87.5 % with rare flat at 4/8. (`notional` fell, 42.1 % → 33.3 %.) Both samples are small; the gate is reported as it was written, not softened. |
| 5 | cost: wall-clock <= 1.30x and mean cell-log bytes <= 1.50x | ⚠️ **SPLIT** — wall-clock 1.15x (`notional`) / 0.83x (`yieldoor`) PASS; mean cell-log bytes 1.56x on `notional` (6 665 → 10 429) **exceeds** the 1.50x bound, 1.31x on `yieldoor` PASS |

Gates 1, 2 and 4 fail, so the outcome is **NO-GO** outright; gate 5's split would only have mattered had
1-4 passed (the pre-registration routes "5 alone" to a human, never to an automatic flip or abort).

**M3 recommendation: NO-GO — `OPERATIONALIZE_LENS` stays opt-in (default OFF). Do not flip.**

## What produced it

- **Dates (Europe/Prague):** base freeze 2026-09-14 16:20-18:43; arms 2026-09-14 18:43 → 2026-09-15 10:34.
- **Commit:** `5e4e730` (main, the PR #2212 merge — i.e. the directive exactly as shipped). Identical in all arms.
- **Backend / model:** `--backend flat-cyborg`, `--model claude-opus-4-8`, `agentis 1.32.0`.
- **Ruler, identical in every arm:** depth OFF (no `--zone-depth-cells` / `--total-depth-cells`), no
  `--deep-hunt`, no `--vector-hunt`, `--jobs 1`; scoring `generation-recall.sh --judge off --min-overlap 2`
  with no `--gt-dupes` (the frozen #1697 location-first matcher, deterministic, zero judge LLM calls);
  killswitches `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1`, `CLAUDE_CODE_NO_MODEL_FALLBACK=1`,
  `CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`.
- **Single-variable construction:** STAGE 1/2 were frozen ONCE per contest and both arms re-entered STAGE 3
  through `run-zone-hunt.sh --rehunt-gaps`, which skips mapping and brief-writing, so the two arms consumed
  **byte-identical** zone maps and briefs (checksummed, 417 files). With depth OFF the cell set is a pure
  function of `scope.tsv`, which is why cell-count parity is guaranteed rather than hoped for.

### Arm mapping (fixed before any number existed)

| take | arm | `OPERATIONALIZE_LENS` | contest | order |
|---|---|---|---|---|
| take-1 | **control** | unset | notional | 1st |
| take-2 | **treatment** | `1` | notional | 2nd |
| take-3b | **treatment** | `1` | yieldoor | 2nd (rerun, see below) |
| take-4 | **control** | unset | yieldoor | 1st of the pair as run |

Control is the env var **UNSET**, not `=0`: the shipped gate is `getenv("OPERATIONALIZE_LENS") == "1"`, so
unset is exactly the production default an M3 flip would change. Arm order was flipped between contests per
the pre-registration.

### Arm-activity gate (verified before any number was trusted)

| arm | cells | `OPERATIONALIZE\|` lines | `OPCHECK\|` lines | cells with >=1 OPCHECK | attribution |
|---|---|---|---|---|---|
| notional control | 42 | 0 | 0 | 0 | PURE-OPUS (439 req, 0 fallback, 0 refusal) |
| notional treatment | 42 | 42 | 299 (7.12/cell) | 42/42 | PURE-OPUS (371 req, 0/0) |
| yieldoor control | 15 | 0 | 0 | 0 | PURE-OPUS (249 req, 0/0) |
| yieldoor treatment (take-3b) | 15 | 15 | 131 (8.73/cell) | 15/15 | PURE-OPUS (73 req, 0/0) |

The `OPERATIONALIZE|`/`OPCHECK|` counts are taken from the **cell logs** (what the model emitted). Grepping
the whole discovery tree is wrong: each zone's `run/` holds a copy of `hunter.ag`, whose SOURCE contains both
literals, so a naive tree grep reports sentinels in the control arm.

### Two run-integrity events, disclosed

1. **Base freeze hit a weekly API rate limit** (2026-09-14, ~17:20-18:00). Four zone briefs fell back to the
   mechanical stub (`notional`: `src_rewards`, `src_routers`; `yieldoor`: `src__p2`, `src_libraries` — the
   latter two carry ALL 8 `yieldoor` rare GT rows). After the reset those four were regenerated live and
   replaced (2.4-2.9 kB stubs → 14.2-17.6 kB substrate bodies) BEFORE the first arm ran. The base is shared
   by both arms, so this is a base-quality repair, never an arm asymmetry.
2. **take-3 (the first yieldoor treatment run) scored `MIXED` on the attribution gate** and was therefore
   rerun as **take-3b**, per the pre-registered "MIXED VOIDS the pair — rerun, do not report" rule. Forensics:
   the single non-opus record is Claude Code's own `<synthetic>` "API Error: Server error mid-response"
   notice, with 0 fallback content blocks and 0 refusals — i.e. `model-attribution.py` buckets a
   non-model transcript artifact into OTHER and flips the verdict. take-3b came back PURE-OPUS and is the
   reported arm. take-3's artifacts are archived under `yieldoor/treatment-superseded/` for completeness;
   its numbers (rare **4/8** — the same 4 rows, overall 8/17) do not change any gate.

## Result

### PRIMARY — `notional` (37 GT rows, 14 rare). Confirmation, not independent evidence: the M1 probe ran here.

| Metric | control (take-1) | treatment (take-2) | Δ |
|---|---|---|---|
| **rare(1-2) generation-recall — HEADLINE** | **1/14** | **1/14** | **0** |
| overall generation-recall | 7/37 | 5/37 | −2 |
| High / Medium | 4/11 · 3/26 | 3/11 · 2/26 | −1 · −1 |
| mid(3-8) | 4/14 | 3/14 | −1 |
| consensus(9+) | 2/9 | 1/9 | −1 |
| verified-recall | 4/37 | 3/37 | −1 |
| breadth cells | 42 | 42 | 0 |
| candidates / confirmed | 19 / 8 (42.1 %) | 21 / 7 (33.3 %) | +2 / −1 |
| wall-clock | 4 h 34 m | 5 h 15 m | 1.15x |
| mean cell-log bytes | 6 665 | 10 429 | 1.56x |

### TRANSFER — `yieldoor` (17 GT rows, 8 rare). The independent gate.

| Metric | control (take-4) | treatment (take-3b) | Δ |
|---|---|---|---|
| **rare(1-2) generation-recall — HEADLINE** | **4/8** | **4/8** | **0** |
| overall generation-recall | 7/17 | 6/17 | −1 |
| High / Medium | 3/7 · 4/10 | 2/7 · 4/10 | −1 · 0 |
| mid(3-8) | 0/3 | 0/3 | 0 |
| consensus(9+) | 3/6 | 2/6 | −1 |
| verified-recall | 6/17 | 5/17 | −1 |
| breadth cells | 15 | 15 | 0 |
| candidates / confirmed | 9 / 7 (77.8 %) | 8 / 7 (87.5 %) | −1 / 0 |
| wall-clock | 2 h 09 m | 1 h 47 m | 0.83x |
| mean cell-log bytes | 7 956 | 10 414 | 1.31x |

### Per-rare-row detail — `notional`

| row | fb | control | treatment | cause when MISS in both |
|---|---|---|---|---|
| H-2 Morpho collateral-price inflation | 1 | MISS | MISS | generation miss — neither arm produced a candidate at the GT location |
| H-4 collateral price wrong on direct Morpho borrow | 2 | **HIT** | **HIT** | — |
| H-8 Pendle SY treated as 1:1 with YT | 2 | MISS | MISS | **class routing + operationalized-but-not-traced.** The bug is in `PendlePTOracle._calculateBaseToQuote` (`useSyOracleRate` → `getPtToSyRate` used as PT→asset). The zone map routes C22 to the staking zone only; the oracles zone carries C2,C9,C15,C23,C19,C8 — no C22. Treatment's staking C22 cell operationalized the PT/SY units, traced them, honestly found no 1:1 in ITS zone → SAFE. Treatment's oracles C2 cell WROTE the exact check as an `OPCHECK|` ("`useSyOracleRate` selecting `getPtToSyRate` vs `getPtToAssetRate` … the flag's referent must equal what `baseToUSDOracle` prices") and then never traced it — it chased the decimals candidate instead. |
| H-9 hardcoded `useEth` in `remove_liquidity*` | 2 | MISS | MISS | **matcher name-divergent FN.** BOTH arms GENERATED this bug (`CurveConvex2Token.sol:_exitPool`, C23 and C15 candidates, take-1 and take-2). H-9's signature names only `remove_liquidity_one_coin` / `remove_liquidity` / `ETH_INDEX` — never a `.sol` basename or `_exitPool` — so the location-first matcher credits the lead to **M-10** (whose signature does name the file+function) and scores H-9 MISS. The #1840 rare-twin-credited-to-a-consensus-row pattern; `--gt-dupes` was pre-registered OFF. Symmetric, so Δ is unaffected — but **absolute rare generation on `notional` is >= 2/14 in BOTH arms**, not 1/14. |
| H-10 `TradeType` swap to steal funds | 2 | MISS | MISS | matcher-unreachable — signature names no in-scope `.sol` basename (precheck (b)) |
| M-3 single-sided strategy cannot trade ETH pools | 2 | MISS | MISS | generation miss |
| M-5 minting blocked when CURVE_V2 dexId used on redemption | 1 | MISS | MISS | generation miss |
| M-8 emissions accrue on an empty strategy | 1 | MISS | MISS | generation miss |
| M-12 `PendlePTOracle._getPTRate` wrong for some markets | 1 | MISS | MISS | generation miss (same oracle zone as H-8; the decimals candidate crowded it out) |
| M-14 Etherna withdrawal-request value incorrect | 1 | MISS | MISS | matcher-unreachable — signature names no in-scope `.sol` basename |
| M-16 unfair liquidation after collateral drop | 1 | MISS | MISS | generation miss |
| M-18 hardcoded Curve sDAI/sUSDe liquidity reduction | 1 | MISS | MISS | matcher-unreachable — signature names no in-scope `.sol` basename |
| M-22 `asset = WETH` with a native-ETH Curve pool | 1 | MISS | MISS | generation miss |
| M-25 revert in `getWithdrawRequestValue()` bricks the account | 1 | MISS | MISS | generation miss |

**Reachable rare = 10/14** (H-9, H-10, M-14, M-18 can be named by neither arm: their signatures anchor on no
in-scope `.sol` basename, so the location-first matcher can never resolve them). Symmetric across arms.

### Per-rare-row detail — `yieldoor`

| row | fb | control | treatment | cause when MISS in both |
|---|---|---|---|---|
| H-2 main ticks set from the pool's `slot0` | 1 | MISS | MISS | matcher-unreachable — the signature's only `.sol` reference is the EXTERNAL `UniswapV3Pool.sol`; the bug's own location (`Strategy.sol`) is never named, so neither arm can be credited (precheck (b)) |
| H-3 integer overflow in the observation index | 1 | **HIT** | **HIT** | — |
| M-1 `Vault::_calcDeposit()` overflow for low-priced tokens | 2 | MISS | MISS | generation miss |
| M-2 `ReserveLogic::_updateIndexes()` constant-utilization assumption | 1 | MISS | MISS | generation miss |
| M-4 `checkPoolActivity()` timestamp-sentinel check | 1 | **HIT** | **HIT** | — |
| M-5 `checkPoolActivity()` lookback window too short | 1 | **HIT** | **HIT** | — |
| M-7 `Vault::withdraw()` ignores idle capital | 1 | **HIT** | **HIT** | — |
| M-8 interest precision loss | 1 | MISS | MISS | generation miss |

**Reachable rare = 7/8.** The 4 HITs are the same 4 rows in both arms.

### Pre-run prechecks (both passed before any LLM spend)

- **(a) method-family reachability** on the transfer contest (gate: >= 3 of 8 rare rows carry a family the
  directive names — external touchpoint / numeric conversion / stored assumption / paired-operation
  asymmetry): **8/8 PASS.** No fallback to `plaza` / `mellow` was needed.
- **(b) zone reachability:** reported above per contest.
- **Cost pre-flight** (offline `run-discovery.sh --list-cells`): `notional` **42** breadth cells (agreed
  ceiling 45 — passed), `yieldoor` **15**.
- **Step 0 mock dry run** of the freeze → stage → `--rehunt-gaps` recipe: PASS, so the staged recipe was
  used as planned and the `operationalize-ab.sh` fallback was never needed.

## Reading of the null

The directive is mechanically perfect and behaviourally total: every treatment cell derived code-grounded
checks and wrote them out before tracing, at ~7-9 checks per cell, and the checks are real (the M1 live gate
asserts every `OPCHECK|` names a token literally present in the source; H-8's oracle cell wrote precisely the
right check). What the measurement shows is that **deriving the check is not the binding constraint** —
H-8 is the clean counter-example: the check was derived verbatim and then simply not traced, and the class
that would have carried it was never routed to that zone. That points the next lever at **class routing and
check-follow-through**, not at more lens text. Two follow-up issues are filed from these forensics
(see #2213); neither changes this run.

This is the #2191 discipline: a negative is a publishable result. The flag stays opt-in and the number is
archived as-is. One run per arm — these are stochastic; a Δ of 0 rows with row-for-row identical HIT sets on
two independent contests is nonetheless a much stronger null than a Δ of 0 in count alone would be.

## Secondary ruler (#2215) — GT location anchors. The primary above is NOT restated or replaced.

Every number above this heading was produced by the **pre-registered primary ruler**: the frozen #1697
location-first matcher over a 5-column `truth.tsv`, no `--gt-dupes`. It stands exactly as published.

#2215 then showed that ruler has a MEASUREMENT defect on this data. A truth row is only matchable when its
TRUNCATED signature prose happens to name both the `.sol` basename and the function; when the watson expressed
the location as a GitHub `#L<n>` link or a `` `Contract:LINE` `` ref, or the location fell past the
truncation, the row became unreachable — and a lead that DID generate the bug was credited to whichever other
row named file+function. `notional` H-9 is the canonical case: both arms produced
`CurveConvex2Token.sol:_exitPool` candidates and both scored H-9 MISS while the credit landed on its
consensus twin M-10. `extract-gt.sh --code` now resolves those anchors into `truth.tsv` column 6
(`<contest>/truth-locations.tsv`, columns 1-5 byte-identical to the archived `truth.tsv`) and
`score-match.py` credits a lead whose OWN `(file, function)` equals one whole anchor.

The re-score below is **secondary**: same artifacts, same arms, same leads, a different RULER. It is
published next to the primary, never in place of it. "Same leads" is checked, not assumed: the projected
`generation-leads.json` each arm was re-scored from is byte-identical to the one the primary run consumed,
so every difference in the tables comes from the matcher and nothing else.

| contest / arm | rare — primary | rare — +locations | rare — +locations+gt-dupes | overall — primary | overall — +locations | overall — +loc+dupes |
|---|---|---|---|---|---|---|
| `notional` control (take-1) | 1/14 | **5/14** | 5/14 | 7/37 | 13/37 | 13/37 |
| `notional` treatment (take-2) | 1/14 | **5/14** | 5/14 | 5/37 | 11/37 | 11/37 |
| `yieldoor` control (take-4) | 4/8 | **5/8** | n/a | 7/17 | 9/17 | n/a |
| `yieldoor` treatment (take-3b) | 4/8 | **4/8** | n/a | 6/17 | 7/17 | n/a |

`n/a` = no GT-equivalence artifact was declared for `yieldoor`. On `notional` the artifact
(`notional/gt-dupes.tsv`, one hand-declared `DUP H-9 M-10 100` pair) expands **0 rows** once the location
anchors exist: H-9 is now credited DIRECTLY, so its consensus twin has nothing left to donate. The pair is
archived anyway, because the equivalence is a true statement about the ground truth and because "the third
column adds nothing" is itself the result.

**Reachable rare rises to 14/14 (`notional`) and 8/8 (`yieldoor`)** — from 10/14 and 7/8 under the primary
ruler. The four `notional` rows the primary could never resolve (H-9, H-10, M-14, M-18) and the one `yieldoor`
row (H-2) all carry an anchor now, so the rare denominator is finally a capability denominator.

### Every row credited ONLY by a location anchor (the `LOCHIT` lines, verbatim from `scorecard-locations.txt`)

| contest / arm | row | fb | lead location that credited it | reading |
|---|---|---|---|---|
| `notional` control | H-2 | 1 | `AbstractSingleSidedLP.sol:convertToAssets` | SHARED LOCATION — the same anchor H-4 carries; the lead is the H-4 collateral-price mechanism and H-2 is its sibling write-up |
| `notional` control | H-8 | 2 | `PendlePTOracle.sol:_calculateBaseToQuote` | **FALSE POSITIVE** — name-coincident, see the disclosure below |
| `notional` control | H-9 | 2 | `CurveConvex2Token.sol:_exitPool` | **TRUE** — the hardcoded exit-leg bug, generated by this arm |
| `notional` control | M-6 | 3 | `AbstractStakingStrategy.sol:convertToAssets:50` | mid tier |
| `notional` control | M-11 | 5 | `AbstractRewardManager.sol:_claimVaultRewards:191` | mid tier |
| `notional` control | M-22 | 1 | `CurveConvex2Token.sol:_exitPool` | **TRUE** — same exit-leg location, the native-ETH/WETH write-up |
| `notional` treatment | H-2 | 1 | `AbstractSingleSidedLP.sol:convertToAssets` | as control |
| `notional` treatment | H-8 | 2 | `PendlePTOracle.sol:_calculateBaseToQuote` | **FALSE POSITIVE** — as control |
| `notional` treatment | H-9 | 2 | `CurveConvex2Token.sol:_exitPool` | **TRUE** — as control |
| `notional` treatment | M-6 | 3 | `AbstractStakingStrategy.sol:convertToAssets` | mid tier |
| `notional` treatment | M-11 | 5 | `AbstractRewardManager.sol:_claimVaultRewards:191` | mid tier |
| `notional` treatment | M-22 | 1 | `CurveConvex2Token.sol:_exitPool` | **TRUE** — as control |
| `yieldoor` control | H-1 | 7 | `Leverager.sol:liquidatePosition` | consensus tier |
| `yieldoor` control | H-2 | 1 | `Strategy.sol:rebalance` | **TRUE** — the lead text is the slot0-tick-at-boundary bug the row describes |
| `yieldoor` treatment | H-1 | 7 | `Leverager.sol:liquidatePosition` | consensus tier |

### Disclosure: pair credit is MECHANISM-BLIND, exactly like the prose rule it supplements

`notional` **H-8 is credited in BOTH arms and it is a false positive.** The anchor
`PendlePTOracle.sol:_calculateBaseToQuote` is real, and both arms did produce a candidate there — but it is
the DECIMALS candidate, not the SY-vs-YT 1:1 mechanism H-8 describes (the per-rare-row table above records
that forensic from the transcripts: the treatment oracles cell wrote the right `OPCHECK|` and then never
traced it). A name is not evidence of a mechanism; that was already true of the #1697 prose rule and it stays
true here. **#2214's H-8 live test must read the cell-log `OPCHECK|`/`TRACE` lines, never this scoreboard.**
The same caution applies, more weakly, to the SHARED-LOCATION rows (H-2/H-4 on `convertToAssets`): one lead
credits both write-ups of one location.

### Does the secondary ruler change the #2213 decision? No.

| gate | primary | secondary (+locations) |
|---|---|---|
| 1 — rare Δ >= +1 on PRIMARY **and** TRANSFER | ❌ 0 and 0 | ❌ 0 (`notional` 5 vs 5) and **−1** (`yieldoor` 5 vs 4) |
| 2 — overall Δ >= 0 and consensus Δ >= 0 on both | ❌ −2 / −1 | ❌ −2 (13→11) / −2 (9→7); consensus −1 / −1 |
| 3 — no new failed zone, cell-count parity | ✅ unchanged (ruler-independent) | ✅ unchanged |
| 4 — anti-Goodhart confirm rate | ❌ recorded on `yieldoor` | unchanged (ruler-independent) |
| 5 — cost bounds | ⚠️ split | unchanged (ruler-independent) |

**M3 recommendation is unchanged: NO-GO — `OPERATIONALIZE_LENS` stays opt-in (default OFF).** The secondary
ruler moves the ABSOLUTE numbers up on every arm and does not move gate 1 toward GO on either contest.

One honesty correction the secondary ruler forces: the primary's "identical row for row" claim holds for
`notional` (both arms credit the same 5 rare rows) but **NOT for `yieldoor`** — control's `Strategy.sol:rebalance`
lead credits the rare row H-2 and treatment produced no lead at that anchor, so the rare sets differ by one
row in the CONTROL's favour. That strengthens the null; it does not weaken it.

### The rule going forward: quote both

Any single-arm rare number taken from this corpus states **the primary and the +locations number side by
side, plus `reachable rare`** — e.g. "`notional` control rare 1/14 primary, 5/14 with GT location anchors,
reachable 14/14". A bare number is unreadable without its ruler, which is the #1841 principle applied to the
third ruler. See the corpus-bench README's "Scoring" section for the default: location anchors are ON by
default (they are a free by-product of `extract-gt.sh --code`), `--gt-dupes` stays opt-in (it costs judging
calls).

### Secondary-ruler files

- `<contest>/truth-locations.tsv` — the 6-column ground truth regenerated from the SAME base freeze with
  `extract-gt.sh --code`. Columns 1-5 are byte-identical to `<contest>/truth.tsv` (verified by diff).
- `<contest>/<arm>/scorecard-locations.json` — `generation-recall.sh --json` under the secondary ruler.
- `<contest>/<arm>/scorecard-locations.txt` — the raw `score-match.py` rows, including every `LOC`/`LOCHIT`
  line, so `hits - location_credited` recovers the primary number from the same replay.
- `notional/gt-dupes.tsv` + `notional/<arm>/scorecard-locations-gt-dupes.txt` — the hand-declared H-9/M-10
  equivalence and the third-column replay (`DUP 1 0`: zero rows expanded).

## Files

- `MANIFEST.tsv` — take · arm · contest · commit · model · flags · start · end for all five arm-runs.
- `<contest>/<arm>/scorecard.json` — the `--json` generation-recall aggregate (source of the tables above).
- `<contest>/<arm>/cells-summary.json` — per-cell status, candidate count and `opchecks`, plus the status
  distribution and the dosage aggregates. No raw cell logs, no transcripts, no target code.
- `<contest>/<arm>/coverage/zone-coverage.json` — the #1830 coverage record (proves the sweep was clean).
- `<contest>/<arm>/verified_findings.json` — each arm's leads that survived the refute gate.
- `<contest>/truth.tsv` — the shared ground truth, identical for both arms of that contest.
- `yieldoor/treatment-superseded/` — take-3, voided by the attribution gate and kept for disclosure.
- `<contest>/truth-locations.tsv`, `<contest>/<arm>/scorecard-locations.*`, `notional/gt-dupes.tsv` — the
  #2215 SECONDARY ruler (see the section above). The primary files are untouched.

All host paths are scrubbed; no third-party names beyond the public contest repositories.

## Reproduce

See the `## Operationalize-lens generation-recall A/B (#2213)` section of
[`../../README.md`](../../README.md) for the full step-0..6 recipe.
