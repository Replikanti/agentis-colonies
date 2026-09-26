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
  corpus.tsv                    # manifest: id, code_repo, judging_repo, project_subdir, role, scope_hint
                                  #   (see header; `role` = dev|holdout, the #2231 hold-out policy below)
  fetch-corpus.sh                # clone code+judging repos for one/every corpus.tsv row (no re-hosting)
  extract-gt.sh                  # judging-repo README.md -> truth.tsv (ground truth + rarity + --code
                                  #   location anchors in column 6, #2215)
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
  triage.py                       # held-out per-row TRIAGE (#2262): per truth row, the evidence at its
                                  #   location + a PROPOSED class (operator confirms; never claims a HIT)
  exam/                           # held-out EXAM RUNNER (#2262 M2): contest-agnostic freeze / plan / stage /
    exam.sh                       #   run / drive / triage / kill + an offline self-test
    exam-helper.py                #   its python half (profile grammar, knob registry, zone filter, class
                                  #   injection, the #2231 checkout pre-flight) — exam.sh has no heredoc python
    profiles/                     #   knob profiles: control.env, exam.env, exam-plus.env, mock.env (self-test)
                                  #   + KNOBS (the env-clearing policy: extra names, PREFIX*es, !allowed)
  fresh-set.sh                    # fresh held-out set builder + training-memorization probe (#2263): discover
                                  #   concluded contests, GT/rare/code/contamination checks, sealed RESERVED.tsv
  fresh-set.py                    # its engine (stdlib python: listing client, pipeline, reserve, probe matcher)
  fixtures/
    sample-judging-readme.md      # tiny synthetic judging report (2 findings, rarity 2 and 9), carrying one
                                  #   of each #2215 anchor form: a `File:` block, a `#L23-L25` blob link and
                                  #   a `Vault:30` backtick ref
    expected-truth.tsv            # extract-gt.sh --code's expected 6-column output on the fixture above
    gt-locations/                 # the tiny Solidity source (src/Vault.sol) the fixture README's line
                                  #   anchors resolve against; do not reflow it (line numbers are the pin)
    score/                        # synthetic score-match.py fixture (truth.tsv + verified_findings.json +
                                  #   expected-scorecard.txt); the second self-test asserts recall 1/3, stable
                                  #   across --min-overlap 2 and 5 (no re-hosted Sherlock prose)
    score-locations/              # synthetic fixture for the #2215 pair-exact location credit: truth.tsv
                                  #   with column 6 + verified_findings.json + expected-scorecard.txt. Pins
                                  #   (a) a row credited ONLY by an anchor, (b) the CROSS-PRODUCT negative
                                  #   (file from one anchor, function from another -> MISS), (c) the
                                  #   LOC/LOCHIT trailers, (d) threshold independence. fixtures/score/ stays
                                  #   5-column on purpose: it is the byte-identity pin for the frozen rule
    hunt-fitness/                 # synthetic fixture for the fitness loop (#1711): truth.tsv +
                                  #   verified_findings.json (mixed `class=C6`/`C6` formatting, C6 high-
                                  #   precision, C3 mostly noise) + reorder-harness.ag (mirrors the agent)
    mech-judge/                   # synthetic fixture for the mechanism judge (#1829): truth.tsv + leads.json
                                  #   + BOTH pinned scorecards (expected-scorecard.token.txt = the documented
                                  #   defect, expected-scorecard.judge.txt = the corrected answer) +
                                  #   judge-decisions.jsonl (the recorded cache) + judge-stub.sh (offline
                                  #   judge backend; MECH_JUDGE_STUB_MODE=malformed for the fail-closed case)
    triage/                       # synthetic fixture for triage.py (#2262): truth.tsv (one row per class,
                                  #   incl. an empty-column-6 keyword row and an unanchored row), the full
                                  #   two-zone map/, one run tree run-core/ (verified breadth + invariant-hunt,
                                  #   REFUTED + ERROR gates, DISMISS/TRACE/INVARIANT lines, a .timeout cell),
                                  #   DECOYS (hunter.ag / refuter.ag source copies, a superseded
                                  #   discovery/core.attempt-1/) and the pinned expected-triage.{tsv,md}
    exam/                         # synthetic fixture for exam.sh self-test (#2262 M2): a two-contract Foundry-
                                  #   shaped project/, zones.fixture.txt + briefs.fixture.txt (two non-custody
                                  #   zones), truth.tsv, and agentis-stub.sh (dash-safe offline agentis: one
                                  #   CANDIDATE that the refuter refutes, STUB_ENV_DUMP / STUB_SLEEP seams)
    fresh-set/                    # synthetic fixture for fresh-set.sh --self-test (#2263): listing.json (seven
                                  #   future-dated contest pairs + one unpaired repo under `fixture-org`),
                                  #   repos/ (plain trees standing in for the clones), scan-root/ (a tiny fake
                                  #   repo text tree), corpus.tsv + ledger.tsv, probe-stub.sh (offline model),
                                  #   and the pinned expected-report{,.ledger,.probe}.tsv / expected-reserved.tsv /
                                  #   expected-probe.tsv / expected-cued.tsv
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
rarity  title  signature  locations` (signature = title + a truncated body snippet, the free-text signal
`score-match.py` matches on — same idiom as `../fixtures/*/truth.tsv`).

### Location anchors — column 6 (#2215)

The claim that "the compiled prose reliably names both the `.sol` basename and the function" turned out to be
FALSE often enough to bound the metric. The signature is a 1500-character truncation, and a watson routinely
expresses the location as a GitHub `#L<n>` permalink or a `` `Contract:LINE` `` backtick ref — neither of
which carries a function NAME a substring matcher can see. On `notional` that made 4 of 14 rare rows
structurally unmatchable, and it mis-credited a fifth: both arms of the #2213 A/B generated H-9 at
`CurveConvex2Token.sol:_exitPool`, and because H-9's prose names only the Curve-side symbols the lead was
credited to its CONSENSUS twin M-10 while the RARE row scored MISS.

Column 6 resolves those anchors GT-side into space-separated, deduped `<Basename.sol>:<function>` pairs, read
from the **FULL** issue block (not the truncated signature — the location is usually what the truncation cut
off), by three mechanisms:

| mechanism | example | needs `--code`? |
|---|---|---|
| `File:` marker above a pasted snippet | `File: Vault.sol` then `function withdraw(` | no |
| GitHub blob permalink with a line anchor | `.../src/Vault.sol#L23-L25` | yes |
| backtick line ref | `` `Strategy:207` ``, `` `Strategy.sol#L207` `` | yes |

`extract-gt.sh <readme> <out> [--code <project-root>]` — `--code` is the cloned audited project root
(`<work>/<id>/code/<project_subdir>`), which is what turns a LINE into a function NAME: the **enclosing**
function of the first line, plus every function **declared inside** an `#L<n>-L<m>` range (a range routinely
opens on the doc comment above the function it quotes). An ambiguous basename (two paths, e.g. a mock and the
real contract) resolves to nothing rather than guessing, and a basename with no function is never emitted —
a half-anchor would be an unanchored file match, which is exactly what #1697 refuses to do.
`run-corpus-bench.sh --gt` passes `--code` automatically when the clone is present; without it the extractor
still emits column 6 with only the `File:`-block anchors (a clean degradation, never an error).

**Columns 1-5 are byte-identical to the pre-#2215 output** — the truncation rule is deliberately unchanged
(verified by `diff` against the archived `runs/2213-operationalize-ab/<contest>/truth.tsv`), and a 5-column
`truth.tsv` still scores exactly as before. `extract-gt-codehawks.sh` has its own row shape and is NOT touched
by this: the CodeHawks path has no location column yet.

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

There is a third, cheaper corrective that applies under `--judge off` and does not replace either ruler:
**GT location anchors** (#2215, truth.tsv column 6). A lead also HITs a row when the lead's OWN
`(file basename, function)` equals one of that row's anchors — **pair-exact**: file and function must come
from the SAME anchor, never a cross product across two of them, which makes this rule strictly TIGHTER than
the prose rule (any co-occurrence anywhere in 1500 characters). It fixes the reachability half of the
name-divergent failure mode above at zero LLM cost, and it does NOT fix the mechanism-blindness: a
name-coincident candidate at an anchored location still scores HIT, so a claim that a SPECIFIC bug was found
must be read off the cell log, never off the scoreboard.

Every location credit is separable. `score-match.py` emits `LOC<TAB><anchored_rows><TAB><loc_credited>` plus
one `LOCHIT<TAB><sev_id><TAB><lead location>` per row credited ONLY by an anchor, so `hits - loc_credited`
recovers the frozen #1697 number **from the same replay** (the #1840 `DUP`/`DUPHIT` idiom). The trailers are
emitted only under `--judge off` and only when at least one row is anchored.

**Reachable rare.** `generation-recall.sh` prints `reachable rare = k/N` per contest and in the aggregate: the
rare rows that carry a resolvable anchor at all. A rare row the matcher cannot resolve is a denominator the
hunter cannot move, so a headline quoted without it invites reading a MATCHER bound as a CAPABILITY bound.
(On a legacy 5-column `truth.tsv` the line degrades to "signature names >= 1 `.sol` basename" and says so.)

**The quote-both rule (mandatory).** Any single-arm rare number taken from this corpus states the frozen
primary and the `+locations` number side by side, plus `reachable rare` — e.g. "`notional` control rare 1/14
primary, 5/14 with GT location anchors, reachable 14/14". This is the #1841 principle: a number without its
ruler is not comparable to any other number.

**Defaults.** Location anchors are **ON by default** — they are a free by-product of `extract-gt.sh --code`,
cost zero LLM calls and are deterministic, and the credit they add is always subtractable. `--gt-dupes`
(#1840) stays **opt-in**: its artifact is judged once per contest and therefore costs LLM calls. The two are
complementary but overlapping — on `notional` the H-9/M-10 equivalence pair expands **0 rows** once the
anchors exist, because H-9 is credited directly (see `runs/2213-operationalize-ab/README.md`).

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

**Tier 2 is scored, and reported, separately (#2217).** `run-discovery.sh --tier2` lifts the checks a cell
DERIVED but never settled (`unresolved` / `uncited`) into a top-level `tier2[]` array, each with a location
derived by regex from the check's own text. Those are weaker evidence than a candidate the model chose to
file, so they never touch a headline: `hypotheses-to-leads.py` projects them only under `--include-tier2` (as
leads flagged `"tier": 2`), and `generation-recall.sh` scores TWICE — the PRIMARY generation-recall is
computed from a lead set the adapter emitted WITHOUT the flag and therefore containing no tier-2 lead at all,
and the tier-2 contribution is printed on its own line (`tier-2 (SECONDARY, #2217): +k`, `tier2_hits` /
`tier2_leads` in `--json`) as the GT rows credited ONLY once tier-2 leads are added. Both sides of that
subtraction go through the same ruler (same `--min-overlap` / `--judge` / `--gt-dupes`), so the secondary
number is a delta and never a second metric. `score-match.py` is UNCHANGED: it ignores the `tier` key and
scores a tier-2 lead by the same location-first rule, which is exactly why the separation has to be made in
the LEAD SET rather than in the scorer. Reading rule: a tier-2 hit says the pipeline NAMED the location in a
check it could not settle — it is mechanism-blind at a higher rate than a tier-1 hit, so "we found it" is
still an operator read of the cell log, never a scoreboard read.

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

## Held-out exam: runner + per-row triage (#2262)

A held-out exam is scored per RARE row, and until now every row was scored by hand: read the truth row, find
candidates and verified findings at the same function, grep the cell logs for it, read the DISMISS lines and the
refute verdicts, decide HIT / MISS and the MISS cause. `triage.py` (M1) mechanises the **reading**, never the
decision: for every truth row it collects the evidence at the row's location and **proposes** a class with the
evidence lines next to it. The operator confirms in the `operator_class` column. `exam/exam.sh` (M2) is the
reusable runner that produces the run trees; run-window attribution and VOID handling follow in M3.

**Inputs.** `--truth <truth.tsv>` (the 5/6-column `extract-gt.sh` shape; the 4-column CodeHawks shape is refused)
and one or more run trees — `--run [LABEL=]<zone-hunt-out>` or `--run-root <dir>`, which collects every dir
holding `discovery/` below it (e.g. an exam root's `arms/<contest>/<zone>/<arm>-r<N>/<contest>/zone-hunt-out`
trees, labelled by their relative path). `--map <zones.json>` (alias `--zones-json`) should be the FULL frozen
map: without it the union of the run trees' own `map/` is used, and a staged single-zone map under-reports
`scope-out-of-map` and `unmeasured` (the header says so). `--scope` defaults to the `scope.tsv` next to `--map`.
`--unmeasured <zone>:<reason>` forces a zone (a VOID run) to unmeasured. `--rows rare` / `--rare-only` keeps the
rare tier (`--rare-max`, default 2). `--out <dir>` writes `triage.tsv` + `triage.md`.

**Where "at the location" comes from.** Anchors are truth.tsv column 6, read with score-match.py's own
`parse_row_locations()`, and every location is matched with its `lead_location()` / `lead_matches_locations()`
(+ `hypotheses-to-leads.py`'s `bare_codefile()`) — imported read-only, so triage's "at the location" is exactly the
scoreboard's #2215 pair-exact rule. When column 6 is empty, a deterministic keyword fallback reads title +
signature: `Contract::fn` / `Contract.sol::fn` / `Contract.fn(` become `keyword-pair` anchors, otherwise backticked
`fn(` tokens become function-only `keyword-fn` anchors (stoplisted: require/revert/emit/abi/keccak256, ERC20 verbs).

**What is read.** Only real output: `discovery/discovery-results.merged.json` (candidates + `tier2[]`),
`verify/verified_findings.json` (`verified[]` of any `source`, `refuted[]`, `out_of_scope[]`, `errors[]`),
`verify/gates*/<n>_*/` (`candidate.manifest`, `verdict.txt`, `REFUTE-GROUND|` only from
`refute-out/run/refute_*.log`), the cell logs `discovery/<zone>/run/hunt_*.log` + their `.untraced-attempt-<n>` /
`.rubric-attempt-<n>` companions (`DISMISS|` lines and word-boundary mentions of the function; `.timeout` /
`.novalid` markers give the cell status), and `deep-hunt/*/run/invariant_*.log` (`INVARIANT|` lines). The
`hunter.ag` / `refuter.ag` source copies every RUN dir holds carry the same sentinel literals and are never read;
a superseded `discovery/<zone>.attempt-<n>/` is excluded unless `--include-superseded`. The fixture's decoys fail
the self-test if either rule regresses.

**Class vocabulary, first match wins** (over all anchors of the row):

| # | class | when |
|---|---|---|
| 0 | `unanchored` | no column-6 anchor and no keyword anchor — never guessed |
| 1 | `HIT-candidate` | `level=verified`: a `verified[]` entry at an anchor; else `level=unassessed`: a candidate whose gate did not refute it (REAL-not-kept / ERROR / skipped / no gate); else `level=tier2`: an unrefuted tier-2 record |
| 2 | `refuted` | candidates at an anchor, every one refuted (non-confirm gate verdict, `refuted[]`, `out_of_scope[]`) |
| 3 | `found-dismissed` | a `DISMISS\|` line at an anchor and no candidate |
| 4 | `scope-out-of-map` | `sub=file`: no anchor file in any zone's `files[]`; `sub=slice`: every scope line for the file is sliced and none lists the function, an owning zone ran, and no log / `INVARIANT\|` target mentions it (the slicer's same-file callee closure can pull unlisted helpers in, and a zone that never answered cannot show a function was unseen) |
| 5 | `unmeasured` | no owning zone was measured: no run tree, `--unmeasured`, or every cell `.timeout` / `.novalid` |
| 6 | `generation` | an owning zone ran; `sub=examined` when a cell log or an `INVARIANT\|` target (ANY verdict — a CLEAN invariant at the location is an examination, not a HIT) mentions the function, else `sub=unseen` |

**Reading rule.** Every class is a PROPOSAL. Like the #2215 anchors, triage is **mechanism-blind**: a
name-coincident candidate at an anchored location proposes `HIT-candidate` all the same, and a mention is a name,
not an examination of the bug. `HIT-candidate` is never a HIT until the operator column says so, and the markdown
prints no recall number. A HIT claim is read off the evidence lines (the candidate text, the cell log), never off
the proposed class.

```bash
# deterministic self-test (what colony-lint runs via demo-holdout-exam.sh; no network/LLM/forge):
dark-factory/bench/corpus-bench/triage.py --self-test

# triage every zone tree of an exam arm against the frozen base's full map (rare rows only):
dark-factory/bench/corpus-bench/triage.py --truth <base>/<id>/truth.tsv --run-root <exam>/arms/<id> \
    --zones-json <base>/<id>/map/zones.json --rare-only --out <dir> [--contest <id> --corpus corpus.tsv]
```

### Exam runner (`exam/exam.sh`, #2262 M2)

The runner replaces the host-only harness scripts. It holds **no contest fact**: everything contest-, arm- or
host-specific is data — the frozen base's `freeze.meta`, a profile file, and a plan TSV that lives outside the
repo. All roots are arguments. It only invokes the pipeline (`map-zones.sh`, `gen-briefs.sh`,
`lib/zone-coverage.py`, `run-zone-hunt.sh`) from the tool checkout it is given, and `triage.py` from this tree.
Needs bash, python3, git, GNU `timeout`, `setsid` and `/proc` (Linux), plus `bwrap` for a live backend (the hunt
sessions must run sandboxed); exits 3 when one is missing.

End to end (every `<...>` is the operator's):

```bash
X=dark-factory/bench/corpus-bench
# 1. fetch code + judging + truth.tsv into <base>/<id>/ (run-corpus-bench.sh; fresh-set.sh for a fresh set)
$X/run-corpus-bench.sh --fetch --gt --id <id> --work <base>
# 2. freeze map + briefs ONCE, from a pinned CLEAN tool checkout (never the live dev tree)
$X/exam/exam.sh freeze --base <base> --contest <id> --checkout <tool-checkout> --profile control \
    --code-subdir <project dir under code/>            # or --project-roots <r1,r2|auto> for a multi-project clone
# 3. a plan: one row per frozen zone (or --zones a,b / --whole for one whole-contest `_all` row); review it
$X/exam/exam.sh plan --base <base> --contest <id> --arm exam --repeat 1 --profile exam \
    --checkout <tool-checkout> > <plans>/exam-r1.tsv
# 4. drive it (sequential, locked, resumable); logs/<plan>.progress has START/END per row
setsid $X/exam/exam.sh drive --root <exam-root> --plan <plans>/exam-r1.tsv [--resume] &
# 5. the drive ends with the triage hand-off; re-run it any time for one arm:
$X/exam/exam.sh triage --root <exam-root> --contest <id> --arm exam --repeat 1   # -> <exam-root>/triage/
# abort: kill everything that runs under the exam root (or one arm dir; never this process or its ancestors,
# never a path with fewer than three components); --dry-run lists it first
$X/exam/exam.sh kill --path <exam-root> --dry-run
```

**freeze** refuses a dirty checkout and one whose prompt-visible files carry `corpus-bench` or a delimited
finding-id token (the colony-lint #2231 rules, via `fresh-set.py`'s `prompt_visible()`), runs `map-zones.sh` +
`gen-briefs.sh` from the checkout with the profile's `BACKEND` / `MODEL`, refuses mechanical-fallback briefs
(exit 5, `--allow-fallback-briefs` overrides), then greps `map/` + `briefs/` for the bench name, finding ids,
` GT `, `judging`, audit-platform names and every `--deny-pattern` (exit 4; pass the contest's own name here),
and writes `freeze.sha256` (every map/brief file) + `freeze.meta` (`checkout_commit model backend code_dir_rel
project_roots map_roots profile frozen_utc`). A frozen base is never written again: a second freeze needs
`--force`, and `stage` refuses a base whose files drifted from `freeze.sha256`.

**Exam root layout** (ground truth lives only in the sibling `_gt/` view, never next to anything the hunt is
pointed at; score one arm with `generation-recall.sh --from-work <arm-dir>/_gt --id <contest>`):

```
<root>/MANIFEST.tsv                               one row per ATTEMPT, append-only, header line
<root>/logs/<plan>.{lock,progress,done,log,heads} driver PID lock, START/END lines, final marker, driver log,
                                                  checkout HEAD pins; <plan>.snapshot-*/ = the re-exec copy
<root>/arms/<contest>/<zone>/<arm>-r<N>/          stage.meta stage.log run.meta run.log deep.log .done
                                                  run.pid (while alive) breadth.env deep.env env.cleared
    <contest>/{code -> base, zone-hunt-out/}      what the hunt is pointed at
    _gt/<contest>/{truth.tsv, judging -> base, zone-hunt-out -> ../../<contest>/zone-hunt-out}
<root>/triage/<contest>-<arm>-r<N>.{tsv,md}
```

**run** = breadth `timeout HARD_STOP_S run-zone-hunt.sh --rehunt-gaps` over the staged zone with the profile's
`env.*` knobs, then — when `DEEP_PASS=1`, `verify/verified_findings.json` exists and the breadth call was not
hard-stopped nor killed — STAGE 4.5 as a second `timeout` call with `--deep-hunt --deep-hunt-only` over the SAME
`--out` and the `deep.*` knobs. `run` refuses a repo root or `--out` that holds a `truth.tsv` / `judging/`, and
writes `run.pid` while alive (a second writer is refused by `run`, `stage` and `drive`). A hard stop (rc 124), a
call killed from outside (rc >= 128, STAGE 4.5 is then never started) or a TERM/INT to `run` itself kills
everything left under the arm dir. An EXIT trap always writes `run.meta` (UTC `start`/`end`/`rc`,
`deep_start`/`deep_end`/`deep_rc`, checkout commit + dirty flag, model, knobs, the EFFECTIVE knob env of both
calls as `breadth_env` / `deep_env` — pass.<NAME> values masked —, profile name + sha256), the arm's `.done`
and one `MANIFEST.tsv` row — also after a crash. A multi-root
freeze hunts from the clone root with the frozen `--project-roots`. The three Claude Code killswitches
(refusal-fallback off, model-fallback off, session persistence on) are exported for every call.

**drive** runs stage + run per plan row, one live arm at a time, under `logs/<plan>.lock` (liveness from
`ps`; a stale lock is removed). It re-execs from a snapshot of `exam/` (bash reads a script incrementally, so a
pull mid-plan would otherwise corrupt the run; shipped profiles resolve inside the snapshot), pins each
checkout's HEAD at first use and refuses (`rc=refused-head-moved`) a row whose checkout moved. Without `--resume`
it refuses a plan whose arm dirs exist; with it, rows with a `.done` are skipped (an unfinished arm dir is moved
aside as `<arm>-r<N>.partial-<k>`, never deleted). A failed row is recorded and the plan continues; nothing is
re-run automatically. A row whose `run` is still alive (e.g. after the driver was SIGKILLed) is refused
(`rc=refused-live-run`), never moved aside. Each `run` is its own process group (`setsid`): a TERM/INT to the
driver stops that group, waits for run's cleanup and exits. At the end it hands every (contest, arm, repeat) of
the plan to `triage` (finished zone trees as `--run <zone>=<out>`, a hard-stopped or killed one as
`--unmeasured <zone>:<hard-stop|killed>`, the frozen FULL map). `kill --path` also stops the run controller of
every arm under the path (found by its `run.pid`: its args name the root and its cwd is elsewhere) and resolves
the path physically (`pwd -P`), as `/proc/<pid>/cwd` is.

**Profiles** (`exam/profiles/*.env`; pass a shipped name or a path):

| line | meaning |
|---|---|
| `# ...` | comment |
| `KEY=VALUE` | runner key: `BACKEND` (mock/flat-cyborg/claude), `MODEL` (required unless mock), `JOBS`, `DEEP_JOBS` (default JOBS), `HARD_STOP_S` (per call), `DEEP_PASS` (0/1), `INJECT_CLASSES` (`C24,C6`: appended once each to the staged zone's scope.tsv class field), `SCOPE_DOCS` (`auto` or `code:<path under the contest's code/>`, → `--scope-docs`). Any other bare key is exit 2. |
| `env.<NAME>=<v>` | exported into the breadth call only |
| `deep.<NAME>=<v>` | exported into the STAGE 4.5 call only |
| `pass.<NAME>` | inherit `<NAME>` from the caller's environment (must be set; the value is never in the file) |

Values reject `$`, backticks, quotes and backslashes; an empty `env.`/`deep.` value is refused (an empty knob is
still SET for `getenv()`). **Knob hygiene:** the operator's environment is inherited, but every pipeline call
gets `env -u` for every knob candidate — every env name the checkout's pipeline READS (derived at run time by
grepping its `.sh`/`.py`/`.ag` for `${NAME:-}`-style expansions, `os.environ`/`os.getenv` and `getenv()`), every
`env.`/`deep.`/`pass.` name of the shipped profiles, the NAME lines of `profiles/KNOBS` and every exported
variable matching one of its `PREFIX*` lines (`DF_*`, `LLM_*`, `FORK_*`, `FLAT_CYBORG_*`, `CLAUDE_CODE_*`, ...) —
minus its `!NAME` host plumbing / auth lines, the killswitches and the profile's own `pass.<NAME>`s. So neither
an exported `SEVERITY_RUBRIC=1` nor an `LLM_MAX_DISCOVERY_CELLS` / `FORK_URL` nobody listed reaches an arm
("pass nothing when off"); a new knob is covered automatically. `DF_NO_SANDBOX` is refused outright (in the
caller's shell: exit 3; in a profile: exit 2) — a held-out run never disables the hunt sandbox. Shipped: `control` (defaults, no knob), `exam` (the
final-exam set: `SEVERITY_RUBRIC` + `GROUND_EVIDENCE`, STAGE 4.5 with `DEEP_HUNT_REACH` + `DEEP_HUNT_PROMISES`,
`JOBS=2`), `exam-plus` (exam + `FUNCTION_COVERAGE`, `BREADTH_PROMISES`, `SCOPE_DOCS=code:README.md`, and the
deep-hunt budget knobs; sized for a whole-contest arm), `mock` (the self-test). No profile names a contest or a
path.

`exam.sh self-test` (run by `demo-holdout-exam.sh`, so by colony-lint) drives a mock two-zone exam end to end
over `fixtures/exam/` with the stub agentis and `--backend mock`: profile grammar, freeze (both contamination
gates, the dirty-checkout refusal, the no-overwrite rule, a multi-root clone), plan, stage (filter, injection
idempotence, drift refusal), run (breadth vs STAGE 4.5 knob routing — a leaked `DEEP_HUNT_REACH` would make the
breadth call exit 2 —, knob hygiene against an exported `SEVERITY_RUBRIC=1`, a leak probe exporting every
pipeline-read env name plus unlisted prefix names as a sentinel, the `DF_NO_SANDBOX` refusal, ground truth
invisible to the hunt, a hard stop), a running arm (stage / `drive --resume` refuse it, `kill --path` stops its
controller, a breadth killed from outside never starts STAGE 4.5, TERM to `drive` stops its run), drive (live and
stale lock, snapshot re-exec, `--resume`, HEAD pin, the triage hand-off) and kill-by-path (exact match, through a
symlink).

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

## D3 corpus rare-recall A/B + transfer + default-flip ratchet (#2157)

Milestone D3 of epic #2130 measures what the D1 **CALLEE-TRUST** directive (#2145) and the D2 **vector-hunt**
lens (#2156) actually buy on the RARE tier, then ratchets each default ONLY on a gain that survives a transfer
contest. This scaffolding PR ships the OFFLINE, CI-deterministic harness; the expensive live corpus A/B and the
default-flip are separate later steps (recorded on #2157).

**The two arms.** `callee-trust-ab.sh` runs `run-zone-hunt.sh` over the SAME target twice:

- **control** — `CALLEE_TRUST=0`, no `--vector-hunt`: the pre-D1/D2 pipeline. `CALLEE_TRUST=0` forces the #2145
  directive off even where the settable-callee detector fires (a `getenv` gate added to `hunter.ag`, default ON
  = byte-identical when the env is unset; registered on `run-discovery.sh`'s `exec.env_passthrough` so it is not
  silently inert — the #1426/#1428 failure mode).
- **treatment** — `CALLEE_TRUST=1`, `--vector-hunt`: D1 surfaces the attacker-controlled-callee `CALLEE-VECTOR`
  candidate; D2's STAGE 4.6 harvests it and forge-verifies it, merging only PoC-PASS vectors as
  `source=vector-hunt`.

The run labels are FIXED before any run (never assigned after the numbers). `--self-test` (CI-safe, mock
backend, no network/LLM/forge) proves the mechanism: control misses a RARE truth row that treatment catches
(`score-match.py` HIT vs MISS), rare-recall Δ=+1, offline. `score-match.py` and `generation-recall.sh` are
reused UNCHANGED.

**Per-step model routing (honest — the D2 live-gate finding).** Fable 5.1 refuses weaponized-PoC authoring
under its `[cyber]` safeguard, so NO arm is single-model end to end. The **analysis/enumeration** stages
(`map-zones` / `gen-briefs` / `run-discovery`+`hunter.ag` / vector enumeration / `run-refute`) run on **Fable
5.1** with `CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1` + `CLAUDE_CODE_NO_MODEL_FALLBACK=1` +
`CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1` (bwrap via `lib/claude-sandboxed.sh`); the **PoC-authoring /
forge-verify** stages (`run-poc.sh`, `run-vector-hunt.sh`'s per-vector PoC) run on **Opus 4.8**. The
**headline** is rare(1-2) **GENERATION**-recall (`generation-recall.sh`, scored from pre-refute candidates —
D1's clean, pure-Fable number); the **secondary** is rare(1-2) **VERIFIED**-recall (`run-corpus-bench.sh
--score` — D1+D2, "Fable analysis + Opus PoC-verify"). `model-attribution.py` reads the persisted transcripts
and proves the split held per stage: an analysis stage that silently fell back to Opus comes back
`CONTAMINATED`, which VOIDS the D1 capability claim.

**Transfer-eligibility gate.** Reuse `refute-corpus-coverage.sh` to avoid the #1887 null-by-construction trap
(a corpus with zero rare-GT rows in the reachable class cannot move the metric):

```bash
dark-factory/bench/corpus-bench/refute-corpus-coverage.sh \
  --derivation d1d2=C8,C6,C10,C11,C2,C16 \
  --held-out-scope <contest>/map/scope.tsv \
  --held-out-truth <contest>/truth.tsv --rare-max 2
```

`COVERAGE-GATE: GO` means the contest's rare(1-2) GT class intersects the attacker-controlled-callee class set.
**Pre-register before any arm runs:** designate one GO contest as the MEASUREMENT target and a *different* GO
contest as the TRANSFER target. The gain counts ONLY if the rare-recall Δ is positive on the measurement target
AND independently positive on the transfer target — a gain that vanishes on transfer is reachability, not
capability (transfer-null).

**Ratchet (two independent defaults, each gated on catches not wiring).**

- **D1** (`CALLEE_TRUST`, this PR makes the toggle default ON = byte-identical to today) — gate on rare
  **generation**-recall (D1 is a generation reframe; verified-recall is confounded by the Opus PoC step). Gain
  survives transfer → default stays ON (documentation ratifies it, no code change). No gain / transfer-null →
  a SEPARATE PR flips the `hunter.ag`/`run-discovery.sh` default to OFF (D1 becomes opt-in), an honest negative.
- **D2** (`--vector-hunt`, default OFF) — gate on rare **verified** (PoC-PASS) recall. Gain survives transfer →
  a SEPARATE PR flips `run-zone-hunt.sh`'s `VECTOR_HUNT=0` default (per the STAGE 4.5 refute-gate default-ON
  precedent). No gain / transfer-null → stays opt-in, honest negative.

The default-flip (or opt-in revert) is a SEPARATE small PR after the live verdict is recorded on #2157 — never
in this scaffolding PR (keeps CI green and separates measurement infra from the measured decision).

**#2160 fold-in.** #2160 (depth-log CALLEE-VECTOR harvest) only ADDS candidates to STAGE 4.6, so the D2
verified-recall Δ measured with #2160 landed is a ceiling and without it a floor. Land #2160 before the live D2
measurement; if not merged in time, run anyway and quote the D2 Δ as a floor.

**Reproduce (offline).**

```bash
# the A/B mechanism (mock backend, control-vs-treatment rare-recall Δ=+1)
dark-factory/bench/corpus-bench/callee-trust-ab.sh --self-test
# per-stage model attribution over the fixture transcripts (Fable / Opus / fallback)
dark-factory/bench/corpus-bench/model-attribution.py --self-test
# the CALLEE_TRUST toggle byte-identity + sentinel suppression (real hunter.ag under mock)
dark-factory/demo-callee-trust-lens.sh
# the run-corpus-bench.sh --vector-hunt / --callee-trust pass-throughs
dark-factory/bench/corpus-bench/run-corpus-bench.sh --self-test
```

**LIVE (operator step — expensive, NOT CI).** After this PR merges and #2160 lands: coverage-gate the corpus to
pick the pre-registered measurement + transfer contests; run per arm one run per contest via `callee-trust-ab.sh
--live` (or `run-corpus-bench.sh --live --id <contest> --callee-trust <0|1> [--vector-hunt] --backend
flat-cyborg`) with the Fable-analysis / Opus-PoC routing, sandbox, and the fallback killswitches; run
`model-attribution.py` over the persisted transcripts to prove the analysis stages were 100% Fable and the PoC
stages Opus; score with `generation-recall.sh` (rare generation-recall) and `--score` (rare verified-recall).
Archive under `runs/2157-corpus-callee-trust-ab/` (measurement) and `runs/2157-<held-out>-transfer/` (transfer),
each a README following the #1887 template (arm mapping fixed before numbers, ruler stated, attribution table,
verdict + ratchet decision, scrubbed paths). Then open the ratchet PR per the verdict.

## Operationalize-lens generation-recall A/B (#2213)

The recipe the #2213 M2 measurement used, reproducible from this repo alone. It adds **no harness**: both
arms enter STAGE 3 through `run-zone-hunt.sh --rehunt-gaps` over a **frozen `map/` + `briefs/`** produced
ONCE per contest, so zone-mapper and brief-writer stochasticity are removed and `OPERATIONALIZE_LENS` is the
single variable. Archive of the run it produced: [`runs/2213-operationalize-ab/`](runs/2213-operationalize-ab/).

Ruler (identical in every arm, and quoted with every number): `--backend flat-cyborg --model <pinned id>
--jobs 1`, depth OFF (no `--zone-depth-cells` / `--total-depth-cells`), no `--deep-hunt`, no `--vector-hunt`,
scoring `--judge off --min-overlap 2` with no `--gt-dupes`, plus
`CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1 CLAUDE_CODE_NO_MODEL_FALLBACK=1 CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1`.
Depth OFF is deliberate: depth cells are planned FROM breadth candidates, so with depth on the two arms could
legitimately plan different cell sets and cell-count parity would be unenforceable.

```sh
DF=<repo>/dark-factory ; RUN=<run-root> ; ID=<contest> ; M=<model-id>

# 0) FREE pre-flight — assert the staged recipe consumes the frozen artifacts before spending anything.
#    Run steps 2-5 once with --backend mock and check the log says
#    "--rehunt-gaps: reusing <map> + <briefs>; STAGE 1/2 skipped" and that every zone is hunted.

# 1) fetch + ground truth (no LLM)
bash "$DF/bench/corpus-bench/run-corpus-bench.sh" --fetch --gt --id "$ID" --work "$RUN/base"

# 2) freeze STAGE 1/2 ONCE per contest — the artifacts BOTH arms will share, byte for byte
CODE="$RUN/base/$ID/code/<project_subdir>"
#    #2255 multi-root row (project_subdir = a comma list of project roots): CODE is the CLONE ROOT and the
#    roots are passed explicitly, so every root is mapped and every path in map/ stays clone-root-relative:
#      CODE="$RUN/base/$ID/code"
#      bash "$DF/map-zones.sh" --repo "$CODE" --project-roots <list> --out "$RUN/base/$ID/map" ...
bash "$DF/map-zones.sh"  --repo "$CODE" --out "$RUN/base/$ID/map" --backend flat-cyborg --model "$M"
bash "$DF/gen-briefs.sh" --zones "$RUN/base/$ID/map/zones.json" --scope "$RUN/base/$ID/map/scope.tsv" \
                         --out "$RUN/base/$ID/briefs" --repo "$CODE" --backend flat-cyborg --model "$M"
# Check the gen-briefs summary line for "N brief(s) FAILED validation ... mechanical fallback used".
# A fallback brief is a ~2-3 kB stub against ~8-21 kB for a real one; regenerate those zones before
# freezing. The base is shared by both arms, so repairing it is never an arm asymmetry.

# 3) cost pre-flight (offline, no LLM): the EXACT per-arm breadth cell count, before spending
#    (multi-root: same loop with the clone-root CODE; subsystem names are qualified `<root>/<name>`)
for SUB in $(grep -v '^#' "$RUN/base/$ID/map/scope.tsv" | cut -d'|' -f1 | sed 's/ *$//'); do
  bash "$DF/run-discovery.sh" --repo "$CODE" --scope "$RUN/base/$ID/map/scope.tsv" \
       --only "$SUB" --list-cells | grep -c '^CELL|'
done   # SUM these; stop and re-scope if the total exceeds the agreed ceiling

# 4) stage a take: copy the frozen artifacts in, then mark EVERY zone a gap
TAKE="$RUN/take-1-control/$ID"
mkdir -p "$TAKE/zone-hunt-out/coverage"
cp -a "$RUN/base/$ID/map" "$RUN/base/$ID/briefs" "$TAKE/zone-hunt-out/"
cp "$RUN/base/$ID/truth.tsv" "$TAKE/truth.tsv"
python3 "$DF/lib/zone-coverage.py" init \
  --zones "$TAKE/zone-hunt-out/map/zones.json" \
  --out "$TAKE/zone-hunt-out/coverage/zone-coverage.json" \
  --zone-list "$TAKE/zone-hunt-out/.zone-list.tsv" \
  --repo "$ID" --commit "$(git -C "$DF" rev-parse HEAD)" --zone-cell-budget 0 --run-cell-budget 0

# 5) run the arm. CONTROL = the variable UNSET (the shipped gate is == "1", so unset is the production
#    default a flip would change); TREATMENT = prefix `env OPERATIONALIZE_LENS=1`.
#    Multi-root: pass the same clone-root CODE; the frozen zones carry their `root`, and --rehunt-gaps exits 3
#    if --repo is not the clone root the map was made against.
bash "$DF/run-zone-hunt.sh" --repo "$CODE" --out "$TAKE/zone-hunt-out" --rehunt-gaps \
     --backend flat-cyborg --model "$M" --jobs 1 --agentis agentis

# 6) score (deterministic, zero judge LLM calls)
bash "$DF/bench/corpus-bench/generation-recall.sh" --from-work "$RUN/take-1-control" --id "$ID" \
     --judge off --min-overlap 2
```

**Arm-activity gate — verify BEFORE trusting any number.** Grep the **cell logs**, never the discovery tree:
each zone's `run/` holds a copy of `hunter.ag`, whose SOURCE contains both `OPERATIONALIZE|` and `OPCHECK|`
literals, so a tree-wide grep reports sentinels in the control arm and looks like a leaked flag.

```sh
CELLS=$(find "$TAKE/zone-hunt-out/discovery" -name 'hunt_*.log')
cat $CELLS | grep -c '^[[:space:]]*OPERATIONALIZE|'   # treatment: == cell count ; control: MUST be 0
cat $CELLS | grep -c '^[[:space:]]*OPCHECK|'          # treatment: > 0 (dosage) ; control: MUST be 0
python3 "$DF/bench/corpus-bench/model-attribution.py" --stage discovery \
  ~/.claude/projects/*<take>*discovery*run/*.jsonl    # MUST be PURE-<model> in BOTH arms
```

`MIXED` / `CONTAMINATED` voids the pair — rerun it. When triaging a `MIXED`, print the offending record
first: Claude Code writes its own `API Error: ...` notices with `model: "<synthetic>"`, which the tool buckets
into OTHER and which is a transcript artifact, not a silent model fallback (`FALLBACK`/`REFUSAL` stay 0).

**Ordering and symmetry rules.** Run both arms of a contest back-to-back and FLIP the arm order between
contests (time-of-day drift); never pull the checkout between the two arms of a pair; a zone left `failed` /
`hunted_degraded` in either arm gets exactly ONE `--rehunt-gaps --rehunt-include-partial
--rehunt-max-attempts 2` pass IN THAT ARM, and if it is still degraded the whole contest pair is VOID — a
crashed cell must never become a one-sided MISS.

## Zone-restricted rehunt (#2214)

A `--rehunt-gaps` pass scoped to ONE zone of an already-frozen base, used to test a lever (a routing change,
a follow-through gate, a dismissal-discipline directive) cheaply against a single rare-row miss instead of
re-running a whole contest. Archive of the run it produced:
[`runs/2214-oracles-rehunt/`](runs/2214-oracles-rehunt/). Needs a base already frozen by the recipe above
(step 2) — this recipe never runs STAGE 1/2.

```sh
DF=<repo>/dark-factory ; ARMDIR=<take-root>/<contest> ; BASE=<frozen-base>/<contest> ; ZONE_ID=<zone id>

# 1) stage: copy the frozen map + briefs (mutated below, so a real copy) + truth.tsv; symlink code + judging
mkdir -p "$ARMDIR/zone-hunt-out/coverage"
cp -a "$BASE/map" "$BASE/briefs" "$ARMDIR/zone-hunt-out/"
cp    "$BASE/truth.tsv" "$ARMDIR/truth.tsv"
ln -s "$BASE/code"    "$ARMDIR/code"
ln -s "$BASE/judging" "$ARMDIR/judging"

# 2) filter the staged map/zones.json down to the ONE zone (byte-identical zone dict, 1-element list)
python3 -c '
import json, sys
path, zid = sys.argv[1], sys.argv[2]
zones = json.load(open(path, encoding="utf-8"))
matched = [z for z in zones if z.get("id") == zid]
assert len(matched) == 1, matched
json.dump(matched, open(path, "w", encoding="utf-8"), indent=2)
' "$ARMDIR/zone-hunt-out/map/zones.json" "$ZONE_ID"
# map/scope.tsv and briefs/ are left untouched for a control arm.

# 2b) treatment arms only: inject the class under test into that zone's scope.tsv line (the field
#     run-discovery.sh --list-cells reads to build the per-cell class set under --rehunt-gaps — NOT
#     zones.json's bug_classes_likely)
#     edit "$ARMDIR/zone-hunt-out/map/scope.tsv": append ",<CLASS>" to field 2 of the matching zone-name row.

# 3) coverage init over the FILTERED zones.json -> one not_reached zone -> `gaps` yields exactly it
python3 "$DF/lib/zone-coverage.py" init \
  --zones "$ARMDIR/zone-hunt-out/map/zones.json" \
  --out "$ARMDIR/zone-hunt-out/coverage/zone-coverage.json" \
  --zone-list "$ARMDIR/zone-hunt-out/.zone-list.tsv" \
  --repo "<contest>" --commit "$(git -C "$DF" rev-parse HEAD)" --zone-cell-budget 0 --run-cell-budget 0
python3 "$DF/lib/zone-coverage.py" gaps --file "$ARMDIR/zone-hunt-out/coverage/zone-coverage.json" \
  --max-attempts 2   # SELF-CHECK: must print exactly one line, id=$ZONE_ID

# 4) run — same ruler as the whole-contest recipe above (depth OFF, --jobs 1, killswitches); the lens/flags
#    under test are env vars on this one invocation
bash "$DF/run-zone-hunt.sh" --repo "$ARMDIR/code" --out "$ARMDIR/zone-hunt-out" --rehunt-gaps \
     --backend flat-cyborg --model <model-id> --jobs 1 --agentis agentis
```

Scoring: read the cell logs (`OPCHECK|`/`TRACE|`/`CANDIDATE|` lines under `discovery/$ZONE_ID/run/hunt_*.log`)
for the specific rare row(s) under test — never the location-first scoreboard, which can name-coincident-credit
a row through an unrelated candidate at the same function (see the #2213 archive's disclosure). Grep only the
`hunt_*.log` glob, never `hunter.ag` (a copy of the directive SOURCE, containing the same literal sentinels).

## Hold-out policy: `dev` vs `holdout` (#2231)

`corpus.tsv` column 5 is `role`, and it decides what a number measured on that contest is allowed to claim:

- **`dev`** (`notional`, `yieldoor`, `yearn-ybold`, `crestal`, `plaza`) — **the lenses are designed here.**
  Until 2026-09-16 these contests' own GT ids and mechanisms sat in `bug-taxonomy.md`'s `seen:` lines, which
  `hunter.ag` reads and `gen-briefs.sh` folds into the frozen briefs verbatim; the brief's known-findings
  clause then told the hunter to treat some of the same rows as out of scope. Every recall number measured on
  a `dev` contest is therefore **in-distribution** — inflated where the mechanism was given, suppressed where
  the brief excluded the row — and both harnesses label it so on the headline. Use these contests to BUILD and
  debug a lens, never to claim recall.
- **`holdout`** (`dodo`, `mellow`, `symm`) — never used to design a lens. **Recall claims are only made here.**

`run-corpus-bench.sh --score` and `generation-recall.sh --from-work` print `role=<role>` next to every
per-contest headline (and carry it in `--json`), with `dev` spelled out as `IN-DISTRIBUTION`. A contest that is
not in the manifest reads `role=?` rather than passing as clean. `run-corpus-bench.sh --self-test` fails if any
row is missing a `dev`/`holdout` role; `tools/colony-lint.sh` fails if a contest id or a GT id reappears in a
prompt-visible file. The contest text removed from the lens is parked, verbatim, in
[`bug-class-coverage.md`](bug-class-coverage.md) ("Contest examples — docs only, never prompt-visible").

Model memorisation of public Sherlock reports remains a residual risk on every contest; the hold-out only
removes the leakage we control.

**The policy in practice**: [`runs/2231-holdout-baseline/`](runs/2231-holdout-baseline/) archives the first
measurement run entirely on `holdout` contests (`mellow`, `malda`, `superfluid-locker`, `lend-v2`) under the
clean, de-contaminated lens — control (shipped main) scores **rare-tier recall 0/13 in both repeats**, and
none of three candidate fixes measured against it (a routing lever, the `#2218` state-assumption lens, `#2235`
external-fact resolution) moves a single held-out rare row (all NO-GO at n=2; the resolver arm's own citation
mechanics separately PASS). Read every number in that archive, and in any future `holdout`-role measurement,
as the honest floor the `dev`-contest numbers above are NOT comparable to.

## Fresh held-out set builder (#2263)

Every capability change needs a never-touched held-out set to be measured on, and the held-out rows above are
spent once a result has been read off them. `fresh-set.sh` builds the next set without the manual routine:

```bash
# build + report (the work dir MUST be outside this repo; exactly one of --ledger / --no-ledger)
bash fresh-set.sh --work <dir> --ledger <hunted-targets ledger> \
     --exclude <prior RESERVED.tsv or spent-exam list> [--since YYYY-MM] [--max-candidates N] [--probe]
# freeze the chosen contests into a sealed manifest (no network)
bash fresh-set.sh --work <dir> --reserve <id,id,...>
# run the set exactly like the corpus
bash run-corpus-bench.sh --work <dir> --corpus <dir>/RESERVED.tsv ...
# probe ANY contest dir holding truth.tsv for training memorization (also retroactively, on a spent set)
bash fresh-set.sh probe <work>/<id> --model <the hunt's model id>
# offline contract check (what colony-lint runs)
bash fresh-set.sh --self-test
```

**Pipeline** (`fresh-set.py`, one process; each contest carries the FIRST gate it fails):

1. **Discover** (`--source sherlock-gh`): page the org's public repos through the GitHub REST API and keep
   `<slug>` + `<slug>-judging` pairs only. `date` is the slug's month, `ended` the judging repo's creation date
   (the closest public proxy for the contest end). `--candidates-from` takes a hand list instead, so another
   platform that publishes GitHub judging repos needs no code change.
2. **Exclude** (`EXCLUDED`, nothing cloned): the code or judging repo is in `--corpus`, or any whitespace field of
   an `--exclude` file equals the slug, id or either repo. Pass every prior `RESERVED.tsv` and spent exam list
   here: the spent held-out contests are named nowhere in repo text, so this is the only thing that catches them.
3. **GT** (`NO-GT`, `LOW-RARE`): shallow-clone the judging repo, run `extract-gt.sh` offline; `rare` = rows with
   found-by 1-2, `gt_shape=drift` when the `# Issue` header count differs from the extracted rows. A contest
   below `--min-rare` (default 1) never gets its code cloned.
4. **Code** (`NO-CODE`): shallow, non-recursive clone plus the wrapper's own non-vendored submodule;
   `empty-submodule` > `readme-only` > `no-solidity`. Then source counts, project roots
   (`lib/project_roots.py`, same rule as the hunt) and `rare_loc` (rare rows with a `--code` location anchor).
5. **Contamination** (`CONTAMINATED`, `REVIEW`): every name of the contest is searched in the repo text
   (`git ls-files`, loaded once) and in the `--ledger` file. Strong needles are the slug, the slug without its
   date, both repo names and the code README H1; weak needles are the name tokens of at least 4 characters that
   are not on the `WEAK_STOP` list in `fresh-set.py` (generic words such as `lending`, `vault`, `protocol`, which
   say nothing about one contest; extend the list when a real run shows a new false positive). A strong hit, any
   hit in a prompt-visible file (the #2231 set, mirrored from `tools/colony-lint.sh`) or a strong ledger hit is
   `CONTAMINATED`. Weak hits only give `REVIEW`, which is reservable only with `--allow-review`, after a human has
   read `<work>/<id>/contamination.tsv`.
6. **Memorization** (`MEMORIZED`, see below), then `CLEAN`.

The report (`<work>/fresh-set-report.tsv`) carries counts only, never a title or a signature; GT text stays in
`<work>/<id>/truth.tsv`. **The work dir and `RESERVED.tsv` stay OUTSIDE the repo** (a `--work` inside it is
refused): a reserved set is sealed until its exam is consumed, and only then promoted into `corpus.tsv` as
`holdout`. `--reserve` refuses (exit 4, nothing written) any contest that is not `CLEAN` (`REVIEW` and `MEMORIZED`
need their `--allow-*` flag), has no detected project root, or is already in the corpus.

**Rate limit and cache.** The listing needs about 5 pages; without `GH_TOKEN` / `GITHUB_TOKEN` it runs
unauthenticated, well under the anonymous limit, and the token is never printed or written. Raw pages are cached
in `<work>/.listing/`, so a re-run costs 0 API calls (`--refresh-listing` to re-fetch). A rate limit, HTTP error,
network error or bad JSON stops pagination but keeps the pages already read: the report header then says
`discovery=partial (<reason>; resets <time>)`. Clones use no API quota.

**Training memorization — the residual the hold-out cannot remove.** Every concluded judging repo available today
predates the hunter model's knowledge cutoff, so the model may have read the public report, and any recall number
on such a set (earlier held-out exams included) is confounded by memorization until it is measured. `fresh-set.sh
probe <contest-dir>` measures it:

- The prompt carries **no code and no ground truth**, only the contest slug, month and protocol name. A leak guard
  refuses (exit 4; `memo=refused` inside a build) a prompt that would carry a GT title, a GT id, a location function
  or a `.sol` name.
- The call goes through **the hunt's backend and model pin**: flat-cyborg, the argv agentis builds for
  `llm.backend = flat-cyborg`, the sandboxed target `lib/claude-sandboxed.sh`, `--model` (default `opus`, the
  hunt's `llm.model` default). The session runs in an empty, pre-trusted scratch dir with every tool and MCP server
  switched off (`--tools "" --strict-mcp-config`), so it can only answer from memory.
- `prompt.txt` and `reply.txt` are recorded verbatim in `<contest-dir>/probe/`, and the reply is scored **offline**.
  `recalled_from_memory` per GT row is `yes` when a non-generic contract/function name (or two names) AND at least
  2 mechanism keywords of the title match one `FINDING|` line. It is `partial` for one keyword, or for a generic
  name alone (`deposit`, `withdraw`, ...). A mechanism-only resemblance is `no`, and each reply line credits at most
  one row. `summary.tsv` gives the memorization rate over all rows and over the rare rows. A backend that fails
  (non-zero exit or an empty reply) is never scored, because an empty reply would read as `not-memorized`: the
  reply is kept as `reply.failed.txt`, `probe` exits 3 and a build marks the contest `memo=failed`.
- A contest with at least one rare row recalled `yes` is `MEMORIZED` in the report and is not reservable without
  `--allow-memorized`. `build --probe` probes every `CLEAN` / `REVIEW` contest that has no recorded reply yet, and a
  recorded reply is always re-scored. `probe --rescore` re-scores without calling the model.
- The probe also runs standalone on any already-frozen `<work>/<id>/` of `fetch-corpus.sh` (the name comes from
  the judging clone's origin remote and the code README H1), so spent sets can be probed retroactively.

**Cued probe (`probe <contest-dir> --cued`, or `build --probe --cued`).** Free recall ("list what you remember")
is biased toward `FINDING|NONE` by its own do-not-guess rule, and it misses recognition memory. The cued probe
gives the model, for each GT row with a column-6 location, ONLY `<contract>:<function>` plus the contest name. It
never gives a title, a description or a mechanism. It asks whether an accepted High/Medium finding was reported at
that function and, if so, what its root cause was.

- Locations are batched, `--batch` per prompt (default 20). The isolation and the backend are the same as the free
  probe, and every prompt and reply is recorded verbatim (`cued-prompt-<n>.txt`, `cued-reply-<n>.txt`).
- Every batch carries one **decoy**: a real function of `<contest-dir>/code` that no GT row names anywhere. Its
  position in the batch is hash-ordered, so it carries no signal.
- A `YES` is scored offline by the same conservative matcher. Because the cue supplies the names, the credit rests
  on the mechanism keywords the model adds itself. The result is `cued_recall` per row (`cued.tsv`) plus
  `cued_rate`, `rare_cued_rate` and `decoy_fp_rate` (`cued-summary.tsv`).
- A model that answers `YES` to everything shows up as a high `decoy_fp_rate`, with content-free answers scoring
  `no`, instead of looking like memorization.
- A contest is `MEMORIZED` when `rare_cued_rate` exceeds `--memorized-rare-rate` (default 0.25). The report shows
  the result as `memo_cued` (rare rows recalled / rare rows asked). `--rescore` re-scores recorded replies offline.

The probe measures what the model can **state**. A model that recognises the code on sight without being able to
name the finding is not caught, so a `not-memorized` contest is a lower bound on contamination, not proof of
absence.

## Adding a contest

Append a row to `corpus.tsv` (`id  code_repo  judging_repo  project_subdir  role  [scope_hint]`) for any
CONCLUDED Sherlock contest whose judging repo is public — `role` is REQUIRED, and a new contest is a
`holdout` unless a lens was knowingly designed on it. To FIND such a contest (and check it for missing code,
contamination and model memorization) use `fresh-set.sh`, see "Fresh held-out set builder (#2263)" above. `extract-gt.sh` only needs the judging repo's
`README.md` to follow the `# Issue <H|M>-<N>: <title>` / `## Found by` shape used above — verify that shape holds (`grep -c '^# Issue
[HM]-' README.md` should equal the contest's published finding count) before trusting the extracted count.

**Multi-project code repo (#2255).** When the audited code repo holds several nested project roots (each with
its own `foundry.toml` / `hardhat.config.*`), set `project_subdir` to a comma-separated LIST of those roots,
relative to the clone root (`core,market`), and write any `scope_hint` relative to the clone root. `--hunt`
then runs `run-zone-hunt.sh --repo <work>/<id>/code --project-roots <list>`, so every root is mapped, briefed
and hunted; `--gt` passes the clone root as `--code`. A listed root that does not exist skips the row. The
coverage record's `repo` field then names the clone dir rather than the project dir (cosmetic).
`generalization-bench.sh` skips such a row explicitly (deep-hunt-ab takes one project dir).

## CodeHawks GT extraction (#2189, unblocks #2172)

The corpus GT source above is Sherlock-only (`extract-gt.sh` parses a public `-judging` repo README). Public
Sherlock judging repos went dry for the post-cutoff, rare-class targets #2172 needs, so a second, non-Sherlock
GT source was added: **CodeHawks**. Its findings/judging data is served by a keyless tRPC layer (no `-judging`
repo, no auth), so it needs a different two-script flow than the Sherlock path — and a **separate manifest** so
the Sherlock `corpus.tsv` and its positional readers (`fetch-corpus.sh`, `run-corpus-bench.sh`,
`generalization-bench.sh`, `../composable-lens-bench/run-composable-lens-bench.sh`) are never touched. Wiring the CodeHawks manifest into the bench is #2172's job, not this
one's.

Two scripts (siblings of `../watch-competitions.sh` and `extract-gt.sh`):

1. **`list-codehawks-concluded.sh --cutoff-date <YYYY-MM-DD>`** — discovery. Parses the same keyless SvelteKit
   `competitions.getCompetitions` embed the freshness watcher parses, but keeps `finalised == true &&
   inviteOnly == false && privateSubmissionsToggle == false` contests whose `endDate` is STRICTLY AFTER
   `--cutoff-date`. The cutoff is a **required flag with no default** — a missing cutoff is an error, never a
   silent date — so a caller can never accidentally admit a possibly-model-seen target into the held-out
   corpus. Recommended value: **`2026-02-01`** (the month strictly after the hunter model's Jan-2026 knowledge
   cutoff; raise it as the cutoff advances, never lower it). Emits `id  urlSlug  name  githubUrl  endDate`,
   sorted by `endDate`. The `id` chains directly into the extractor. Private-submission contests (findings tRPC
   returns empty arrays) are dropped as a clean machine-detectable case, not an error.
2. **`extract-gt-codehawks.sh <competition-id> <github-url> <out-truth.tsv> <out-corpus.tsv>`** — extraction.
   With `--from <json>` (offline) or a live keyless GET of `findings.getFindingOverviewsForCompetition`, it
   **stream-decodes** the findings array element-by-element (`json.JSONDecoder.raw_decode` per cluster) so a
   70MB+ payload never materializes at once. For each accepted **High/Medium** finding it emits one class-tagged
   `truth.tsv` row (`sev_id  found-by  class-csv  label` — the exact shape `refute-corpus-coverage.sh`
   consumes) and appends one row to the CodeHawks-only **`codehawks-corpus.tsv`** manifest.

**Rarity / `found-by`.** The payload nests, per finding cluster, an `issues[]` array of every raw submission —
and a live inspection (#2189) showed the SAME reporter can appear more than once in one cluster (20 of 38
clusters on the inspected contest had raw `len(issues)` > distinct reporters). So raw `len(issues)` over-counts
and is NOT the rarity signal. The extractor counts **distinct reporters** (`issues[].User.id`, falling back to
`.username`, then `.Team`) per cluster — the analog of Sherlock's "Found by" watson list. Fewer distinct
reporters = rarer.

**Class tagging (conservative, auditable, never guessed).** `codehawks-class-keywords.tsv` maps each taxonomy
class (`../../auditor/bug-taxonomy.md`) to a narrow keyword regex. A finding's `title + description + content`
is matched against every class; it is auto-tagged **only when EXACTLY ONE class matches**. On 0 or 2+ matches
the `class-csv` is left BLANK (a safe no-op: `refute-corpus-coverage.sh` yields no class token for an empty
field, so an untagged row never enters the rare-GT class set until a human fills it in) and the finding is
logged to `--needs-tagging` for human classification. A wrong class poisons GT, so ambiguity is always deferred
to a human. The keyword table is a first cut from the taxonomy's own prose, checked in separately from the
parser so it can be hand-audited and extended without a code review; it is EXPECTED to leave many findings
blank. The RARE attacker-controlled-callee class is C8 (reentrancy).

**Network gating (HARD).** The live fetch is opt-in / offline-by-default. `colony-lint.sh`/CI invoke ONLY
`--self-test`, which drives the checked-in redacted fixtures under `fixtures/codehawks/` (`--codehawks-from` /
`--from`, zero network). No code path reachable from `--self-test` hits the endpoint.
