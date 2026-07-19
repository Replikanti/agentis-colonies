# dark-factory corpus bench

Sibling of [`../run-capability-bench.sh`](../run-capability-bench.sh) (#1490): that bench scores the pipeline
against ONE synthetic fixture with a planted audit-surviving bug. This one scores it against **real, concluded
Sherlock contests** — the same question a session-only calibration answered on 2026-07-11 and never persisted:
*does the pipeline recall what an elite crowd of watsons already found, and does it hold on the RARE bugs that
separate an elite hunter from the crowd, not just the easy consensus ones everybody catches?*

It is **not** a claim of live-hunting performance on a fresh, unaudited target — every contest here is already
concluded and combed over by dozens of watsons + judges, so a HIGH score here means "recovers known-hard
findings," and a low score on the RARE tier is the whole point: that tier is exactly what a $0 live bounty
campaign keeps missing (see `project_hunt_bench_calibration` / `project_dark_factory_live_runs` in operator memory).

## Layout

```
corpus-bench/
  corpus.tsv                    # manifest: id, code_repo, judging_repo, project_subdir, scope_hint (see header)
  fetch-corpus.sh                # clone code+judging repos for one/every corpus.tsv row (no re-hosting)
  extract-gt.sh                  # judging-repo README.md -> truth.tsv (ground truth + rarity)
  score-match.py                 # bench-only scorer: verified_findings.json leads -> HIT/MISS per truth row
                                  #   (--per-lead: also emit per-lead class + HIT/MISS for the fitness feeder)
  bench-to-knowledge.sh           # LEARN half (#1711): scored contests -> per-class real-bug precision ->
                                  #   agentis `hunt-fitness` knowledge (feeds zone-mapper.ag's reorder)
  run-corpus-bench.sh             # orchestrator + scorer (this is the entrypoint)
  fixtures/
    sample-judging-readme.md      # tiny synthetic judging report (2 findings, rarity 2 and 9)
    expected-truth.tsv            # extract-gt.sh's expected output on the fixture above
    score/                        # synthetic score-match.py fixture (truth.tsv + verified_findings.json +
                                  #   expected-scorecard.txt); the second self-test asserts recall 1/3, stable
                                  #   across --min-overlap 2 and 5 (no re-hosted Sherlock prose)
    hunt-fitness/                 # synthetic fixture for the fitness loop (#1711): truth.tsv +
                                  #   verified_findings.json (mixed `class=C6`/`C6` formatting, C6 high-
                                  #   precision, C3 mostly noise) + reorder-harness.ag (mirrors the agent)
```

No contest code or finding text is re-hosted in this repo — only the manifest (repo/commit-free GitHub slugs)
and the fetch/extraction logic are committed. Everything else is cloned fresh from the public Sherlock repos on
demand (`--fetch`), same posture as `fetch-target.sh` / `fetch-audits.sh` elsewhere in `dark-factory/`.

## Ground truth

`extract-gt.sh` parses a judging repo's `README.md` — the compiled report Sherlock publishes once a contest
concludes — into `truth.tsv`. Each accepted High/Medium finding there looks like:

```
# Issue H-1: <title>
Source: <link>
## Found by
<comma-separated watson handles>
### Summary / Root Cause / ...
```

The watson-handle count is the **rarity** signal: a finding six watsons independently found (consensus) is a
different, easier target than one only a single watson caught (rare). `truth.tsv` columns: `sev_id  severity
rarity  title  signature` (signature = title + a truncated body snippet; the compiled Sherlock prose reliably
names both the affected `*.sol` file basename and the function — the signal `score-match.py` matches on — same
idiom as `../fixtures/*/truth.tsv`).

## Scoring

For each contest: run the REAL federation pipeline (`run-zone-hunt.sh`: map → brief → discover → verify) over
the cloned code repo through a real LLM backend, then score each `verified_findings.json` lead against the
`truth.tsv` rows via the **location-first** bench matcher `score-match.py` (#1697). Each lead carries a
structured `location = <file>:<function>:<line>`; a lead HITs a truth row when the lead's **file basename AND
function name both occur** in that row's `signature`. Requiring both tokens disambiguates the file basename
(many rows can name `GatewayTransferNative.sol`; a specific function name lands on one), so **recall is
threshold-independent** for any lead whose function resolves — `--min-overlap` governs ONLY the fallback used
when a lead has no parseable function (file-basename present + a stopword-filtered technical-token overlap
floor). Recall counts DISTINCT truth rows matched (two leads hitting one row count once) and is reported
overall, by severity (High/Medium), and by rarity (rare 1-2 / mid 3-8 / consensus 9+) — flat recall alone
hides that consensus bugs are the easy part.

> This replaced an earlier free-text token-overlap oracle (`novelty-gate.sh`) that failed across every
> threshold on real contest prose (#1697). `score-match.py` is **bench-only**: the live `novelty-gate.sh`
> hunting-pipeline gate and `extract-gt.sh`'s `truth.tsv` schema are both unchanged.

**Verified leads that don't match any truth row are reported as `unmatched_leads`, never auto-claimed as
novel.** A concluded, multi-watson-combed contest rarely has a genuinely missed valid H/M; an unmatched lead is
far more likely noise (FP, out-of-scope, already-known-but-phrased-differently) than a real find. Treat it as
a manual-triage queue, not a result.

## Generation-recall harness (#1730)

The scoring above measures the pipeline's **post-confirmation** verified findings. `generation-recall.sh`
measures one step earlier — the **generator's hypotheses** — so it isolates the GENERATION step from
fuzzer/refuter confirmation and answers the #1716 question the ON-vs-OFF A/B could not: *of the GT bugs the
pipeline never submitted, how many did it actually NAME but then fail to CONFIRM?*

It scores the two generation artifacts a corpus-bench run already stages, projected through the stdlib-only
adapter `hypotheses-to-leads.py` into the `{"verified":[...]}` lead shape the **unchanged** `score-match.py`
already consumes:

- the breadth hunter's **pre-refute** candidates — `zone-hunt-out/discovery/discovery-results.merged.json`
  (each `cells[].candidates[]` string `file:fn:line|class|severity|exploit|poc`);
- the deep-hunt lens's **generated invariant targets** — `zone-hunt-out/deep-hunt/*/run/invariant_*.log`,
  the `INVARIANT|<file:fn>|<verdict>` lines, scored **with the fuzzer verdict IGNORED**. A `CLEAN` verdict is
  ambiguous (a real bug the invariant was too weak to trip is indistinguishable from a genuinely safe target),
  so a `CLEAN` invariant that still **names** a GT bug's location counts as generation-recall — the fuzzer's
  failure to confirm is the generation-vs-confirmation *delta*, not a miss of the generation step.

**Metric.** generation-recall = (DISTINCT GT `truth.tsv` rows whose signature is location-first matched by
`≥1` generated hypothesis) / (total GT rows), using the same file-basename + function co-occurrence rule as
above (threshold-independent at `--min-overlap` 2 and 5), reported overall / by severity / by rarity — the
rare tier is the headline capability number. When a contest also carries `verify/verified_findings.json`, the
**generation−verified DELTA** (GT rows a hypothesis NAMED but the fuzzer/refuter never confirmed) is printed
too — the #1716 expressiveness gap, made measurable.

```bash
# deterministic self-test (what colony-lint runs via demo-generation-recall.sh; no network/LLM/forge):
dark-factory/bench/corpus-bench/generation-recall.sh --self-test

# score the generation step of an already-hunted corpus-bench work dir:
dark-factory/bench/corpus-bench/generation-recall.sh --from-work <dir> --id yieldoor --json
```

`score-match.py`, `extract-gt.sh`, `run-zone-hunt.sh`, `run-discovery.sh`, and `run-invariant-hunt.sh` are all
**unchanged** — this harness only consumes their artifacts, and the adapter absorbs every projection detail so
the #1698/#1699 re-measurement scorer stays byte-identical. This GT-anchored before/after is the **standard
evidence for money-tier levers**: a single one-target A/B is no longer the sole signal.

## Usage

```bash
# deterministic safety property (what colony-lint runs; no network, no LLM):
dark-factory/bench/corpus-bench/run-corpus-bench.sh

# full real-backend measurement over the whole corpus:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --work /path/outside/repo --json

# one contest at a time, staged:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --fetch --gt --id yieldoor --work <dir>
dark-factory/bench/corpus-bench/run-corpus-bench.sh --hunt  --id yieldoor --work <dir> --backend flat-cyborg
dark-factory/bench/corpus-bench/run-corpus-bench.sh --score --id yieldoor --work <dir> --json
```

Point `--work` OUTSIDE the repo checkout (e.g. a scratch dir) — it clones 8 contest code repos + judging
repos and stages a full `run-zone-hunt.sh` output tree per contest, none of which belongs in version control.

Exit `0` = requested stage(s) ran (a low/zero recall is DATA, not a failure — same posture as
`run-capability-bench.sh`'s live stage); `1` = `--self-test` regressed; `2` = bad args; `3` = missing
prerequisite (repo not fetched yet, `agentis` missing, etc).

## Fitness feedback loop (bench → hunter, #1711)

The bench does not just *measure* — it now **teaches the hunt**. The same HIT/MISS matching that scores recall
also tells us which bug classes actually catch REAL bugs (vs surface noise), and that signal feeds back into
`zone-mapper.ag`'s class selection so the highest-precision classes hunt first:

```
score-match.py --per-lead   →   bench-to-knowledge.sh   →   agentis knowledge import --replace   →   zone-mapper.ag
(per-lead class + HIT/MISS)     (per-class precision)       (hunt-fitness KnowledgeEntry rows)       (recommend/reorder)
```

1. **LEARN.** `score-match.py --per-lead` appends one `LEAD<TAB><class><TAB><HIT|MISS>` line per verified lead
   (a HIT = the lead matched a real GT row; MISS = unmatched noise). The flag is purely additive — default
   output stays byte-identical, so the `--self-test` regression is unaffected. `bench-to-knowledge.sh` reads
   the already-scored contests under a `--work` dir, aggregates per class GLOBALLY (`hits`, `misses`,
   `precision = hits/(hits+misses)`), NORMALIZES the messy class field (`class=C3` and `C3` collapse to `C3`;
   empty → `unknown`), and writes agentis `hunt-fitness` `KnowledgeEntry` rows. With `--import <store-dir>` it
   runs `agentis knowledge import <json> --replace`.

   ```bash
   dark-factory/bench/corpus-bench/bench-to-knowledge.sh \
     --work <scored-work-dir> --id dodo --id yieldoor --out hunt-fitness.json
   ```

   **`--replace` is mandatory** (and always used by the feeder): a re-import WITHOUT it ACCUMULATES samples.
   The full JSON is regenerated from all selected contests each run, so the import is idempotent.

2. **ACT.** `zone-mapper.ag` calls `recommend("hunt-fitness", ["real-bug"])` (a soft prior on the
   classification prompt) and `query_knowledge("hunt-fitness", …)` to reorder its emitted `ZONE|` class CSV so
   classes with the highest real-bug precision lead — riding the existing post-`prompt()`/`apply_backstop`
   append mechanism (no shell reorder). That order flows through `map-zones.sh`'s `ZONE|` scrape → `scope.tsv`
   → `run-discovery.sh`'s per-cell fan-out in CSV order. `map-zones.sh` enables `knowledge.enabled` and, when
   the operator sets `HUNT_FITNESS_JSON` to a feeder output, imports it into the run store after `agentis init`
   and before the zone loop:

   ```bash
   HUNT_FITNESS_JSON=/path/to/hunt-fitness.json dark-factory/map-zones.sh --repo <target> --out <out> --backend <b>
   ```

   With no fitness imported the whole path is an **identity** (byte-identical prompt AND class CSV to today), so
   this never changes behaviour until the bench has taught it something.

**MVP boundary.** Fitness is **global per-class** (aggregated across all scored contests). Per-protocol-type
keying (e.g. C6 on a cross-chain gateway vs a lending vault) is a noted follow-up. This layer reprioritizes what
the hunt can *already* do; it does not change the underlying hunt quality. agentis-core is untouched — the
`learn`/`recommend`/`knowledge` primitives already exist.

`dark-factory/demo-hunt-fitness.sh` pins the whole loop (source-guards + feeder precision/normalization +
`knowledge list` visibility + fitness-driven reorder that flips when the fitness flips). Every functional part
runs on `--backend mock` (no LLM), so it never contends with a live corpus-bench run.

## Adding a contest

Append a row to `corpus.tsv` (`id  code_repo  judging_repo  scope_hint`) for any CONCLUDED Sherlock contest
whose judging repo is public. `extract-gt.sh` only needs the judging repo's `README.md` to follow the
`# Issue <H|M>-<N>: <title>` / `## Found by` shape used above — verify that shape holds (`grep -c '^# Issue
[HM]-' README.md` should equal the contest's published finding count) before trusting the extracted count.
