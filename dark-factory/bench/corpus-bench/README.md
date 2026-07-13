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
  run-corpus-bench.sh             # orchestrator + scorer (this is the entrypoint)
  fixtures/
    sample-judging-readme.md      # tiny synthetic judging report (2 findings, rarity 2 and 9)
    expected-truth.tsv            # extract-gt.sh's expected output on the fixture above
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
rarity  title  signature` (signature = title + a truncated body snippet, fed to `novelty-gate.sh`'s overlap
oracle for scoring — same idiom as `../fixtures/*/truth.tsv`).

## Scoring

For each contest: run the REAL federation pipeline (`run-zone-hunt.sh`: map → brief → discover → verify) over
the cloned code repo through a real LLM backend, then match each `verified_findings.json` lead against every
`truth.tsv` row via `novelty-gate.sh`'s overlap oracle (the same mechanism `run-capability-bench.sh` uses).
Recall is reported overall, by severity (High/Medium), and by rarity (rare 1-2 / mid 3-8 / consensus 9+) —
flat recall alone hides that consensus bugs are the easy part.

**Verified leads that don't match any truth row are reported as `unmatched_leads`, never auto-claimed as
novel.** A concluded, multi-watson-combed contest rarely has a genuinely missed valid H/M; an unmatched lead is
far more likely noise (FP, out-of-scope, already-known-but-phrased-differently) than a real find. Treat it as
a manual-triage queue, not a result.

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

## Adding a contest

Append a row to `corpus.tsv` (`id  code_repo  judging_repo  scope_hint`) for any CONCLUDED Sherlock contest
whose judging repo is public. `extract-gt.sh` only needs the judging repo's `README.md` to follow the
`# Issue <H|M>-<N>: <title>` / `## Found by` shape used above — verify that shape holds (`grep -c '^# Issue
[HM]-' README.md` should equal the contest's published finding count) before trusting the extracted count.
