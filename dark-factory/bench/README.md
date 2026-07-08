# dark-factory capability bench

Measures the thing that actually gates earnings on an audited target: **does the
discover → evaluate → DEVISE → attack → novelty-gate pipeline surface a bug N prior
auditors MISSED, and never re-surface one they already found?**

This is the bounty-hunting analogue of the dev-apprenticeship fed-bench (capability,
not SWE delivery). It is **not** the envelope `sdlc-bench`, which calibrates the
meta-agents that build the repos — not the federation's hunting. Model-routing
calibration comes *after* this bench exists to score against.

## Layout

```
bench/
  run-capability-bench.sh        # the scorer
  fixtures/<name>/
    src/                         # in-scope code containing an audit-SURVIVING (residual) bug
    audit.txt                    # the provided audit = the KNOWN-issue exclusion boundary
    truth.tsv                    # ground truth: boundary rows (known) + residual rows (audit-surviving)
```

`truth.tsv` columns: `type<TAB>signature<TAB>class`, where `type` is `boundary`
(already in `audit.txt`; must stay excluded) or `residual` (the audit-surviving bug
DEVISE should surface).

## Two stages

- **STAGE 1 — novelty discrimination (deterministic, CI-safe, no backend).** Each
  `boundary` restatement must be rejected `KNOWN` by `novelty-gate.sh`, and each
  `residual` finding must pass `NOVEL`. This is the safety property — never re-report
  a known bug, never suppress a real one — and it gates CI via `colony-lint`.
- **STAGE 2 — devise recall (live; `--live` + `agentis` + a real LLM backend).** Runs
  `audit-scout.ag` over the fixture and scores whether its `RESIDUAL` leads overlap the
  `residual` truth signature (a HIT) without restating a `boundary` (a false positive).
  This measures the LLM-limited capability. A weak backend legitimately scores low —
  that is the bench telling the truth, and it is exactly the signal model-routing
  calibration will optimise against. Never runs on CI.

## Usage

```bash
# deterministic safety property (what CI runs):
dark-factory/bench/run-capability-bench.sh --json

# full capability measurement (needs a real backend wired into the agentis store):
dark-factory/bench/run-capability-bench.sh --live --json
```

Exit `0` = all run stages passed, `1` = a stage failed, `2` = bad args / missing fixture.

## Adding a fixture

Drop a new `fixtures/<name>/` with `src/`, `audit.txt`, and `truth.tsv`, then run with
`--fixture dark-factory/bench/fixtures/<name>`. Keep the residual genuinely outside the
`audit.txt` boundary (no shared function token / salient terms), or STAGE 1 will
correctly flag it as already-known.
