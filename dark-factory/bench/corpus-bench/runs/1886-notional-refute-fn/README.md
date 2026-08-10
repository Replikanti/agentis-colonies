# Refute-gate false-negative measurement (#1886) — durable run archive

This directory is the reproducibility fix #1879 lacked: the discovery/verify/refute
artifacts of a single live `notional` run, scrubbed of host paths, so the refute-gate
false-negative characterization in `../../bug-class-coverage.md` can be re-inspected
offline without a fresh multi-hour hunt.

## What produced it

- **Date:** 2026-08-10
- **Commit:** `05b218a` (branch `measure/refute-gate-fn-1886`, off `origin/main`)
- **Backend:** `flat-cyborg 0.12.1` over Claude Code, `agentis 1.28.0`
- **Ruler (quote this with every number):** `--zone-depth-cells 4 --total-depth-cells 36`,
  **effective per-zone depth 4** (`coverage/zone-coverage.json budget.depth_per_zone`; the #1880 ceiling did not bite — 3 zones × 4 = 12 ≤ 36),
  semantic judge `--judge cmd --judge-min-confidence 60`, GT-equivalence **off** (`--no-gt-dupes`),
  scoped to the 3 lens-target zones `src/oracles`, `src/single-sided-lp`, `src/staking`.
  A depth-4 number is **not** cost/recall-comparable to the #1831 depth-12 arm. Wall clock ~4.1 h.

## Reproduce

```
bash <repo>/dark-factory/bench/corpus-bench/run-corpus-bench.sh \
  --live --id notional \
  --corpus <repo>/dark-factory/bench/corpus-bench/corpus.scoped-1886.tsv \
  --backend flat-cyborg \
  --zone-depth-cells 4 --total-depth-cells 36 \
  --judge cmd --judge-min-confidence 60 --no-gt-dupes \
  --judge-log <archive>/judge-log.jsonl --work <work>
```
(`corpus.scoped-1886.tsv` = the committed `corpus.tsv` with `notional`'s scope_hint set to
`src/oracles,src/single-sided-lp,src/staking`.)

## Contents

| path | what |
|---|---|
| `verified_findings.json` | the 2 REAL findings that survived refute |
| `judge-log.jsonl` | 8 judge calls + confidence + MATCH/NO-MATCH vs `truth.tsv` |
| `truth.tsv` | the 37-row notional ground truth (H/M) this run was scored against |
| `discovery/<zone>/discovery-report.md` | per-zone candidate leads as generated (before refute) |
| `refute/<n>_<slug>/` | per-candidate refute artifacts: `verdict.txt`, `refute-out/refute-report.md` (verdict + one-sentence reason), `refute-out/run/refute_*.log` (full rationale), `candidate.manifest`, `eff-class.txt` |

## Headline (this run — stochastic, one run)

- **notional rare recall: 2/14** (baseline 0/14; #1879 measured 1/14 on a separate run)
- overall 3/37 · High 1/11 · Medium 2/26 · rare(1-2) **2/14** · mid(3-8) 0/14 · consensus(9+) 1/9
- candidates generated / refute-confirmed: **29 / 2**; confirm rate 6.9 %, 24 hunt cells
- judge: 8 calls, 0 JUDGE-ERROR; 4 raw MATCH, **confidence gate @60 dropped 1 MATCH (conf 55), costing 1 recall row** (#1841 — gate-sensitive)
- 3 GT rows credited: **H-9** (rare, anchor), **M-22** (rare, non-anchor), **M-2** (consensus, non-anchor)

### Per-anchor characterization (the point of #1886)

| anchor | GT class | generated? | refute verdict | judge → GT | cause |
|---|---|---|---|---|---|
| **H-9** hardcoded `useEth` (`CurveConvex2Token`) | C22/C23 | YES (4 sibling framings) | **1 REAL** (gate 13, `unstakeAndExitPool`, C22) **+ 3 REFUTED** siblings on the same `_exitPool`/`unstakeAndExitPool` use_eth surface | **MATCH → H-9** | **CAUGHT**, but framing-fragile — refuter killed 3 of 4 framings of the same bug as "privileged deployer config"; one precise framing (`coins(i)` returns WETH ERC-20 on a V2 crypto pool) survived |
| **H-8** Pendle SY 1:1 (`PendlePTOracle`) | C22 | **NO** | — | — | **generation miss** — no `PendlePTOracle` SY-rate candidate produced in any zone (it *was* generated in #1879) |
| **H-4** Morpho direct-borrow (`AbstractSingleSidedLP.convertToAssets:196`) | C21 | YES (gate 7) | **REFUTED** | — | **refute false-negative** — refuter rebutted a *different* attack path (deposit re-entry blocked by `CannotEnterPosition`) than the GT mechanism (direct Morpho borrow, `t_currentAccount` unset) |
| **M-12** `PendlePTOracle._getPTRate` decimals | C2 | **NO** | — | — | **generation miss** — same as H-8, no `PendlePTOracle` candidate |

### Bonus (non-anchor) findings

- **M-2** (consensus, rarity 21) — `Ethena.sol:_finalizeCooldown`: when `cooldownDuration()==0`, `balanceBefore` is snapshotted after USDe already arrived → `tokensClaimed=0` with `finalized=true`, permanently pinning a zero payout. REAL, judge MATCH → M-2. A real second confirmed finding the anchors didn't predict.
- **M-22** (rare, rarity 1) — credited from the H-9 REAL lead (mechanically adjacent: `asset=WETH` + Curve Native-ETH loss). One lead, two rare GT rows.

## What this run says about the bottleneck

The refute-gate false-negative this issue set out to measure **is real (H-4), but it is not the dominant loss.** Of the 4 anchors: **1 caught (H-9), 1 refute-FN (H-4), 2 never generated (H-8, M-12).** Generation/coverage lost as many anchors as the refute gate did, and the one catch (H-9) was framing-fragile — 3 of its 4 sibling framings were refuted, which is the candidate-side / class-routing signal #1887 is about. Net rare recall still rose (2/14 vs #1879's 1/14), but via H-9 + a mechanically-adjacent non-anchor (M-22), not via the anchors the lens was built for.

**Lever routing:** the H-4 refute-FN and the H-9 framing-fragility are candidate-side (the refuter judged a mislabeled/under-argued thesis, or killed the wrong framing of a real bug) → the refuter→hunter knowledge-transfer lever in **#1887** is the relevant experiment (this run uses the blackboard coordination layer but records 0 experience/knowledge events — the hunter never learns what the refuter rejects). The H-8/M-12 generation misses are NOT addressed by #1887 — they are a coverage/generation problem upstream of the refute gate. No new taxonomy classes (exhausted, #1831).

> All host/worktree paths are scrubbed; contest-relative `src/...` paths and `sherlock-audit/...` URLs are public and kept verbatim.
