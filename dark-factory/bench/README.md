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

  PASS is **residual recall** (did DEVISE surface every audit-surviving bug). BOUNDARY
  coverage and boundary-overlap are reported **advisory**, never gated: a genuine residual
  legitimately references a boundary function (e.g. *"the reentrancy-focused audit never
  modelled the share path"*), so function-token overlap over-counts "restatements"
  ([#1496](https://github.com/Replikanti/agentis-colonies/issues/1496)).

### The backend

STAGE 2 drives a **real** backend. agentis's `llm.command` contract is `claude -p`-shaped
(`-p --output-format json` + prompt on stdin), so the reliable default is
`bench/lib/claude-p-backend.sh` — a thin `claude -p` adapter, no flat-cyborg PTY (whose
one-shot cold-start proved flaky). Override with `BENCH_LLM_COMMAND` (e.g. point at the
federation's `tools/flat-cyborg-claude.sh` for flat-rate billing); pick the model with
`BENCH_LLM_MODEL` (default `opus` to measure the DEVISE ceiling; `sonnet` for the
federation routing tier). Requires `claude` + a logged-in `~/.claude`; STAGE 2 SKIPs cleanly
without them.

### Validated reference (`rounding-residual`, opus)

audit-scout extracted BOUNDARY **2/2** (both known audit findings) and RESIDUAL recall
**1/1** — surfacing the planted share-price inflation and double-floor rounding leak, *plus*
an emergent cross-ledger insolvency bug not deliberately planted. DEVISE works on a strong
model; the ceiling is real capability, not scaffolding.

## Usage

```bash
# deterministic safety property (what CI runs):
dark-factory/bench/run-capability-bench.sh --json

# full capability measurement (real backend; opus by default):
dark-factory/bench/run-capability-bench.sh --live --json

# measure the federation routing tier instead:
BENCH_LLM_MODEL=sonnet dark-factory/bench/run-capability-bench.sh --live --json
```

Exit `0` = all run stages passed, `1` = a stage failed, `2` = bad args / missing fixture.

## Adding a fixture

Drop a new `fixtures/<name>/` with `src/`, `audit.txt`, and `truth.tsv`, then run with
`--fixture dark-factory/bench/fixtures/<name>`. Keep the residual genuinely outside the
`audit.txt` boundary (no shared function token / salient terms), or STAGE 1 will
correctly flag it as already-known.

## corpus-bench (real concluded contests)

[`corpus-bench/`](./corpus-bench/) is the sibling bench that scores the pipeline against real, concluded
Sherlock contests (ground truth extracted from their public judging-repo reports) instead of one synthetic
fixture — recall stratified by severity and by finding rarity (rare/mid/consensus, i.e. how many watsons
independently found it). See [`corpus-bench/README.md`](./corpus-bench/README.md).
