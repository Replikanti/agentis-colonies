# C22 routing + TRACE follow-through + dismissal-discipline rehunt (#2214 M3) — archive

The forensic follow-up to the #2213 M2 A/B ([`runs/2213-operationalize-ab/`](../2213-operationalize-ab/)):
`notional` H-8 ("Pendle SY treated 1:1 with PT via `getPtToSyRate`") was MISSED by both #2213 arms, and the
forensics said this was **not a generation failure** — the class that would carry the bug (C22,
cross-protocol unit) never reached the oracles zone, and the one cell that derived the right check never
traced it. This measurement isolates and tests three fixes for that, one at a time, on a single zone.

## Headline

Two levers merged to main and one candidate lever measured, on the **same frozen `notional` base** as
#2213 (map + briefs + target code at `5e4e730`), rescoped to `src_oracles` only (6 base classes:
`C2,C9,C15,C23,C19,C8`) and re-entered through `run-zone-hunt.sh --rehunt-gaps`:

| lever | change | PR | result |
|---|---|---|---|
| 1 — routing | route C22 onto zones with a cross-protocol rate/price touchpoint | #2221 (`1928413f`) | **reaches the bug in 3/3** — every `routed`/`routed+trace` repeat plans a C22 cell that finds the SY-vs-asset referent mismatch |
| 2 — follow-through | a `SAFE` cell must TRACE every `OPCHECK|` it wrote, or it fails `untraced-opcheck` | #2222 (`48d79c5b`) | **mechanically total** — 171/171 checks traced across 21 cells, zero untraced, re-ask never fired |
| 3 — dismissal discipline | config-realizability + external-fact citation rules (`OPERATIONALIZE_LENS=1`) | #2224 (`b77144d9`), measured not merged-as-default | **H-8 PASS** (2/3 carry-or-candidate, cited), **M-12 regresses** (2/3 → 0/3), 7/21 cells degraded, requests 3-7x |

**Routing alone does not recover H-8.** The hunter reaches the SY-vs-asset mismatch every time and, for 5 of
the first 6 `routed`/`routed+trace` repeats, dismisses it as a "trusted-deployer misconfiguration" without
checking whether the audited repo itself ships that configuration (it does — `TestPTStrategyImpl.sol` wires
`useSyOracleRate = true` against an asset-priced feed, which is why Sherlock accepted H-8 as High). That is
the residual cause PR C's dismissal rules target.

### Series 1 — routing + follow-through (9/9 arm-runs, all PURE-OPUS, zero voids, zero `untraced-opcheck`)

| rare row | `control` (lens off, no C22) | `routed` (C22, lens off) | `routed+trace` (C22, lens on) |
|---|---|---|---|
| **H-8** SY≠PT rate source | 0/3 — never named | 0/3 — found & dismissed 2x, bare `SAFE` 1x | 0/3 — found, traced & dismissed 3x (2 cells each time) |
| **M-12** `_getPTRate` 1e18 assumption | 0/3 — adjacent decimals candidate 3x | **1/3** | **2/3** (+1 `UNRESOLVED`) |
| follow-through | n/a | n/a | 171/171 checks traced, 0/21 cells untraced, 0 re-asks |

Pre-registered gates: **lever 1 (TRACE gate) PASS** — zero silent `SAFE`s and the SY/YT check TRACEd in
3/3 (criterion: ≥ 2/3). **Lever 2 (routing) FAILS its own H-8 criterion** — C22 is planned in 3/3 `routed`
repeats (routing works) but converts to an H-8 hit in 0/3 (dismissal intervenes downstream). M-12 is the
only rare-row movement of the series (0/3 → 1/3 → 2/3), and it moves only with the lens ON.

### Series 2 — dismissal discipline, PR C (#2224 merged at `b77144d9`; C22 routed, lens ON, both rules + citation gate active)

| rare row | `routed+trace` (series 1) | `dismissal` (PR C) |
|---|---|---|
| **H-8** | 0/3 — traced, dismissed | r1 cited-CLEAN / degraded-`UNRESOLVED` · r2 **`UNRESOLVED` x2, cited** · r3 **CANDIDATE** → 2/3 meet the pre-registered carry-or-candidate condition — **PASS**; 1/3 is a scoreboard HIT |
| **M-12** | **2/3** | **0/3** — rule 2 as shipped accepts name-only "verifications" (`docs.pendle.finance`, `IPendle.sol:16-19`, `PendlePYOracleLib PMath.ONE`) that close the check `CLEAN` |
| degraded cells | 0/21 | 2 + 3 + 2 = **7/21** (per-cell citation gate tripped by an unrelated uncited line in the same cell) |
| requests / wall-clock | 20-41 / 42-46 min | 146 / 121 / 82 · 83 / 81 / 75 min |
| candidates | 3-5 | 3 · 4 · 6 (anti-Goodhart bound held) |

## The pre-registered gates, scored

| # | gate | series 1 (routing + follow-through) | series 2 (dismissal) |
|---|---|---|---|
| lever 1 | zero silent `SAFE`, SY/YT check TRACEd in ≥ 2/3 | ✅ PASS (3/3, 3/3) | n/a (subsumed) |
| lever 2 | H-8 becomes a candidate in `routed` repeats | ❌ FAIL (0/3) | — |
| dismissal | H-8 candidate-or-`UNRESOLVED`(cited) in ≥ 2/3 **and** M-12 verified-or-`UNRESOLVED` | — | ⚠️ SPLIT — H-8 PASS (2/3), M-12 FAIL (0/3, rule-2 gap) |
| anti-Goodhart | candidates must not collapse vs `control`'s 3-5 | ✅ held every arm-run | ✅ held (3,4,6) |
| cost | cell-log bytes / requests should not blow out | n/a (not remeasured) | ⚠️ 3-7x requests, 1/3 cells degraded per run |

## M3 decision

**PR A (routing, #2221) and PR C rule 1 (config-realizability) stay on main as shipped** — they moved H-8
from "never named" (#2213) to "named with the repo's own configuration cited" and, once in three repeats, to
a candidate. **`OPERATIONALIZE_LENS` stays default OFF** — with it ON, PR B's TRACE gate plus PR C's rule 2
cost M-12 (2/3 → 0/3), degrade a third of the cells, and triple-to-septuple the request count. Three
follow-ups carry the residuals, all sequenced and all cheap to re-measure on this one zone (one arm-run
≈ 75 minutes):

1. **[#2225](https://github.com/Replikanti/agentis-colonies/issues/2225)** — rule 2 must require the cited
   text to STATE the fact and live in the repo (`path:line`); a name-only external reference must be
   `UNRESOLVED`, never `CLEAN`. Expected to give M-12 back.
2. **[#2223](https://github.com/Replikanti/agentis-colonies/issues/2223)** — per-check pairing so the
   citation gate degrades a CHECK, not a whole cell: dismissal r1's C23 carried H-8 `UNRESOLVED` correctly
   and was discarded anyway for an unrelated uncited line in the same cell.
3. **[#2217](https://github.com/Replikanti/agentis-colonies/issues/2217)** — an `UNRESOLVED` on a rare-class
   check must become a second-tier candidate that reaches the refute gate and the scoreboard; today
   dismissal r2's two correct `UNRESOLVED` carries count for nothing on the scoreboard.

Re-measure after 1+2 land: `dismissal` x3 on `src_oracles` again; flip the lens default only if
M-12 ≥ 2/3 **and** H-8 carry-or-candidate ≥ 2/3 **and** degraded cells ≤ 1/7 per run.

## Integrity notes

- **15/15 PURE-OPUS, zero voids** across all three arm-run series (`control`/`routed`/`routed+trace` x3 on
  the `1928413f`+`48d79c5b` tool checkout, `dismissal` x3 on the `b77144d9` checkout) — see `MANIFEST.tsv`'s
  `attribution`/`requests` columns, cross-checked per arm-run with `model-attribution.py --stage discovery`.
  Note the arithmetic: this is **12 arm-runs** (control/routed/routed+trace x3 = 9, dismissal x3 = 3); the
  live measurement comment's running header says "15/15" — that count could not be reconciled against
  `MANIFEST.tsv` or the `arms/` directories (12 present) and is reported here rather than silently corrected
  or repeated.
- **Zero voids.** No `MIXED`/`CONTAMINATED` attribution, no chrome/timeout rerun, across all 12 arm-runs.
- **Gate-3 amendment, per STOP-1 decision 3:** an `untraced-opcheck` degraded cell counts as the MEASURED
  METRIC for the dismissal arm, not as a void requiring a rerun — the 7/21 degraded-cell figure above is
  therefore data, not attrition.
- **Scoring discipline (per the plan comment and STOP-1):** H-8/M-12 verdicts are read from the cell logs
  (`OPCHECK|`/`TRACE|`/`CANDIDATE|` lines) by an operator, never from the location-first scoreboard — #2215's
  secondary ruler credits H-8 through the name-coincident decimals candidate at the same function
  (`PendlePTOracle._calculateBaseToQuote`), which is a false positive (disclosed in the #2213 archive). The
  `h8_kw_prefilter`/`m12_kw_prefilter` columns in each `cells-summary.tsv` are a **case-sensitive keyword
  pre-filter only**; every line they flag is dumped to a per-run review file for the operator read, and the
  `OPERATOR-READ` row in each `cells-summary.tsv` is that read, not the pre-filter.
- **PR C's live demo arm ran 2 cells concurrently with `routed+trace` r3**, disclosed here for completeness:
  PR C's own QA/demo fixtures were exercised on the operator host while `routed+trace` r3 was still running.
  Both are CPU-bound LLM calls to independent flat-cyborg sessions against disjoint work directories (no
  shared state, no shared `discovery/` tree); `routed+trace` r3's own attribution (PURE-OPUS, 20 requests,
  0 fallback/refusal) and cell count (7/7 ok) are unaffected. Flagged per the "disclose, don't silently
  absorb" convention from the #2213 archive's run-integrity section.

## What produced it

- **Commits:** PR A `1928413f` (#2221, C22 cross-protocol-touchpoint routing), PR B `48d79c5b` (#2222, OPCHECK→TRACE
  follow-through gate) — the tool checkout for `control`/`routed`/`routed+trace` is pinned at `48d79c5b` (both
  merged). PR C `b77144d9` (#2224, config-realizability + external-fact citation rules) — the tool checkout
  for `dismissal` is pinned at `b77144d9`. All three are on `main` as of this archive.
- **Backend / model / killswitches:** identical to the #2213 arms — `--backend flat-cyborg --model
  claude-opus-4-8 --jobs 1`, depth OFF (no `--zone-depth-cells`/`--total-depth-cells`, no `--deep-hunt`, no
  `--vector-hunt`), `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 CLAUDE_CODE_NO_MODEL_FALLBACK=1
  CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`.
- **Frozen base, reused byte-identically:** the `notional` map + briefs + target code from #2213 at
  `5e4e730` — never re-mapped, never re-written for this measurement.
- **Zone filter:** STAGE 3 re-entered through `run-zone-hunt.sh --rehunt-gaps` with the staged
  `map/zones.json` filtered down to the single `src_oracles` entry (byte-identical zone dict, one-element
  list) BEFORE `zone-coverage.py init`, so `gaps` yields exactly that one zone. `map/scope.tsv` and `briefs/`
  are left untouched for `control`; for `routed`/`routed+trace`/`dismissal`, `C22` is appended to that one
  zone's scope-line class CSV (the field `run-discovery.sh --list-cells` actually reads to build the per-cell
  class set under `--rehunt-gaps`).
- **`OPERATIONALIZE_LENS`:** unset for `control`/`routed`; `=1` for `routed+trace`/`dismissal` (the lens gates
  both PR B's TRACE requirement and PR C's citation rules).

## Reproduce

See the new `## Zone-restricted rehunt (#2214)` section of
[`../../README.md`](../../README.md) for the staging recipe (stage → filter `zones.json` → inject the added
class into `scope.tsv` → `zone-coverage.py init` → `--rehunt-gaps`).

## Files

- `MANIFEST.tsv` — arm · repeat · commit · model · flags · start · end · rc · attribution · requests, for
  all 12 arm-runs.
- `<arm>/r<n>/cells-summary.tsv` — one row per cell (class, status, candidates, `opcheck_n`, `trace_n`,
  `untraced_n`, `h8_kw_prefilter`, `m12_kw_prefilter`, `unresolved`, `reasks`), derived from the cell logs
  (`hunt_*.log`) only — never from `hunter.ag`, which is a copy of the directive SOURCE and contains the
  literal `OPCHECK|`/`TRACE|` strings as prompt text (the #2213 pitfall: a tree-wide grep reports sentinels
  in the control arm). A trailing `OPERATOR-READ` row carries the per-arm-run H-8/M-12 verdict from the
  operator's live read of the cell logs (never the keyword pre-filter, never the scoreboard).
- `<arm>/r<n>/candidates.tsv` — `location | class | severity` for every `CANDIDATE|` line in that arm-run.
  No mechanism text, no PoC text, no exploit code.
- No raw cell logs, no transcripts, no target code, no host paths.

All host paths are scrubbed; no third-party names beyond the public contest repository already named in the
#2213 archive.
