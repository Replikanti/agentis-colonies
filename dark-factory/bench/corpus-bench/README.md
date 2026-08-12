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
                                  #   (--judge: semantic mechanism judge instead of the token matcher, #1829)
  mech-judge.sh                   # judge driver (#1829): request JSON on stdin -> VERDICT| lines on stdout,
                                  #   judged through the flat-cyborg PTY wrapper (never a metered API call)
  gt-dupes.sh                     # GT-equivalence builder (#1840): judges truth rows against each other
                                  #   (upper triangle) through mech-judge.sh -> gt-dupes.tsv next to truth.tsv
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
    mech-judge/                   # synthetic fixture for the mechanism judge (#1829): truth.tsv + leads.json
                                  #   + BOTH pinned scorecards (expected-scorecard.token.txt = the documented
                                  #   defect, expected-scorecard.judge.txt = the corrected answer) +
                                  #   judge-decisions.jsonl (the recorded cache) + judge-stub.sh (offline
                                  #   judge backend; MECH_JUDGE_STUB_MODE=malformed for the fail-closed case)
    gt-dupes/                     # synthetic fixture for GT equivalence (#1840), deliberately SEPARATE from
                                  #   mech-judge/ (adding a row there would change every request payload and
                                  #   silently re-baseline the frozen #1829 cache keys): truth.tsv with a
                                  #   consensus/rare twin pair + a name-sharing NON-duplicate control,
                                  #   leads.json, judge-stub.sh + judge-decisions.jsonl (the recorded
                                  #   one-MATCH defect), dupes-stub.sh (offline builder backend), gt-dupes.tsv
                                  #   + gt-dupes.stale.tsv, and BOTH pinned scorecards
                                  #   (expected-scorecard.nodup.txt / .dup.txt)
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

Two rulers, one scorer. `--judge off` (the **default**, and the only mode CI runs by default) is the
location-first token matcher below; `--judge cache|cmd` (#1829) replaces it with the semantic mechanism judge
described in the next section. The default is deliberately the cheap deterministic one — but it has two
documented failure modes, so **any published recall number should say which ruler produced it**:

- **name-divergent true match → false negative.** The hunter names the factory/helper/getter that actually
  contains the faulty code, while the report's prose anchors its `.sol` link on a different contract and never
  names that function. Same root cause, same mechanism, scored MISS.
- **name-coincident false match → false positive.** A candidate names a function a truth row also names but
  describes a completely different mechanism. Different bug, scored HIT — and it lands on the wrong row, so
  the real row it *did* describe still reads MISS.

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

## Semantic mechanism judge (#1829)

`--judge cache|cmd` swaps the name-matching rule for a **root-cause + mechanism** decision made by a model.
The scorer shows one lead — its `location`, `class`, `exploit` and `poc_sketch` — against a batch of truth
rows and asks: does this candidate describe the SAME faulty code behaviour, abused the SAME way, as one of
these rows? The prompt states both halves of the rule explicitly, because both naive heuristics are wrong:
*shared names are not sufficient evidence* and *divergent names are not disqualifying*.

**Decision contract.** `score-match.py` writes one canonical request per lead × row batch on the driver's
stdin and reads verdict lines off its stdout — nothing else:

```
request  {"lead":{"id","location","file","class","exploit","poc_sketch"},"rows":[{"sev_id","signature"},...]}
reply    VERDICT|<lead_id>|<sev_id>|MATCH|<confidence 0-100>|<one-line reason>
         VERDICT|<lead_id>|NONE|NO-MATCH|<confidence 0-100>|<one-line reason>
```

Only `MATCH` decisions at or above `--judge-min-confidence` (default **60**) score. A verdict about another
lead is ignored; a `MATCH` naming a `sev_id` that was not in the request is dropped.

**The gate is an outlier floor, not a recall parameter (#1841).** The decision rule tells the judge that
divergent file or function names are not disqualifying, and it obeys that in the DECISION — but not in the
CONFIDENCE: a lead that describes the row's root cause from a superseded copy, a factory or a helper comes
back `MATCH` at a confidence in the **60s**. At the old default of 70 that hedge became a scored MISS, so the
rule and the ruler contradicted each other and the contradiction was resolved against the pipeline. The
default now sits **below** the whole observed 62–68 hedge band rather than through the middle of it: it exists
to drop a MATCH the judge itself disbelieves, and on the 43 recorded decisions it was chosen against it drops
nothing at all at 50 or 60. It cannot manufacture a false positive either — the #1829 false-positive direction
is decided by `MATCH`/`NO-MATCH`, and the gate only ever *drops* MATCHes, so no threshold can credit a
candidate the judge rejected. That number rests on one interim run at one pipeline revision: it is a
**sensitivity curve, not a calibration**. Two things falsify it, both visible in the artifacts below — a
credited MATCH in `[60, 70)` that triage shows is a different mechanism, or a location-divergent true match
recorded *below* 60. Either means the confidence cannot separate the two populations, and the answer is to
separate mechanism confidence from location agreement, not to retune again.

Judge mode therefore emits a second trailer next to `JUDGE`:

```
GATE<TAB><min_confidence><TAB><gated_matches><TAB><gated_rows>
```

— the threshold in force, how many valid `MATCH` decisions it dropped, and how many truth rows are MISS
**only** because of it. **A nonzero `gated_rows` means that run's headline is gate-sensitive** and must be
published with its sensitivity; the same archived cache re-derives the number at any other threshold
(`--judge-min-confidence 70` reproduces a pre-#1841 scorecard byte-for-byte).

**The judge is AUTHORITATIVE — there is no fallback to the token matcher.** A silent fallback would re-import
exactly the two failure modes the judge exists to fix, so an unparseable reply is a **JUDGE-ERROR**, never a
quiet NO-MATCH, and the run **aborts with exit 4** once JUDGE-ERRORs exceed `--judge-max-error-rate` (default
20 %) — a degraded backend must not be allowed to publish a plausible-looking low recall. Judge mode adds two
extra trailer lines to the scorecard, `JUDGE<TAB><calls><TAB><errors>` and the `GATE` line above; the per-row
`HIT|MISS` lines and the `LEADS` trailer keep their shape, so every downstream consumer is unaffected.

**Quoting the ruler.** A judged recall figure is meaningless on its own — quote it with
`(judge mode, min-confidence, gt-dupes state)`. All three now appear in the human line and in the `--json`
output of `run-corpus-bench.sh`, and both harnesses **forward the threshold they print**, so the printed gate
is by construction the applied one. `GATE` says what that gate cost the run.

**Three modes, and which one belongs where:**

| mode | what it does | where |
|------|--------------|-------|
| `off` (default) | the frozen #1697 token matcher, byte-identical output | everywhere by default; the only mode in the corpus-bench self-tests |
| `cache` | replays recorded decisions from `--judge-cache`; a **miss is fatal (exit 4)** | CI (`demo-mech-judge.sh`) and any offline re-derivation of a published number |
| `cmd` | invokes `--judge-cmd` (default `mech-judge.sh`) for a miss and records it read-through | operator-run only, on freed subscription capacity |

**CI never runs `cmd`.** The CI path is `cache` plus an offline stub — no LLM, no network, no `agentis`.

**Reproducibility rule.** A judged number is reproducible offline **only** via its recorded decisions:
`--judge-cache` is a content-keyed read-through cache (sha256 of the canonical request) and `--judge-log` is
an append-only record of every live judging call, including the raw reply. **Archive the log next to the
scorecard** — the recorded raw reply is what the cache replays and re-parses, so `--judge cache` reproduces a
`--judge cmd` scorecard byte-for-byte. Without the log, a judged recall number is an unverifiable claim.

**Cache-generation hazard — read this before editing the judge prompt.** The cache key covers `{lead, rows}`
**only**; the prompt in `mech-judge.sh` is deliberately *not* part of it, and a replay re-parses the recorded
`raw_reply` instead of re-asking. So editing the prompt, the `VERDICT|` grammar or the decision rule does
**not** invalidate a single recorded decision: entries from before and after the edit keep colliding on the
same key, and one cache file silently mixes two **decision generations** with no field anywhere saying which
is which. Any prompt change must therefore **version the key first** — stamp a `judge_rev` (a hash of the
prompt builder) on every newly recorded entry, report the distinct revisions found at replay time
(pre-existing entries read `unversioned`), and offer a hard-fail switch for a mixed cache. This is not
currently implemented, and it is uninformative until a second generation exists — which is exactly why the
rule is "version before you edit", not "version afterwards". The same warning sits on `judge_request()` in
`score-match.py`, where the key is built.

**Judging always runs through the flat-cyborg PTY wrapper.** `mech-judge.sh` shells out to
`${MECH_JUDGE_LLM_CMD:-<federation-root>/flat-cyborg-claude.sh}` (the same `LLM_WRAP`-style indirection
`run-autoharness.sh` and `run-method-discovery.sh` use), so judging bills against the flat-rate subscription
session and never the metered print-mode API. It raises `FLAT_CYBORG_IDLE_MS` to 12000: the wrapper's own
8000 default is too short for a multi-row reasoning prompt and truncates the reply.

**Cost shape.** One judging call per lead × batch of `--judge-batch` rows (default 12) — a 37-row contest
costs 4 calls per lead. The batch exists for accuracy as much as cost: judging a lead against ALTERNATIVE
rows gives a name-coincident candidate a better home to go to instead of being forced onto its name twin. The
read-through cache makes re-scoring free.

```bash
# CI / offline: replay recorded decisions (this is what colony-lint runs via demo-mech-judge.sh)
dark-factory/bench/corpus-bench/score-match.py <truth.tsv> <verified_findings.json> \
  --judge cache --judge-cache <decisions.jsonl>

# operator re-measurement of an already-staged work dir, live judge, decisions recorded for replay:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --score --id yieldoor --work <dir> --json \
  --judge cmd --judge-cache <dir>/judge-cache.jsonl --judge-log <dir>/judge-log.jsonl

# the same ruler on the generation side (both halves of the generation-minus-verified DELTA):
dark-factory/bench/corpus-bench/generation-recall.sh --from-work <dir> --id yieldoor \
  --judge cache --judge-cache <dir>/judge-cache.jsonl --json

# driver contract check (offline):
dark-factory/bench/corpus-bench/mech-judge.sh --self-test
```

`--judge cmd` follows the same discipline as `--live` elsewhere in this bench: run it only on freed
subscription capacity, never on CI, and never as part of a PR gate. `novelty-gate.sh` (the live
hunting-pipeline gate), `extract-gt.sh`'s `truth.tsv` schema and the location-first algorithm itself are all
**unchanged** — judge mode is strictly additive and default-off.

`dark-factory/demo-mech-judge.sh` pins the whole thing on synthetic fixtures (`fixtures/mech-judge/` and
`fixtures/mech-judge-location/`, our own structural analogues — no contest prose or code is re-hosted here
either): the token matcher's WRONG answer and the judge's RIGHT answer are both byte-exact, so neither
direction of the #1829 defect can come back silently, and the fail-closed paths (malformed reply, degraded
judge, cache miss) are asserted too. The location fixture pins the gate in both directions from ONE recorded
decision set — a hedged `MATCH|64` from a superseded-copy location is MISS at 70 and credited at the shipped
default with an unchanged `JUDGE` trailer, while a name-coincident different-mechanism lead stays MISS even at
`--judge-min-confidence 0` — plus a source-guard that the default has exactly one value across the scorer and
both harnesses.

## GT equivalence classes (#1840)

A concluded judging repo routinely accepts **two rows for the same underlying bug**, written up differently
and found by very different watson counts. The judge is asked for at most one MATCH per candidate and only
ever sees one `--judge-batch` slice of the rows at a time — a duplicate pair straddling two batches is
invisible to it by construction — so a lead that finds such a bug credits whichever twin the model happened to
name. Since the headline is stratified by rarity and the twins' watson counts differ, **the twin that gets
lost is the rare one**: the pipeline finds a rare bug and is scored as if it had not.

Equivalence is a property of the **ground truth**, not of the matcher, so it is decided GT-side, once per
contest, and stored as a file:

```
gt-dupes.tsv (next to truth.tsv)
# gt-dupes/v1 contest=<id> source=judge|manual driver=<driver> built=<iso8601>
DUP<TAB><sev_a><TAB><sev_b><TAB><confidence 0-100><TAB><one-line reason>
```

`gt-dupes.sh` builds it by judging every truth row against the rows AFTER it (upper triangle — no self-pairs,
half the calls) through the **unchanged** `mech-judge.sh` driver, request grammar and decision rule: the row
under test is sent in the `lead` slot as `R-<sev_id>` with its signature in `exploit`. So the same judge that
decides "did this lead find that bug?" decides "are these two rows the same bug?". `source=` distinguishes a
judged artifact from a hand-curated one; an unparseable reply produces **no** pair (no pair = no expansion =
the old behaviour) and is counted in a summary line.

**What the numbers mean (precision contract).** `score-match.py --gt-dupes <file>` unions the pairs into
classes and, when a lead matched any member, credits every member:

| quantity | effect |
|----------|--------|
| `gt_total`, every severity/rarity stratum total | **unchanged** — one entry per accepted GT row, exactly as the judging repo published it. Denominators are never collapsed. |
| `hits` | GT rows whose underlying bug the hunter found: matched directly **or** through another row in the same class. Both twins count, each in its own stratum — which is the point: the rare twin lands in the rare stratum. |
| `matched_leads` / `unmatched_leads` / `--per-lead` `LEAD` lines | **unchanged**. Expansion touches `row_hit` only, so one lead can never become N matched leads and the unmatched-lead triage queue keeps its meaning. |
| new trailers | `DUP<TAB><classes><TAB><expanded_hits>` plus one `DUPHIT<TAB><credited><TAB><directly_matched>` per expanded row. **`hits - expanded_hits` is exactly the pre-#1840 number, from the same replay.** |

**Report two numbers, and name the ruler.** Any headline scored with an artifact must be quoted as
`rare X/Y (Z via GT-equivalence)` alongside the ruler it was measured with — "mechanism judge (#1829) +
GT-equivalence crediting (#1840)" is not the same ruler as the token matcher, and a number measured under one
is not comparable to a number measured under the other. The published token-matcher baseline is **not**
re-derivable under the new rule (no artifact exists for those contests); what *is* guaranteed is that every
judged run whose decisions are archived replays both numbers from one cache.

**Guard rails against inflation** (a wrong pair would inflate exactly the stratum this exists to protect):

- `--gt-dupes-min-confidence` (default **85**, deliberately far above the judge's scoring gate) is applied at
  **scoring** time, so one archived artifact re-derives the expanded number, the unexpanded number and any
  threshold in between.
- A class larger than `--gt-dupes-max-class` (default 3) is **not** expanded at all, with a warning on stderr.
- Every pair carries a reason, and `DUP`/`DUPHIT` keep every expanded hit separable from the direct ones.
- A pair naming a `sev_id` absent from `truth.tsv` is a hard **exit 3** — a stale or wrong-contest artifact
  never silently mis-credits.

**Opt-in and default-off.** Without `--gt-dupes` no trailer is emitted and every existing scorecard
(`fixtures/mech-judge/`, `fixtures/score/`, `--self-test`) stays byte-identical.

**Cost shape.** About `N/2 x ceil(N/batch)` judging calls per contest — for a 30-row contest roughly 55 calls,
comparable to one scoring pass — but paid **once per contest**, independent of the lead count, and persisted
as a file. (Re-judging each lead against the remaining rows instead would be `O(leads x rows)` and re-paid on
every run.)

```bash
# build the artifact for one contest (operator-run: it costs judging calls; NOT part of --live):
dark-factory/bench/corpus-bench/run-corpus-bench.sh --dupes --id yieldoor --work <dir>

# or standalone, with the decision log archived next to it:
dark-factory/bench/corpus-bench/gt-dupes.sh <dir>/yieldoor/truth.tsv <dir>/yieldoor/gt-dupes.tsv \
  --log <dir>/yieldoor/gt-dupes-log.jsonl

# score with it (picked up automatically when <work>/<id>/gt-dupes.tsv exists; zero extra LLM calls):
dark-factory/bench/corpus-bench/run-corpus-bench.sh --score --id yieldoor --work <dir> --json \
  --judge cache --judge-cache <dir>/judge-cache.jsonl

# the same replay under the pre-#1840 ruler, for the two-number comparison:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --score --id yieldoor --work <dir> --no-gt-dupes \
  --judge cache --judge-cache <dir>/judge-cache.jsonl

# builder contract check (offline, no LLM):
dark-factory/bench/corpus-bench/gt-dupes.sh --self-test
```

`dark-factory/demo-mech-judge.sh` pins the whole thing on a second synthetic fixture (`fixtures/gt-dupes/`,
kept separate from `fixtures/mech-judge/` so the frozen #1829 cache keys cannot be re-baselined): the lost
rare twin (2/4, rare 0/2) and its recovery (3/4, rare 1/2) are both byte-exact, and so are the guard rails —
the name-sharing non-duplicate stays MISS, the `LEADS` trailer never moves, a stale artifact exits 3, a raised
merge bar re-derives the unexpanded number, and the builder pairs exactly the twins.

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

## Generalization measurement bench (#1763 G4)

The [#1763](https://github.com/Replikanti/agentis-colonies/issues/1763) epic generalized three yearn-hardcoded
pieces of the share-inflation catch by DETECTION (G1: core-dependency delegatecall-singleton) and by DIRECTIVE
(G2/G3: admin-guard + deferred-accounting) — always keeping yearn-ybold as the worked example, and always proven
not to regress the yearn catch. `generalization-bench.sh` is the measurement that asks the question those PRs
could not: **did that generalization actually TRANSFER to a target that is not yearn?**

It ORCHESTRATES the two frozen sibling harnesses above (it reimplements neither): `generation-recall.sh
--from-work` for the generator's reach on each target, and `deep-hunt-ab.sh --live` for the ON-vs-OFF High-recall
delta — scored, per selected contest, against that contest's own `truth.tsv`. It selects the corpus contests
whose ground truth is share-inflation / value-conservation / first-depositor class — the targets where G1-G3
SHOULD transfer if it generalized at all: **yieldoor, plaza, notional, mellow** (all share-issuing value-custody
vault protocols, verified present in `corpus.tsv`). `yearn-ybold` is NOT a selected target — it is the
REGRESSION ANCHOR.

The report is built to produce an **honest negative**: the aggregate TRANSFER verdict is computed over the
NON-yearn targets, and a zero recall is printed as `TRANSFER: NONE`, never smoothed. A **HARD regression gate**
(`--regression`, also run inside `--self-test` and before every `--live` report) refuses to report any transfer
number unless the yearn base still yields its deterministic FINDING under the generalized code — it runs the two
CI-enforced yearn source-guard demos (`demo-invariant-core-dep.sh` + `demo-invariant-vault-first-depositor.sh`)
and FAILS LOUD on any overfitting loss.

```bash
# deterministic self-test (what colony-lint runs; no network/LLM/forge — selection + orchestration + the HARD
# yearn regression gate over synthetic fixtures):
dark-factory/bench/corpus-bench/generalization-bench.sh --self-test

# standalone yearn-base regression gate:
dark-factory/bench/corpus-bench/generalization-bench.sh --regression

# real measurement over an already-staged corpus-bench --work dir (operator-run):
dark-factory/bench/corpus-bench/generalization-bench.sh --live --work <staged-work-dir> --json
```

`--live` is **never** the default and drives the real LLM/forge backend: run it ONLY after freed subscription
capacity, on a single non-contending value-custody zone — the same discipline as `deep-hunt-ab.sh --live`. It
consumes a `--work` dir the operator has already staged with `run-corpus-bench.sh --fetch --gt [--hunt]` (with
the generalized capability ON); the `generation-recall.sh` / `deep-hunt-ab.sh` / `score-match.py` primitives it
calls are all **unchanged** — this bench only orchestrates and reports. The fitness / genome-search "evolve"
driver (item 10 of the G4 plan) is a SEPARATE follow-up, deferred until this bench produces a baseline; per the
epic it will be the `pattern-evolver.ag` genome-search-over-a-bench-fitness-oracle idiom, not an `evolve_self()`
runtime builtin (which does not exist in this substrate).

## Usage

```bash
# deterministic safety property (what colony-lint runs; no network, no LLM):
dark-factory/bench/corpus-bench/run-corpus-bench.sh

# full real-backend measurement over the whole corpus:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --work /path/outside/repo --json

# one contest at a time, staged:
dark-factory/bench/corpus-bench/run-corpus-bench.sh --fetch --gt --id yieldoor --work <dir>
dark-factory/bench/corpus-bench/run-corpus-bench.sh --dupes --id yieldoor --work <dir>   # optional, #1840
dark-factory/bench/corpus-bench/run-corpus-bench.sh --hunt  --id yieldoor --work <dir> --backend flat-cyborg
dark-factory/bench/corpus-bench/run-corpus-bench.sh --score --id yieldoor --work <dir> --json
```

Point `--work` OUTSIDE the repo checkout (e.g. a scratch dir) — it clones 8 contest code repos + judging
repos and stages a full `run-zone-hunt.sh` output tree per contest, none of which belongs in version control.

Exit `0` = requested stage(s) ran (a low/zero recall is DATA, not a failure — same posture as
`run-capability-bench.sh`'s live stage); `1` = `--self-test` regressed; `2` = bad args; `3` = missing
prerequisite (repo not fetched yet, `agentis` missing, etc).

## Runtime bound: depth × zone-count (#1880)

`--zone-depth-cells` is a **per-zone** maximum, so the sweep admits `depth × zone count` depth cells and a
many-zone contest silently costs a multiple of what the flag reads. `--total-depth-cells N` (default **36**
on this bench) bounds the whole sweep of one contest instead: the effective per-zone allowance becomes

```
min(--zone-depth-cells, 36 / zone_count)      # integer division; the remainder is left unspent
```

so every zone of one scored contest is hunted on the same ruler. Worked examples:

| zones | `--zone-depth-cells` | effective per-zone depth | effect |
|---|---|---|---|
| 3 | 12 | 12 (`36/3 = 12`) | unchanged — a small contest never notices the bound |
| 9 | 12 | 4 (`36/9 = 4`) | the #1872 trap: 108 admitted depth cells become 36 |
| 9 | 4 | 4 (nominal already ≤ `36/9`) | unchanged — this is the #1879 config the bound is derived from |

**Where 36 comes from.** #1872 Stage C ran `notional` (9 zones) at `--zone-depth-cells 12` — up to 108 depth
cells, projected ~18–24 h — and #1879 named `--zone-depth-cells 4` on that same 9-zone contest as the
tractable configuration, i.e. 36 cells. So 36 admits exactly the configuration the operator already judged
tractable and leaves 2–3-zone contests at depth 12 completely unchanged. `tools/colony-lint.sh` pins the
value statically; move the bound and update this section in the same commit.

**The bound is exact in CELLS ONLY.** Per-cell wall clock varies (payload size, retries, backend), the same
caveat the #1830 cell budget already carries — the wall-clock figures above are advisory provenance, never
enforced. The bound is also an UPPER one: zones that turn out `no_brief` / `unscoped` / denied are counted in
`zone_count` but spend nothing, so a sweep can finish under the ceiling.

**Quote the effective depth, not the flag.** A depth recall number must be reported with
`budget.depth_per_zone` from that run's `<work>/<id>/zone-hunt-out/coverage/zone-coverage.json` (present only
when the ceiling is on), and each zone's coverage `detail` names the scaling. Passing `--total-depth-cells 0`
turns the ceiling OFF and restores the uncapped pre-#1880 behaviour byte-for-byte — that is how the #1858 /
#1860 / #1879 / #1831 arms stay exactly re-derivable.

The bench also passes the two #1830 breadth-side caps straight through (`--zone-cell-budget` /
`--run-cell-budget`, both default `0` = OFF = not forwarded). They carry **no** bench policy on purpose: a run
cell pool denies whole zones, which would pay for runtime out of the #1824/#1825/#1826 breadth-coverage
investment, whereas depth is trimmed to 0 before a single breadth class is dropped.

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

## Refuter → hunter constraint transfer (#1887)

A second feedback channel, the same shape as the one above but fed by the **refute gate** instead of the
scorer. Each REFUTED verdict now also states the GENERALISABLE standard the claim failed; those standards are
distilled into a knowledge corpus and read by the hunter of a **different** target:

```
refuter.ag CONSTRAINT|   →   run-refute.sh / verify-findings.sh   →   refute-to-knowledge.sh
(one per REFUTED verdict)    (refute-constraints.tsv, gate-ordered)    (refute-constraint entries)
                         →   REFUTE_CONSTRAINTS_JSON + run-discovery.sh knowledge import --replace
                         →   hunter.ag query_knowledge("refute-constraint", 32)
```

Building a corpus from an already-archived refute pass, then hunting a DIFFERENT contest with it:

```bash
# 1. LEARN — from a verify-findings.sh output dir (or one or more refute-constraints.tsv files directly)
dark-factory/refute-to-knowledge.sh \
  --from-verify <verify-out-dir> --out refute-constraints.json

# 2. ACT — the ON arm differs from the OFF arm by this ONE exported variable, nothing else
REFUTE_CONSTRAINTS_JSON=$PWD/refute-constraints.json \
  dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --id <held-out-contest> ...
```

**`--replace` is mandatory** (and always used by the feeder and by the importer): a re-import WITHOUT it
accumulates samples. With the variable unset the whole path is an **identity** — `query_knowledge` returns
nothing, the block renders empty and the hunter's prompt is byte-identical to today.

**Measurement rules (the acceptance contract, fixed before the code):**

- **Derivation and held-out targets must differ.** Constraints derived from contest X are only meaningful
  when measured on contest Y. Iterating the corpus text against the held-out target BURNS it — move the
  measurement to the next contest.
- **Metric = rare-bug recall** (GT rows with `found-by` ≤ 2, the existing `rare(1-2)` bucket). Confirm rate
  is secondary and does NOT constitute a pass: *a rise in confirm rate with flat rare recall is a FAIL and is
  recorded as one.* A hunter told what the gate rejects can learn to produce gate-pleasing claims; the block
  carries an explicit anti-Goodhart clause, and the metric is the real defence.
- **Equal cell counts.** The import adds no cells; unequal counts between arms VOID the comparison.
- **Quote the ruler with every number**, and state "one run per arm, stochastic" — the #1886 archive's
  convention. A flat-or-worse result is a legitimate, publishable outcome: the default stays off.

**Multi-target corpus (#1895) — the coverage gate is now the mandatory precheck.** The #1887 held-out came out
null because the notional-derived corpus and yieldoor's rare money classes did not overlap. Before spending any
fresh derivation or held-out A/B, run `refute-corpus-coverage.sh` — it computes the triple intersection
`{∪ derivation classes} ∩ {held-out hunted classes} ∩ {held-out rare(1-2) GT classes}` from checked-in / archived
data (manifest `cut -d'|' -f2`, `map-zones` scope.tsv field 4, class-tagged truth.tsv `found-by ≤ 2` rows) and
prints `COVERAGE-GATE: GO` only when it is non-empty; a `NO-GO` names the empty leg and exits non-zero, and no
expensive step runs on a `NO-GO` (`--self-test` pins a GO, the #1887 NO-GO repro, and a hunted-but-not-rare-GT
NO-GO; wired into `colony-lint.sh`). The corpus itself is still built the same way — multiple `--in` TSVs into
`refute-to-knowledge.sh`, which sums `samples` on a shared `(class, sentence)`, keeps distinct sentences
separate, and stays byte-stable modulo `created_ms` and independent of `--in` order (`demo-refute-feedback.sh`
3e/3f) — so the burn rule, equal-cell-count, rare(1-2)-primary and anti-Goodhart rules above are all unchanged;
multi-target is *just more `--in`*. Rationale, the C2 transfer axis, and the C2/C20 granularity crux:
[`bug-class-coverage.md`](bug-class-coverage.md#multi-target-constraint-corpus-1895).

`dark-factory/demo-refute-feedback.sh` pins the whole chain offline (report byte-identity with and without
the constraint line, the harvested TSV, the feeder's aggregation/determinism, and a REAL hunter cell's
prompt ON vs OFF); `demo-discovery-parallel.sh` block 19 pins default inertness, `knowledge.enabled`, the
`--jobs N == serial` equality WITH a corpus imported, and the fold's CB.

## Adding a contest

Append a row to `corpus.tsv` (`id  code_repo  judging_repo  scope_hint`) for any CONCLUDED Sherlock contest
whose judging repo is public. `extract-gt.sh` only needs the judging repo's `README.md` to follow the
`# Issue <H|M>-<N>: <title>` / `## Found by` shape used above — verify that shape holds (`grep -c '^# Issue
[HM]-' README.md` should equal the contest's published finding count) before trusting the extracted count.
