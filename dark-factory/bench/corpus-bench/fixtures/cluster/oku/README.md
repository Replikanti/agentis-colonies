# Held-out clustering fixture: oku (#2278 M2)

The real data that motivated root-cause clustering (#2278): the two `verify/verified_findings.json` files the
#2245 fresh-set A/B produced on contest `oku`, committed byte for byte, plus that contest's ground truth.
`lib/cluster-findings.py` (M1, PR #2281) was calibrated on dev data only. These files were **held out from the
clusterer: never used to choose T** (the threshold stays the module's `DEFAULT_THRESHOLD`, 0.30, which M1 fixed
before this fixture existed).

## Contents

| file | what | sha256 |
|---|---|---|
| `A/verified_findings.json` | #2245 arm `A`, STAGE 4 output (35 verified) | `c0904526494424773d1b8732bb0a1c7532245bc039c61e45d1df0cc7045282ea` |
| `B/verified_findings.json` | #2245 arm `B-orig`, STAGE 4 output (44 verified) | `002589f5adf8960eba7f49ba10da4ff7ee923304e5890d5f0a32842ead388413` |
| `truth.tsv` | contest ground truth, 19 rows (H-1..H-8, M-1..M-11), 6 columns | `9dd5344f6fad4f01b7b7a596b7580a419d7ad5204afaa7fce93055d2b274292b` |

## Provenance

- **Contest:** Sherlock `2024-11-oku` (Oku). Code `sherlock-audit/2024-11-oku` at
  `ee3f781a73d65e33fb452c9a44eb1337c5cfdbd6` (project root `oku-custom-order-types/`, which is what every
  `location` / `file` in the arm files is relative to); judging `sherlock-audit/2024-11-oku-judging` at
  `51056bfab7c79d1b29e4ff63c4bfbaa80ed420ad`.
- **Run labels** are the ones defined in the #2245 run-label comment
  (https://github.com/Replikanti/agentis-colonies/issues/2245#issuecomment-6024378428):
  - `A` = `A-r1/.../verify`: `SEVERITY_RUBRIC=1 GROUND_EVIDENCE=1`.
  - `B-orig` = `B-r1/.../verify`: A + `FUNCTION_COVERAGE=1 BREADTH_PROMISES=1` with the pre-#2292 scope docs.
- Both files are pre-M1 pipeline output: no `clustering` key, no raw sibling, no entry with a `source` key and no
  function-less `location`. They carry exactly the keys the clusterer reads.
- **Why `B-orig` and not `B-scope2292`** (the column the #2245 verdict reports):
  1. The issue's numbers (44 verified, the order-id collision 6x) were taken from this file.
  2. It is one unmodified STAGE 4 output. `B-scope2292` is split across two directories (39 + 1 retry), so using
     it would mean hand-merging an artifact the pipeline never wrote; `B-scopefix` is a hybrid of carried-over
     verdicts and a partial re-refute.
  3. The #2292 scope bug only removed candidates before verification (5 `out_of_scope`); it changed no verified
     entry, so it does not bear on clustering.
  4. The recorded #2245 judge scores B-orig at 6/19, the same six rows as every other column, and its recorded
     decisions cover every lead of this file.
  5. It has the largest duplicate load, so it is the strongest test.
- **Why this `truth.tsv`:** it is the file the #2245 arms were scored against (the readout's "oku (19)" with its
  H-1..H-8 / M-1..M-11 ids). The similarly named `2025-07-oku-trade-order-types` is a different Sherlock contest
  (1 GT row) that was never reserved or hunted.
- **Public-content scrub:** every string value of both arm files (`location`, `exploit`, `poc_sketch`, `reason`,
  top-level `errors` / `out_of_scope` / `scope_layer`) and of `truth.tsv` was scanned for absolute host paths
  (`/home/`, `/Users/`, `/root/`, `/tmp/`, `worktrees/`) and client names before commit: 0 hits. The truth
  text comes from the public judging repo.
