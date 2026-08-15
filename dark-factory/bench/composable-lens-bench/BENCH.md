# composable-lens transfer bench (#1914 M4)

Does the class-agnostic **general-solvency** deep-hunt lens (`SYS-solvency`, epic #1914 M1–M3) catch a
composition-class High on **more than the single surface it was shaped on**? This bench is the M4 transfer
validation: it runs the lens over multiple corpus targets and reports whether it caught a real bug on **≥2
distinct** ones.

## What it measures

For each selected corpus target the bench runs `run-zone-hunt.sh --deep-hunt --composable-lens` (the ONLY path
that exercises the general lens — `run-corpus-bench.sh --hunt` never passes `--deep-hunt`, so it never touches
this lens) and tabulates the per-surface `SYS-solvency` verdict from the M3 lens×surface coverage matrix
(`<out>/coverage/lens-surface-matrix.json`, schema `lens-surface-matrix/v1`), falling back to the raw
`deep-hunt/*/run/invariant_*.log` `INVARIANT|<target>|<verdict>` lines (aggregate only, the `_c<N>.log`
per-candidate logs filtered exactly as the #1780 merge adapter does).

The scoring core is `composable-lens-tabulate.py`; the orchestration is `run-composable-lens-bench.sh`.

### Rules the bench enforces

- **HARNESS_ERROR is a GAP, not a clean negative.** A composition seam whose harness failed to
  compile/generate is un-probed. It is tabulated **distinctly from CLEAN** and never counted as a negative or a
  catch — the whole reason the M3 record exists.
- **Adversary-path requirement.** A composable run that deploys `hooks: address(0)` produces a **vacuous
  CLEAN**: the invariant held only because no adversarial actor ever drove the composition seam. A CLEAN/FINDING
  is counted as **meaningful** only if the generated composable test source instantiated a **non-`address(0)`**
  adversarial actor (a Handler/Hook/Adapter/Attacker). A run that never drove the adversary path is flagged and
  **not** counted.
- **CATCH = an adversary-driven FINDING.** A target is a catch iff it has ≥1 `SYS-solvency` FINDING that is
  adversary-driven.
- **The M4 gate: catch on ≥2 DISTINCT targets.** Transfer means the general lens works beyond the one surface
  it was shaped on. The bench **exits non-zero** when the gate is unmet, so a live run's pass/fail is
  unambiguous.
- **`depth_per_zone`, never the nominal flag.** The effective per-zone depth is read from the coverage record
  (`<out>/coverage/zone-coverage.json`, `budget.depth_per_zone`, #1880 — present only when the sweep ceiling
  bit) and recorded next to every number. A recall figure is quoted against THAT.

## Running it

Offline self-test (CI-safe — no network / LLM / forge; this is what `colony-lint` runs):

```
bash dark-factory/bench/composable-lens-bench/run-composable-lens-bench.sh --self-test
```

Live measurement (operator, by hand — clones public corpus targets, runs the real backend, **never on CI**):

```
bash dark-factory/bench/composable-lens-bench/run-composable-lens-bench.sh \
    --live --id <id> --id <id> [--backend flat-cyborg] [--work <dir>]
```

`--id`s are `corpus.tsv` slugs (`../corpus-bench/corpus.tsv`); the transfer gate needs **≥2**. The machine
summary lands at `<work>/summary.json` (also printed with `--json`).

## RESULTS

> **Placeholder — to be filled from the LIVE run.** The default `--composable-lens` flip is gated on this
> measurement; do not fabricate numbers. Fill the table below from a `--live` run's `<work>/summary.json`, one
> row per target, and record the effective `depth_per_zone` (not the nominal flag) plus the backend used.

Backend: _TBD_ · targets: _TBD_ · date: _TBD_

| Target | FINDING | CLEAN | HARNESS_ERROR | Catch | Adversary actor | depth/zone |
|--------|--------:|------:|--------------:|:-----:|-----------------|-----------:|
| _TBD_  |         |       |               |       |                 |            |
| _TBD_  |         |       |               |       |                 |            |

**Distinct catch targets:** _TBD_ / gate ≥2 → _MET / NOT MET_.

HARNESS_ERROR gaps: _TBD_. Vacuous (adversary path not driven): _TBD_.

Once the gate is MET on ≥2 distinct targets, the coordinator flips the `run-zone-hunt.sh` default
(`DEEP_HUNT_COMPOSABLE_LENS=1`) in a follow-up commit and refreshes the demo goldens; `--no-composable-lens`
(shipped here, inert-by-default) becomes the documented byte-identical opt-out for reproducing pre-flip runs.
