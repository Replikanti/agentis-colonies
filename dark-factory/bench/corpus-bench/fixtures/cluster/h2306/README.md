# Held-out clustering fixture: h2306 (#2306 phase B)

The held-out set that decides whether root-cause clustering may default ON in the verify stage
(`DF_CLUSTER_FINDINGS`, `verify-findings.sh`). It holds 24 unmodified STAGE 4 `verified_findings.json` outputs from five
concluded Sherlock contests, the contests' ground truth, per-finding root-cause labels written blind, and the
recorded mechanism-judge matches.

`lib/cluster-findings.py` v2 (the cannot-link refinement, #2308) was calibrated on dev data only and frozen at
`64dafa92` before any file here was assembled. **No clusterer (v1 or v2) ran on these files before every hash
below was anchored** in the pre-registration comment:
https://github.com/Replikanti/agentis-colonies/issues/2306#issuecomment-6226678401

## Layout

```
h2306/
  <contest>/
    truth.tsv                  contest ground truth (extract-gt.sh output, 6 columns)
    <arm>/verified_findings.json   one raw STAGE 4 output, byte for byte (one redaction, below)
    root-causes.tsv            blind root-cause labels (same schema as ../oku/root-causes.tsv)
    expected-distinct.tsv      DERIVED: `cluster-holdout.py derive --labels root-causes.tsv`; never hand-edited
    judge-matches.tsv          recorded mechanism-judge MATCHes per raw lead (`cluster-holdout.py judge-project`)
  expected-gate.txt            `cluster-holdout.py gate --root h2306 --method v2` stdout
  spotcheck.tsv                the operator's spot-check of every non-exempt judge-HIT row
```

## Contests and arms

| contest | code repo @ commit | project root | arms (raw entries) |
|---|---|---|---|
| `lend-v2` | `sherlock-audit/2025-05-lend-audit-contest` @ `713372a1ccd8` | `Lend-V2/` | `control-r1` (8), `control-r2` (11), `resolver-r1` (10), `resolver-r2` (8) |
| `numa-audit` | `sherlock-audit/2024-12-numa-audit` @ `ae1d7781efb4` | `Numa/` | `A` (34), `B` (28) |
| `peapods` | `sherlock-audit/2025-01-peapods-finance` @ `d28eb19f4b39` | `contracts/` | `ccip` (5), `dex` (4), `p1` (8), `p3` (3), `voting` (3) |
| `perennial-v2-4-update` | `sherlock-audit/2025-01-perennial-v2-4-update` @ `2381b47e69b1` | `perennial-v2/` | `A` (9) |
| `superfluid-locker` | `sherlock-audit/2025-06-superfluid-locker-system` @ `d8beaeed47f7` | `fluid/packages/contracts/` | 12 arms, 35 entries: `p1-audit-r1`, `p2-{c24,c25,control,evidence}-r{1,2}`, `p2-rubric-r{1,2,3}` |

Arm provenance:
- `numa-audit` `A` / `B` are the #2245 arms `A` / `B-orig`, chosen for the same reasons as oku's (see `../oku/README.md`).
- `perennial-v2-4-update` `A` is #2245 arm `A`.
- `peapods` arms are the final-exam zone outputs, one zone per arm (`contracts__p1` → `p1`, `contracts_ccip` → `ccip`, …). The final-exam result was recorded before this set existed, and these outputs are spent as unseen data from here on (STOP 1 Decision 5).
- `lend-v2` arms are the four non-clone runs of zone `src_LayerZero__p1`.
- `superfluid-locker` arms are `<zone>-<run>` for zones `src__p1` / `src__p2`.

## Selection rule (declared in the plan, applied mechanically)

A STAGE 4 output qualifies if and only if all of the following hold:
- (a) its contest has a `truth.tsv`;
- (b) neither the file nor its contest was ever an input to clustering design, calibration or validation (this excludes oku, notional and yieldoor);
- (c) it is not a VOID, killed or partial run;
- (d) it is one unmodified `verify/` output, not a hand-merged re-refute variant;
- (e) its non-`source` `verified` array is not a byte-copy of another qualifying run;
- (f) it has at least one same-block pair.

Of 84 candidate files, the rules excluded:

| rule | files excluded |
|---|---|
| (b) | 10 |
| (c) | 6 |
| (d) | 3 |
| (e) | 3 |
| (f) | 38 |

That leaves 24 files with 78 same-block pairs, equal to the planning-time pre-count.

## Public-content scrub and redaction

Every string of every staged file, label file and judge file was scanned for absolute host paths, client names and RPC key URLs. There was one hit.

- In `perennial-v2-4-update/A/verified_findings.json` at `$.verified[4].poc_sketch`, the scratch path `/tmp/` became `$TMPDIR/` (1 occurrence, a byte replace).
- The redaction happened before labelling.
- sha256 before the redaction: `7d2c85f1…de78ac`. After: `255435cb…5ac29a`.

The ground-truth text comes from the public judging repos.

## Labels (pre-registered)

- `root-causes.tsv` was written by five separate blind labellers, one per contest.
  - Their only inputs were the raw arm files, `truth.tsv`, the contest source at the commit above, and each entry's mechanical `block_key()` with a shared/singleton flag. That input was not a clustering run.
  - They had no repo access, no clusterer, no identifier / Jaccard / line-distance output and no plan text.
- **Same-root-cause rule** (as in oku): two findings share an `rc` if and only if one minimal code fix at one site removes both exploit paths.
  - `rc` ids are contest-global.
  - A `singleton`-block entry may carry a mechanical `U-<arm>-<idx>` id.
  - Ambiguous calls start their evidence with `borderline:`. There are 3 such rows (lend-v2 1, peapods 1, superfluid-locker 1).
- **Power:** D = 17 labelled-distinct same-block pairs (lend-v2 5, peapods 12), which meets the G4 floor of 12. D_unique = 5 (contest, block, rc-pair) tuples.
  - 6 of the 17 pairs sit in one peapods block (`tokenbridge.sol:_processinboundtokens`, R01/R02).
  - The labeller called that pair close but did not mark it `borderline:`: one strict received-amount check would stop both paths, but the natural minimal fixes differ.
- **Gate amendment** (operator, anchored before any clusterer run): the flip also needs the v1 control to merge at least one labelled-distinct pair (`k >= 1`).
  - With `k = 0` the set never presented the failure mode, and the verdict is INCONCLUSIVE (default stays OFF).
  - Reason: with D_unique = 5, a v1-quality method would pass the zero-merge gate with probability 0.36–0.74.
- Labels are committed verbatim. A label error found later is reported, not edited.

## Judge matches

- **`numa-audit`:** the matches replay the recorded #2245 judge cache, the same recording run as oku's. The hit rows equal the #2245 readout.
- **The other four contests:** the cache was recorded live for this set with `score-match.py --judge cmd`, batch 12 and gate 60. That was 284 judging calls with 0 JUDGE-ERRORs. The matches were then projected per raw lead with `cluster-holdout.py judge-project`.
- The caches are not committed. Each file records its cache's sha256.

## Replay

```
python3 dark-factory/bench/corpus-bench/cluster-holdout.py power --fixture dark-factory/bench/corpus-bench/fixtures/cluster/h2306
python3 dark-factory/bench/corpus-bench/cluster-holdout.py gate --root dark-factory/bench/corpus-bench/fixtures/cluster/h2306 --method v2
```

`run-corpus-bench.sh --self-test` replays the gate and diffs it against `expected-gate.txt`. It also checks the
`DF_CLUSTER_FINDINGS` default against the verdict.
