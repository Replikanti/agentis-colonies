# #2231 held-out baseline + treatment — archive

Held-out measurement of dark-factory's discovery lens on four never-referenced-in-taxonomy contests
(`mellow`, `malda`, `superfluid-locker`, `lend-v2` — de-contamination policy from issue #2231; zero grep
hits for any of these names/GT ids anywhere under `dark-factory/auditor/`). Exported by `export.sh`
(idempotent, no LLM calls, no repo changes) from the operator host's working tree.

## Headline

**Rare-tier recall 0/13 on held-out code, in both control repeats.** All three candidate fixes measured
against that baseline — routing (`bridgefix`), the #2218 state-assumption lens (`c24`), and #2235 external
fact resolution (`resolver`) — are **NO-GO on recall at n=2** (0/3, 0/7, 0/4 rare rows respectively, twice
each). The `resolver` arm's own mechanics — external-fact TRACE + citation gate — **PASS**: 11 re-openable
citations of vendored/in-repo source across its 4 valid repeats, 0 confabulated, 0 untraced after re-asks —
but nothing to discharge, because the hypotheses that would need discharging were never generated. Every
rare MISS across all four arms traces to hypothesis **generation**, not judgment, routing (once fixed) or
evidence.

## What produced it

- **Frozen clean-lens bases**, one freeze per contest, from the `#2232` de-contamination merge checkout
  `70248565` (`bug-taxonomy.md` carries zero corpus contest name / GT id at that commit; post-freeze
  contamination grep CLEAN on every one of mellow (11 zones), malda (19), superfluid-locker (4) and
  lend-v2 (16)). `map-targets.sh` locates 13 of the 14 held-out rare rows to 10 target zones (malda M-16
  has no resolvable location — operator read only, excluded from the recall denominator).
- **Hunt arms** (`control`, `bridgefix`, `c24`) run from the tool checkout at `0667b50` — shipped main, all
  new knobs default OFF, so `control` is the production default. The **`resolver`** arm runs from `8da1068`
  (the `#2235` M4 merge: `OPERATIONALIZE_LENS=1` + `DF_EXTERNAL_RESOLVE=1`).
- **Method**: zone-restricted `--rehunt-gaps` (per the corpus-bench README's "Zone-restricted rehunt
  (#2214)" recipe) against one zone of an already-frozen base at a time — the same mechanism #2214 used, on
  the frozen held-out bases instead of the in-distribution `notional` base.
- **Treatment arms inject a class into the staged `map/scope.tsv`** of the zone under test, not the frozen
  base itself: `bridgefix` adds C5+C12 to `malda src_rebalancer_bridges` (targets the M-5/M-10/M-12 routing
  gap control exposed — the frozen map routes only C15/C23/C3 there); `c24` adds C24 to the 3 zones whose
  frozen map lacks it (`malda src_rebalancer_bridges`, `superfluid-locker src__p2`, `superfluid-locker
  src__p1`).
- **Ruler**: `--backend flat-cyborg --model claude-opus-4-8 --jobs 1`, `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1
  CLAUDE_CODE_NO_MODEL_FALLBACK=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` — identical killswitches/backend
  to the `#2214` arms.

## Arms

| arm | scope.tsv | `OPERATIONALIZE_LENS` | external resolve | used here |
|---|---|---|---|---|
| `control` | frozen (unchanged) | unset | unset | baseline, all 8 valid zones x2 |
| `bridgefix` | + C5,C12 (one zone only) | unset | unset | `malda` `src_rebalancer_bridges` x2 |
| `c24` | + C24 | unset | unset | 3 zones x2 (see above) |
| `lens` | frozen (unchanged) | `1` | unset | defined by the harness, **not run** in this measurement |
| `resolver` | frozen (unchanged) | `1` | `1` | 2 zones x2 (see above; r2 void + re-run, see below) |

## Pre-registered rules, and how they were scored

- **Ruler is the operator's own read of every cell log** (`OPCHECK|`/`TRACE|`/`CANDIDATE|` lines under
  `discovery/<zone>/run/hunt_*.log`), never the keyword pre-filter and never the location-first scoreboard —
  the live table's own header states this convention. Keyword/candidate columns are triage only.
- **A GT row counts as a HIT only if the candidate appears in BOTH repeats of an arm/zone (n=2).** A
  candidate landing on a GT row in one repeat and not the other is scored as **noise**, not a HIT — applied
  explicitly to `malda src_rebalancer` M-7 (found in `control` r1 via a C24 candidate, absent in r2:
  "noise by the n=1 rule", excluded from the 0/13 baseline denominator).
  - Corollary read for the mechanism table: a MISS reproduced identically in both repeats (same cells, same
    candidates, same absence of the mechanism) is read as a **deterministic** MISS, distinguished from a
    MISS whose r1/r2 candidate sets differ.
  - `resolver` r2's on `lend-v2 src_LayerZero__p1`/`mellow src_managers` (the 2026-09-21 re-run) counts on
    this rule identically to any other r2 — its being a re-run of a voided attempt does not change how it is
    scored, only how its attribution is read (see Integrity, below).
- **A treatment arm is scored NO-GO on recall when it recovers 0 of its target rare rows across both valid
  repeats** — applied uniformly: `bridgefix` 0/3 twice, `c24` 0/7 twice (across its 3 zones), `resolver` 0/4
  twice.
- **`resolver`'s mechanics (external-fact TRACE + citation gate) are scored separately from recall**: count
  of `EXTERNAL-CITED` TRACE lines that re-open to a real vendored/in-repo path, count of confabulated
  citations (must be 0), count of untraced `OPCHECK`s after re-asks (must be 0), and whether `ONCHAIN-FACT`
  was ever invoked. This arm's recall NO-GO and its mechanics PASS are reported as two independent verdicts,
  not netted against each other — a resolver that never forms the right hypothesis has nothing for correct
  citation mechanics to discharge.
- **A VOID run (transport failure, hard-stop, operator-stopped) never becomes a one-sided MISS**: it is
  excluded from both the numerator and the denominator and, where budget allowed, re-run under the same
  arm/checkout/bases (see Integrity).

## Integrity notes

- **Hard-stop raised 2 h → 4 h after two cuts.** The original per-repeat bound (`DF_HARD_STOP_S=7200`,
  inherited from #2214/#2218) cut `lend-v2 src__p3` (3 cells in 2 h) and `src__p4` (stopped by the
  operator) during the first baseline pass; both are the M-2 alternate zones (`src_LayerZero__p1`, M-2's
  primary zone, is measured directly) and are recorded here as dropped/VOID rather than re-run. The bound
  was then raised to 14400 s (4 h) for every remaining repeat, control included.
- **The `src__p3`/`src__p4` drop.** Both alternate zones for M-2 were abandoned after the hard-stop cut
  (`src__p3`: rc=124, 3 cells in 2 h; `src__p4`: rc=143, operator-stopped) rather than re-run at the new 4 h
  bound, because M-2's primary zone (`lend-v2 src_LayerZero__p1`) is measured directly and a second location
  for the same rare row does not change the recall denominator.
- **An operator-edit void — `lend-v2 src_LayerZero__p1` `control` r1.** The first attempt also hit the (then
  still 2 h) hard-stop (`rc=124`) mid-run; `MANIFEST.tsv`'s `flags` column shows it ran with
  `DF_RESOLVE_EXTERNAL=off`, while the immediate retry (`rc=0`, same contest/zone/arm/repeat key) shows
  `DF_EXTERNAL_RESOLVE=off` — the operator corrected `env.sh`'s `RESOLVER_ENV_VAR` name between the two
  attempts. Both attempts are preserved as separate `MANIFEST.tsv` rows; only the successful retry has an
  exported `cells-summary.tsv`/`candidates.tsv`.
- **An operator-edit void — `malda src_mToken__p1` r1.** The live table's own notes column records this
  repeat as "re-run after the voided r1": the `control` r1 row present in `MANIFEST.tsv` (`rc=0`,
  PURE-OPUS, 89 requests) is itself the re-run, not the original attempt. Unlike the `lend-v2` case above,
  the voided original attempt did not leave a distinguishable directory name and so has no separate
  `MANIFEST.tsv` row of its own — disclosed here rather than silently presented as a single clean r1.
- **Three weekly-usage-limit voids (2026-09-18), re-run 2026-09-21.** `resolver` r2 on both its zones
  (`lend-v2 src_LayerZero__p1`, `mellow src_managers`) and `c24` r2 on `malda src_rebalancer_bridges` (the
  treatment row immediately ahead of `resolver` r2 in the plan queue, ending the same second `resolver` r2
  starts) all came back with every cell `.novalid`: flat-cyborg returned "no closing sentinel; completed on
  the marker-less grace", the signature of hitting the weekly usage limit rather than a hunt result. All
  three are VOID in `MANIFEST.tsv`. `resolver` r2 (both zones) and `c24` r2 (`malda`) were re-run on
  2026-09-21, same arm/checkout/frozen bases as the voided attempt, and those re-run rows are the ones
  scored above.
  - **Attribution of the three 2026-09-21 re-run rows reads `PURE-OPUS (re-run window)`**, not the export's
    raw `MIXED`. `attrib.sh` keys off Claude Code's transcript store by the exact working-directory string
    used at run time, and the re-run reused the same directory as the voided 2026-09-18 attempt, so the raw
    attribution covers BOTH attempts combined. The operator verified the re-run window alone — filtering the
    shared transcript to records timestamped inside the 2026-09-21 run window — is 100% `claude-opus-4-8`
    (115 / 130 / 6 model records for `lend-v2 src_LayerZero__p1` resolver r2, `mellow src_managers` resolver
    r2, and `malda src_rebalancer_bridges` c24 r2 respectively); the `<synthetic>` records the raw tool
    buckets into `MIXED` are Claude Code's own `API Error` notices from the voided 2026-09-18 attempt, not a
    model fallback on the scored run.
- **Attribution methodology.** Every row's `attribution` column is `attrib.sh <contest> <zone> <arm>
  <repeat>` run fresh by `export.sh` (never cached from a prior archive) — see `MANIFEST.tsv`. A repeat whose
  directory name was reused after a void (the operator-edit voids and the weekly-limit voids above) reports
  on the COMBINED transcripts of every attempt that ever ran under that path, disclosed here rather than
  silently absorbed or silently re-labelled, per the "disclose, don't silently absorb" convention from the
  `2214` archive.

## Reproduce

Every arm-run here is the corpus-bench README's "Zone-restricted rehunt (#2214)" recipe
(`dark-factory/bench/corpus-bench/README.md`, section of that name), applied to a held-out-frozen base
instead of an in-distribution one, with the treatment arms' step 2b (`scope.tsv` class injection) used for
`bridgefix`/`c24`. See that section for the staging, coverage-init and `run-zone-hunt.sh --rehunt-gaps`
commands verbatim, and its "Arm-activity gate" for how to verify an arm before trusting any number
(`OPERATIONALIZE|`/`OPCHECK|` sentinel counts, `model-attribution.py --stage discovery`). Freezing a new
held-out base first requires `corpus.tsv`'s `role=holdout` contests and the "Hold-out policy" section in the
same README.

## Files

- `MANIFEST.tsv` -- contest, zone, arm, repeat, commit, model, flags, start, end, rc, attribution, requests.
  One row per source-harness MANIFEST.tsv row (superseded/void attempts included, never collapsed).
- `targets.tsv` -- contest, sev_id, found_by, title, zone(s), reachable (from `TARGETS.tsv` x
  `targets-zones.tsv`; `malda` M-16 is the one unreachable row -- no resolvable location).
- `<contest>/<zone>/<arm>-r<n>/cells-summary.tsv` -- one row per cell (class, status, candidates, opcheck,
  trace, untraced, unresolved, reasks; `resolver`-arm runs add external_cited, onchain), derived from the
  cell logs (`hunt_*.log`) only -- never from `hunter.ag` (prompt-text copy of the directive source, which
  contains the literal `OPCHECK|`/`TRACE|`/`CANDIDATE|` strings -- the #2213 pitfall). A VOID run's
  directory still gets a `cells-summary.tsv`/`candidates.tsv`, with a trailing `VOID` row/line carrying the
  reason, per every real cell log that exists (a hard-stop can still produce a few genuine completed cells
  before the cut).
- `<contest>/<zone>/<arm>-r<n>/candidates.tsv` -- `location | class | severity` for every `CANDIDATE|` line
  in that repeat. No mechanism text, no PoC text, no exploit code.
- No raw cell logs, no transcripts, no target code, no host paths.

## Operator-read table (verbatim, issue #2231 comment 5706239160)

Live-fetched via `gh api repos/Replikanti/agentis-colonies/issues/comments/5706239160 --jq .body`.

> The table below is the operator's own read of every cell log (never the keyword pre-filter, never the
> scoreboard) -- copied verbatim, including its own "last updated" header at fetch time.

## Held-out baseline — live (last updated 2026-09-21 20:55 — **TREATMENT COMPLETE (n=2 on every arm/zone)** — treatment r2 running — baseline complete (n=2); **treatment arms running** Europe/Prague)

Control arm = shipped main (`0667b50`, all new knobs OFF, lens OFF), zone-restricted `--rehunt-gaps` on the frozen clean-lens bases, 2 repeats per target zone, every zone's first repeat before any second. Operator read per rare row; keyword columns only triage. **These are the first numbers not measured on rows the lens was designed on.**

| contest / zone | rare row(s) | r1 | r2 | notes |
|---|---|---|---|---|
| mellow `src_managers` | M-6 lockup bypass on mint→transfer | **MISS** (generation: no candidate or reasoning names the mint-then-transfer timing) | ⬜ | 6 cells ok, PURE-OPUS (100 req), 2 candidates: **M-1 HIT** (consensus, fb 63 — the inverted transfer-whitelist check at `ShareManager.updateChecks`) and an unguarded `RiskManager.setVault` (not a GT row) |
| malda `src_mToken__p1` | M-1 rounding direction in `__redeem` (fb 1) | **MISS** (generation: 6 cells, 89 req, 0 candidates — the redeem rounding direction is not raised even though a C6 rounding cell ran on the zone) | **MISS** (replicates: 6 cells, 56 req, 0 candidates) | re-run after the voided r1 |
| malda `src_rebalancer_bridges` | M-10, M-5, M-12 | **MISS ×3** (routing: the frozen map gives this zone only C15, C23, C3 — no validation/access class for unenforced `maxFee`/`ttl`, unallowed destination chain, excessive bridge fee; 3 cells SAFE, 0 candidates, 12 req) | **MISS ×3** (identical: 3 cells SAFE, 0 candidates, 11 req, `maxFee`/`ttl` never mentioned) | cheap zone: 12 min; deterministic routing miss, n=2 |
| malda `src_rebalancer` | M-12 (alt zone) | **MISS** (M-12's mechanism — arbitrary `maxFee` through `EverclearBridge` — lives in the bridges zone; here 4 cells C15/C24/C5/C8, 30 req, 1 candidate: the C24 cell found a *tumbling transfer-window budget reset* at `Rebalancer.sendMsg` (2× `maxTransferSize` within seconds by `REBALANCER_EOA`) — the same window-reset defect the consensus row **M-7** (fb 56, "incorrect transfer size validation after time window reset") describes, framed as extraction instead of DoS → M-7 HIT on operator read) | **MISS** (4 cells, 24 req, 0 candidates — the r1 C24 window-reset candidate did not replicate; M-7 is 1/2, i.e. noise by the n=1 rule) | first C24 candidate on held-out code lands on a GT row, but only in 1 of 2 repeats |
| superfluid-locker `src__p2` | M-2, M-6 | **M-2 MISS** (generation: nothing about `unlock` reverting at `getTotalUnits == 0`) · **M-6 MISS-adjacent** (the `_createPosition` candidate flash-skews the ETH/SUP pool price on *provide* to over-mint LP units; M-6 is price manipulation on *withdraw* so liquidity exits as untaxed ETH — same pool-manipulation family, different leg) | **M-2 MISS · M-6 MISS-adjacent** (replicates r1: 5 cells, 110 req, 4 candidates — the `provideLiquidity`/`withdrawLiquidity` zero-tax path (H-2) and the `_createPosition` price-skew on provide again) | 5 cells, 26 req, 6 candidates all at `FluidLocker.sol`: **H-1 HIT** (fb 15: soft-stake then `provideLiquidity` spends the same FLUID, no available-balance gate) and **H-2 HIT** (fb 10: lock → provide → wait → `withdrawLiquidity` with zero tax) — two consensus rows found |
| superfluid-locker `src__p1` | M-3, M-5 | **MISS ×2** (generation: the buffer / initial-deposit arithmetic in `FluidEPProgramManager.cancelProgram`/program start is never examined; routed classes C17, C19, C5, C6, C7 — C6 rounding would be the carrier and did not go there) | **MISS ×2** (replicates r1: 5 cells, 112 req, the same single signature-digest candidate, nothing on the buffer math) | 5 cells, 97 req, 1 candidate: EIP-712-style digest without `chainid`/`address(this)` in `EPProgramManager._verifySignature` (C7) — not a GT row |
| lend-v2 `src_LayerZero__p2` | H-12 | **MISS** (generation: `distributeBorrowerLend` using `borrowWithInterest` — cross-chain borrows originated here instead of this chain's borrows — is never questioned; 6 cells C10/C22/C24/C2/C5/C9, 0 candidates; no accounting-scope class such as C6/C1 routed here) | **MISS** (replicates r1: 6 cells, 100 req, 0 candidates) | 90 req, all SAFE |
| lend-v2 `src_LayerZero__p1` | M-1, M-2, M-6 | **MISS ×3** (generation: 8 cells, 328 req, 9 candidates all at `CoreRouter`/`CrossChainRouter` — none about the repay-vs-liquidation race (M-1), the `borrowAllowed`/`enterMarkets` failure (M-2) or `borrowForCrossChain` breaking (M-6); consensus rows H-19/H-20/H-21-shaped candidates present) | **MISS ×3** (replicates r1: 8 cells, 79 req, 11 candidates of the same shape; nothing on M-1/M-2/M-6) | full run 92 min after the hard-stop was raised to 4 h |
| lend-v2 `src__p3` / `src__p4` | M-2 (alt zones) | ❌ dropped: `src__p3` r1 hit the hard-stop after 3 cells in 2 h, `src__p4` r1 stopped by the operator; M-2's primary zone is `src_LayerZero__p1`, which is measured | — | hard-stop raised to 4 h for every remaining run |

Unreachable for the location ruler (operator read only): malda M-16.

### Baseline result (control, shipped main, n=2)

**Rare-tier recall 0/13 in BOTH repeats** (13 readable held-out rare rows; malda M-16 has no location). Repeat 2 reproduced repeat 1 on every zone: same MISS causes, same consensus HITs (mellow M-1, superfluid H-1/H-2, lend-v2 H-19/H-20/H-21 in both repeats; malda M-7 only in r1 → noise). Causes: **generation 10** (mellow M-6; malda M-1, M-12; superfluid M-2, M-3, M-5; lend-v2 H-12, M-1, M-2, M-6), **routing 3** (malda M-5, M-10, M-12 in the bridges zone: C5/C12 never routed), **adjacent 1** (superfluid M-6), **dismissed 0**. All 20 arm-runs PURE-OPUS; request counts 11–328 per zone-run. Treatment arms (bridgefix, c24, resolver — 2 repeats each) run next against this table; the #2217 M5 re-run is in between.

### Treatment arms — live (same frozen bases, same ruler; control rows above are the comparison)

| arm / zone | rare row(s) | r1 | r2 | read |
|---|---|---|---|---|
| `bridgefix` (C5 + C12 injected) · malda `src_rebalancer_bridges` | M-5, M-10, M-12 | **MISS ×3** | **MISS ×3** | routing fixed — the two new cells RAN (C5 120 lines, C12 74 lines) — but neither ever mentions `maxFee`/`ttl`; C5 touched "destination" once and answered SAFE. So on this zone the cause is routing AND generation: the right class reaches the zone and still does not conceive the bug. 0 candidates, 5 cells. **r2: MISS ×3, identical** (5 cells, 0 candidates, `maxFee`/`ttl`/`destination` never mentioned) → **bridgefix NO-GO on n=2**: routing was necessary but is not sufficient here. |
| `c24` · superfluid-locker `src__p2` | M-2, M-6 | **MISS ×2** | **MISS ×2** (identical: 6 cells, C24 cell no candidate, only the H-1-shaped `provideLiquidity` candidates) | 6 cells (C24 added); the C24 cell produced no candidate; the other cells reproduced H-1/H-2 (consensus) exactly as control. M-2 (`unlock` reverting at `getTotalUnits == 0`) is a state-assumption row on paper, and the lens did not reach it. |
| `c24` · superfluid-locker `src__p1` | M-3, M-5 | **MISS ×2** | **MISS ×2** (6 cells; this time the C24 cell did emit one candidate — an unguarded `FluidEPProgramManager.stopFunding` near `endDate`, which is not a GT row — still nothing on the buffer / initial-deposit math) → **c24 on superfluid NO-GO on n=2** | 6 cells (C24 added); the C24 cell produced no candidate; the only candidate is the same non-GT signature-digest one as control. The buffer / initial-deposit arithmetic in `FluidEPProgramManager` is still never examined — a stale-state lens does not describe it (it is a config-edge / precision row). |
| `c24` · malda `src_rebalancer_bridges` | M-5, M-10, M-12 | **MISS ×3** | **MISS ×3** (re-run 2026-09-21 20:32–20:45 after the Sep-18 attempt was VOID on the weekly limit; 4 cells ok, 0 candidates, PURE-OPUS) → **c24 NO-GO on n=2 on all three zones (0/7 rare rows, twice)** | 4 cells (C24 added), 0 candidates; the C24 cell (86 lines) never mentions `maxFee`/`ttl`. Not a state-assumption zone; included only as a cheap negative control for the lens — and it behaved as one. |
| `resolver` (lens ON + `DF_EXTERNAL_RESOLVE=1`, checkout `8da1068`) · lend-v2 `src_LayerZero__p1` | M-1, M-2, M-6 | **MISS ×3** | **MISS ×3** (re-run 2026-09-21 18:03–19:42 after the 2026-09-18 attempt was VOID on the weekly usage limit: 8/8 cells `.novalid`, "You've hit your weekly limit · resets Sep 21, 6pm"). Re-run: 8 cells ok, 56/56 traced, **5 `EXTERNAL-CITED`** (vendored OZ `Ownable.sol`, in-repo `LToken.sol:281-308`), the on-chain verb was offered (`ONCHAIN-FACT|…|on`) but never called; same consensus candidate set; nothing on M-1/M-2/M-6. Attribution of the re-run's own 115 model records: PURE-OPUS (the 75 `<synthetic>` API-error records in the shared transcript dir all date from the voided Sep-18 attempt). → **resolver on this zone: 0/3 in both valid repeats.** | mechanics work on first live use: 8 cells ok, 45/45 checks traced, **3 `EXTERNAL-CITED` TRACE lines** — two cite the vendored `lib/LayerZero-v2/…/OAppReceiver.sol:97-107` (lzReceive endpoint/peer guards) and one `src/LToken.sol:47` — and the citation gate accepted them (0 untraced after 2 re-asks); the resolver budget file shows the verb was called from the C22 cell. No `ONCHAIN` use. The rare rows did not move: they are generation misses here (the C5 cell traced `borrowForCrossChain` for its access guard and answered CLEAN, never for M-6's cross-chain borrow path), so external reading had nothing to discharge. Candidates = the same consensus set as control + the C10 shortfall-math lead. 104 min. |
| `resolver` · mellow `src_managers` | M-6 | **MISS** | **MISS** (re-run 2026-09-21 19:42–20:31 after the Sep-18 attempt was VOID on the weekly limit; 6 cells ok, 38/38 traced, 1 `EXTERNAL-CITED` (OZ `mulDiv`), no on-chain call, PURE-OPUS 130 records in the re-run window; `ShareManager.mint` traced for overflow/access only — rule 1 even checked the repo's shipped `targetedLockup:0` — the mint-then-transfer timing is never raised; consensus M-1 again) → **resolver: 0/4 rare rows in both valid repeats — NO-GO on recall, mechanics PASS** | 6 cells ok, 37/37 traced, 2 `EXTERNAL-CITED` (vendored OZ `Math.sol:198-199` mulDiv floor; in-repo `IOracle.sol`), 0 `ONCHAIN`; the C5/C13 cells traced `ShareManager.mint` only for the `targetLockup` flag's access control (CLEAN, with the rule-1 "repo ships small value" realizability check) — the lockup-bypass-on-transfer timing is never raised. Consensus M-1 again. |

## Operator summaries (verbatim, issue #2231 comments 5710345689 and 5765715901)

### r1 first clean number (comment 5710345689, 2026-09-17)

> ## Held-out baseline r1 — first clean number (9 of 10 target zones read; lend-v2 `src_LayerZero__p1` re-running with a 4 h cap)
>
> **Rare-tier generation recall: 0/13** on the held-out rows read so far (operator read of every cell log; keyword columns only triage). The same runs found **7 consensus rows** in passing (mellow M-1; malda M-7; superfluid-locker H-1, H-2; lend-v2 H-19, H-20, H-21), so the pipeline is sound — it finds what 10–60 watsons find.
>
> Cause of every rare MISS (table above): **generation 9** (mellow M-6; superfluid M-2, M-3, M-5; lend-v2 H-12, M-1, M-2, M-6; malda M-12 in its alt zone — the cells never touch the mechanism), **routing 3** (malda M-5, M-10, M-12 in `src_rebalancer_bridges`: the frozen map routes only C15/C23/C3 there; the mechanisms are C5 access / C12 fee-vs-protection — a touchpoint rule "bridge send with caller-supplied fee/ttl/destination → C5 + C12" is the cheapest testable fix), **adjacent 1** (superfluid M-6). Zero "found and dismissed" cases on held-out code — the binding constraint here is generation, not judgment, which is what point 5 of the programme predicted.
>
> Operational: lend-v2 zones need a 4 h hard-stop (two 2 h runs were cut); the two M-2 alternate zones (`src__p3`, `src__p4`) are dropped in favour of its primary zone. Repeat 2 of every zone follows, then the #2217 M5 re-run, then the treatment arms (`bridgefix` = C5+C12 on the malda bridges zone; `c24` on the zones whose frozen map lacks C24; `resolver` only where a rare row turns on an external fact).

### Final (comment 5765715901, 2026-09-21)

> ## Held-out measurement — final (baseline n=2, three treatment levers n=2)
>
> | | rare rows (13 readable) | consensus rows found | verdict |
> |---|---|---|---|
> | **control** (shipped main, lens OFF) | **0/13** in both repeats | 7 (mellow M-1; superfluid H-1, H-2; lend-v2 H-19, H-20, H-21; malda M-7 once) | the honest starting line |
> | `bridgefix` (C5+C12 routed to the malda bridges zone) | 0/3, twice | — | **NO-GO**: the right classes reach the zone, the cells never mention `maxFee`/`ttl` — routing necessary, not sufficient |
> | `c24` (#2218 state-assumption lens injected on 3 zones) | 0/7, twice | same as control | **NO-GO**: the C24 cells never produce a GT-row candidate on unseen code |
> | `resolver` (#2235 external reading + lens ON, 2 zones) | 0/4, twice | same as control | **NO-GO on recall, mechanics PASS**: 11 re-openable citations of vendored source, 0 confabulated; nothing to discharge because the hypotheses were never formed |
>
> Cause of every rare MISS across 20 control runs: generation 10, routing 3 (the bridges zone), adjacent 1, dismissal 0. Integrity: 40 valid arm-runs (20 control + 20 treatment), all PURE-OPUS in their run window; 6 voided runs re-run or dropped and disclosed (two 2 h hard-stops on lend-v2 → 4 h cap; one operator-edit void; three weekly-usage-limit voids on 2026-09-18 re-run on 2026-09-21).
>
> What this measurement settled: (1) the corpus is now clean and the number is real; (2) on unseen code the binding constraint is hypothesis generation, not judgment, routing or evidence — the three levers that fixed the in-distribution H-8 story do not move a single held-out rare row; (3) the next lever is a lens written from a concrete miss shape and measured on its held-out twin — #2245 iteration 1 (C25, notional M-8 → superfluid M-2) is in QA and runs next. Archive PR for this measurement follows (docs/data only); it closes this issue.
