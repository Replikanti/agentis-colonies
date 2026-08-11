# Refuter→hunter constraint TRANSFER measurement (#1887) — held-out A/B archive

The **held-out measurement** half of #1887's acceptance contract. The frozen constraint corpus
[`../../../../auditor/knowledge/refute-constraints.json`](../../../../auditor/knowledge/refute-constraints.json)
was DERIVED on `notional` (archived under [`../1887-notional-constraints/`](../1887-notional-constraints/))
and is measured HERE on a DIFFERENT contest, `yieldoor`. Corpus frozen and committed (`8e5476c`) **before**
either arm ran — the ordering is the measurement.

## Headline: the result is CLASS-MISMATCH-BOUNDED, not a mechanism verdict

The mechanism works and the treatment was genuinely active (import verified below). But the derivation and
held-out targets have **disjoint bug-class profiles**, so this A/B cannot test transfer on the metric that
matters, and the primary number is null-by-construction:

- **Corpus classes** (what the treatment can inject): C15×9 (integration-seam / composability),
  C21×8 (context-flag valuation dispatch), C23×4 (hardcoded external-integration parameter),
  C2×3 (oracle integrity), C22×3 (cross-protocol unit) — the classes `notional`'s refutations exercised.
- **yieldoor's hunted classes** (from `map/scope.tsv`): C20, C19, C10, C15, C6, C5 (zone `src`); C6, C11,
  C20, C19 (zone `src_libraries`); C14 (zone `src_types`).
- **Overlap = C15 only** — and the hunter injects class-filtered, so every non-C15 cell gets an empty,
  byte-identical block. yieldoor's rare money-tier Highs are **H-2 (C20 slot0 tick-centering)** and
  **H-3 (C19 uint16-overflow DoS)** — classes with **zero corpus constraints**. yieldoor has no C15
  ground-truth bug either, so the treatment has no reachable rare-bug surface on this target.

Root cause: a **single-target-derived** constraint corpus is class-idiosyncratic. Class-keyed transfer needs
`derivation-classes ∩ held-out-hunted-classes ∩ held-out-GT-classes ≠ ∅`; on notional→yieldoor that
intersection is effectively empty. The real lever is a multi-target / class-broad corpus — tracked as
follow-up **#1895**. (Consistent with the earlier G4 finding that transfer is narrow.)

## What produced it

- **Date:** 2026-08-11 (Europe/Prague). OFF arm 16:08–19:14; ON arm 19:15–23:50.
- **Commit:** `8e5476c` (branch `measure/1887-refute-transfer`, off `origin/main`; mechanism in PR #1893, corpus freeze `8e5476c`).
- **Backend:** `flat-cyborg` over Claude Code (model `opus`), `agentis 1.28.0`.
- **Ruler (identical in both arms):** `--zone-depth-cells 4 --total-depth-cells 36`,
  `--judge cmd --judge-min-confidence 60 --no-gt-dupes`, `--backend flat-cyborg`. One run per arm (stochastic).
- **Arm mapping (fixed before any number):**
  - **OFF = control** — `REFUTE_CONSTRAINTS_JSON` unset.
  - **ON = treatment** — `REFUTE_CONSTRAINTS_JSON=<repo>/dark-factory/auditor/knowledge/refute-constraints.json`.
  - Nothing else differs.
- **Treatment active (verified at store level, not just the env var):** the ON run logged
  `Imported 27 entries (0 skipped)` and its per-run knowledge store held all 27 `refute-constraint-*` rows.
  The OFF run carried no such rows. (An input-level check on the hunter sentinel is fooled by the template
  string in the agent source — the store contents are the real proof.)

## Result

Judged recall against `truth.tsv` (17 accepted H/M GT rows), quoted with the ruler above.

| Metric | OFF (control) | ON (treatment) | Δ |
|---|---|---|---|
| **rare(1-2) — PRIMARY** | **1/8** | **1/8** | **0** |
| overall recall | 6/17 | 3/17 | −3 |
| High | 4/7 | 2/7 | −2 |
| Medium | 2/10 | 1/10 | −1 |
| mid(3-8) | 1/3 | 1/3 | 0 |
| consensus(9+) | 4/6 | 1/6 | −3 |
| confirm rate | 64.3% | 63.2% | −1.1 |
| cells | 19 | 24 | +5 |
| candidates | 14 | 19 | +5 |
| confirmed leads | 9 | 12 | +3 |
| judge calls (0 err) | 18 | 24 | — |

## Verdict

- **Primary metric — rare(1-2) recall: FLAT, Δ=0 (1/8 → 1/8).** No transfer, and structurally it could not
  have moved — the corpus has zero constraints in yieldoor's rare-bug classes (C19/C20). This is the
  headline, and it is a class-mismatch artifact, not evidence about whether the mechanism transfers.
- **Goodhart gate: NOT triggered (PASS).** The failure mode is "confirm rate rises while rare recall stays
  flat." Confirm rate did not rise (64.3% → 63.2%); rare flat. No gate-gaming signal.
- **Overall / consensus recall came out LOWER on this run (6/17 → 3/17; consensus 4/6 → 1/6).** Reported, not
  attributed as a treatment harm: it is confounded three ways and cannot be separated at n=1 per arm —
  (a) the structural class mismatch (any treatment effect is off-target); (b) **cell-count parity FAILED**
  (24 vs 19 cells — the plan flags unequal counts as voiding the strict comparison; the ON arm's 12 confirmed
  leads collapsed onto only 3 distinct GT rows vs OFF's 9→6, i.e. more candidates, narrower coverage); and
  (c) single-run stochasticity (recall is high-variance).
- **Outcome:** a legitimate **structurally-bounded null**. The mechanism (PR #1893) imports and injects
  correctly; the held-out target was class-mismatched to a single-target corpus, so the A/B could not test
  transfer on the money metric. Per plan: **default stays off, the corpus stays checked in, #1887 closes with
  this negative.** The transfer lever moves to the multi-target/class-broad corpus (**#1895**).

## Files

- `off/scorecard.json`, `on/scorecard.json` — the `--json` aggregate scorecards (source of the table above).
- `off/verified_findings.json`, `on/verified_findings.json` — each arm's confirmed leads (post refute gate).
- `off/judge-log.jsonl`, `on/judge-log.jsonl` — the semantic-mechanism judge calls; re-derive any recall
  number offline via `score-match.py --judge cache --judge-cache <file>` at any confidence threshold.
- `truth.tsv` — the shared ground truth (17 rows), identical GT for both arms.

All host paths and any third-party names are scrubbed.

## Reproduce

```
# corpus is frozen at <repo>/dark-factory/auditor/knowledge/refute-constraints.json (commit 8e5476c)
# OFF (control):
REFUTE_CONSTRAINTS_JSON= \
  bash <repo>/dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --id yieldoor \
    --work <work>/off-work --backend flat-cyborg \
    --zone-depth-cells 4 --total-depth-cells 36 --judge cmd --judge-min-confidence 60 --no-gt-dupes --json
# ON (treatment) — identical except the env var:
REFUTE_CONSTRAINTS_JSON=<repo>/dark-factory/auditor/knowledge/refute-constraints.json \
  bash <repo>/dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --id yieldoor \
    --work <work>/on-work --backend flat-cyborg \
    --zone-depth-cells 4 --total-depth-cells 36 --judge cmd --judge-min-confidence 60 --no-gt-dupes --json
```
One run per arm; numbers are stochastic. A flat/negative here is the checked-in outcome, not a regression.
