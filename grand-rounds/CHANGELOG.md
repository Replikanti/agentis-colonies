# Changelog — grand-rounds

All notable changes to the `grand-rounds/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `grand-rounds-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

**Requires:** agentis >= 1.22.3

## [0.2.0] - 2026-09-02

### Fixed
- **The preprocessor could score an input it never read.** The take-2 submission
  run pointed `MVA_VCF` outside the bcftools container's bind-mounts; every stage
  of the normalize pipe failed on an empty stream, and the record-count
  post-condition then inspected the STALE `normalized.vcf.gz` from the previous
  run, passed, and printed "normalized VCF written". The run scored on an input
  nobody selected, and the M2 ablation it was meant to test never happened. The
  preprocessor now refuses on a non-zero pipeline status, and separately when its
  output is older than the stats file the same invocation just wrote.
- **The REF-mismatch guard was dead.** Its pattern (`[0-9]+ +[a-z ]*ref
  mismatch`) matched nothing `bcftools norm -c w` writes, which is one
  `REF_MISMATCH<TAB>` record per site. Where a summary line did match twice,
  `head -1` could return the 0 from "Checked 0 ref mismatches" while a later line
  reported 12 — failing open. Counted in .ag now.
- **`pop_af` guarded multiple rows but not multiple values.** A `Number=.` AF tag
  carries every allele's frequency and `norm -m -any` copies it whole to each
  split record ("0.0001,0.6000"); that parsed as 0, so a common variant read as
  ultra-rare AND the skeptic was told the population axis had been checked — the
  #2056 failure inverted. An ambiguous field is now unassessable.
- **Moving the GTF row selection into .ag blew the CB budget.** `gene_at`
  re-derived the panel window per record, which was affordable while the shell
  returned one line and cost ~5,495 CB per call once .ag ingested 75-265; a
  500-record loop aborted at record 138, so a real WGS proband would have died
  with a runtime error and no submission. The BED is built once and scanned.
- The leak guard inherited `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE` and would
  scan another repository while reporting this tree clean. `demo-baseline.sh`
  already unset them for itself; the guard now does too.
- `grep -P` in the runtime pipeline and in the smoke gate, and GNU-only `sed -i`
  in the live suite, made the federation unrunnable on macOS. `cargo install
  agentis` — documented here as the way to install the prerequisite — does not
  exist; the upstream prebuilt installer does. `git` and `bcftools` join the
  checked prerequisites.
- **A guard that could not read the tree reported it clean.** Every scan is
  driven by `git ls-files`, which returns nothing when git declines the
  directory (safe.directory / "dubious ownership" on a bind-mounted or shared
  checkout, a dangling worktree gitfile). Measured: a planted HP id under
  `GIT_TEST_ASSUME_DIFFERENT_OWNER=1` scanned zero files and exited 0 over a
  real leak. The guard now refuses (exit 2) rather than reassuring.
- **A locally built bundle shipped operator secrets.** `BUNDLE.manifest` was the
  bare `grand-rounds/` directory and `make-federation-bundle` uses `cp -pR`,
  which ignores `.gitignore` — so a tarball built on a working machine contained
  `baseline/.agentis/` (an Ed25519 private key), a real `config/colony.toml` and
  gated `work/*.vcf`, with all bundle tests green. Official releases build from
  a fresh CI checkout and were unaffected, but enumerating paths only narrowed it — the remaining directory entries had the
  same property, and `tribes-bench` and `trading-binance` carry it too. Fixed at
  the source instead: `make-federation-bundle` now stages from the **git index**,
  so an uncommitted file cannot ship from any federation, and it refuses to build
  outside a checkout rather than falling back to a plain copy.
- **The leak guard had two blind spots, both on the privacy side.** Derived
  artifacts the pipeline itself writes (`refuted.tsv`, `panel-review.tsv`, a
  renamed submission CSV) carry GRCh38 coordinates but no forbidden extension,
  and there was no coordinate needle at all — staged into a checkout they
  scanned as clean. And `grand-rounds/baseline/fixtures/` was a BLANKET
  allowlist in both the guard and `.gitignore`, so anything dropped in the one
  directory a test input naturally lands in bypassed the extension check: a
  planted `clinical.docx`, `proband.bam` and an `.obo` carrying a real HP id all
  passed. The guard now has a coordinate needle (measured: zero false positives
  on the tracked tree), the fixtures exemption is a NAMED five-file allowlist and applies to the
  extension check ONLY — the content needles now scan the fixtures too, since
  `demo-baseline.sh`'s purity check covers only `*.vcf` and `mini.fa`,
  and `demo-baseline.sh` asserts each needle separately so one cannot hide
  behind another. `.gitignore` also covers renamed submissions and the derived
  artifacts.
- `colony.toml` was accepted, warned about when absent, and never read. An
  operator setting `[baseline] panel_pad` there silently got the default. The
  note now says plainly that the file is not parsed and names the environment
  variables that are.
- **The released bundle was broken, and its privacy guard looked broken with
  it.** `BUNDLE.manifest` listed only `grand-rounds/`, so the tarball shipped
  without `tools/check-no-gated-data.sh`: inside it `demo-baseline.sh` reported
  46 ok / 1 failed / exit 1, and the failure was in the leak guard — the worst
  thing to look broken on a clinical-genomics submission. Worse, the guard's
  mutation assertion passed **vacuously**: it ran `bash "$GUARD"` and treated any
  non-zero exit as "the guard bit", but a missing script exits 127, so a guard
  that was not shipped at all read as a working one. The assertion had been dead
  for the whole life of the release. The guard now ships, 127 is treated as "did
  not run", the repo-scoped tree scan skips only where there is no `.git` entry at all
  (an unpacked tarball), never merely because git declines to confirm a tree, and `tools/test-make-federation-bundle.sh` gains
  a test that runs the federation's own suite inside the built tarball and
  requires the mutation assertion to have actually executed.
- **A cold clone could emit a submission built on zero phenotype evidence.**
  `agentis init` writes `llm.backend = mock`, whose `prompt()` returns nothing;
  nothing checked the backend, so the phenotyper produced a 1-byte HPO draft,
  the run offered *that* draft for operator approval, and approving it yielded a
  schema-valid CSV with no warning. `start-colony.sh` now refuses (exit 7) on a
  mock/unset backend (`MVA_ALLOW_MOCK_BACKEND=1` overrides for
  deterministic-stages-only runs), and the phenotyper refuses on zero verified
  HPO terms whatever the cause, recording `phenotype-empty` in the abort memo.
- `demo-baseline-live.sh` had **always run on an empty phenotype set** — all 40
  assertions passed without ever exercising a non-empty one. It now wires a
  deterministic stub backend (prompt on stdin, reply on stdout) returning the
  two ids its synthetic `hp.obo` defines. Still 40 ok, now against real terms.
- `install.sh` exited 0 after printing `FATAL - python3 not found`; python3 is a
  hard requirement and it now exits 2. `agentis init` is also run when `.agentis`
  has no HEAD, repairing only a provable stub and never deleting.
- `analyze-nampt.ag` refuses when the rhabdomyosarcoma arm falls below 10 of the
  expected 13 lines: a partial Oncotree-label loss previously produced a fully
  confident verdict from n=1.
- macOS portability: `realpath` replaced with the federation's python3 idiom,
  and every bare `mktemp` given a template (BSD requires one).
- README quickstart was not runnable (missing `MVA_*` exports); docs no longer
  claim the Exomiser output is unconsumed or that a "golden CSV" exists.

### Added
- `tools/verify-citations.ag` + `tools/analyze-nampt.ag` — the Track 2
  citation-verification contract and the DepMap check that corrected the report.

### Added

- **Operator hackathon runbook** `doc/hackathon-runbook.md`
  ([#2031](https://github.com/Replikanti/agentis-colonies/issues/2031)): the
  operator-driven MVA Hackathon steps the automation cannot perform —
  leaderboard submission (M4), the optional gated mosaicism deep-dive with a
  robust `HF_HUB_DISABLE_XET=1` FASTQ-download recipe (M2), the Track 2 report
  + video (M5), and post-hackathon data deletion (M7). README links it.

### Changed

- **Exomiser top-N now merges into the reconciler**
  ([#2054](https://github.com/Replikanti/agentis-colonies/issues/2054)):
  closes the novel-gene blind spot — the candidate pool used to be built
  exclusively from the known-MVA-gene panel, so a causal variant outside
  BUB1B/CEP57/TRIP13/CENATAC could never rank. With `MVA_RUN_EXOMISER=1`
  (still opt-in — hour-scale run) the reconciler appends one representative
  variant per novel gene AFTER the panel candidates (panel precedence is
  structural; `max_rows` trims the tail): combined score ≥
  `phenotype_novel_gene_min_score` → `phenotype_novel_gene` (primary, 0.20),
  below → `incidental` (secondary, 0.05) — the raw score never becomes an
  EPCR, per the ladder's own contract. Header-driven TSV column resolution;
  canonical-path fallback keeps the merge across the D6 two-pass flow and is
  manifest-pinned (`.done.<nvcf|hpo|assembly>` must match — stale Exomiser
  output from an earlier phenotype never merges); per-row hardening skips
  non-primary/unprefixed contigs (chr-normalized first), symbolic alleles,
  malformed positions, comma symbols, and panel variant-key collisions
  (readthrough genes), so one bad row can never kill the whole submission;
  lens promotion never relabels a novel-gene row into a `known_gene_*` rung;
  removing `$MVA_WORK_DIR/exomiser/` forces panel-only. Without Exomiser
  output the submission is byte-identical (pinned by `cmp` in the live
  test). Live-agent mutations E1–E5.

### Deprecated

### Removed

### Fixed

- **Tied EPCRs capped F-max; scorer-mandated proband id**
  ([#2067](https://github.com/Replikanti/agentis-colonies/issues/2067),
  [#2066](https://github.com/Replikanti/agentis-colonies/issues/2066)): the
  first live submission scored rank points 100/100 (full match at rank 1)
  but F-max 0.667 — two rows tied at 0.90 mean no threshold isolates the
  true row. `emit_submission` now separates ties deterministically AFTER
  the final ordering (first of a tie keeps the tier value, each following
  row emits 0.01 below the previous, floored at 0.01) — presentation of
  the already-computed total order, no new evidence; tiers stay in the
  notes. And the emitted `proband_id` honors the new `MVA_PROBAND_ID` knob
  (challenge scorers accept only the dataset-documented literal, e.g.
  PROBAND01) with the VCF sample name as the fallback; allowlisted
  end-to-end, exit-5 re-wire on old configs. Live mutations S1/S2.

- **Within-tier ordering was lexicographic by row text**
  ([#2064](https://github.com/Replikanti/agentis-colonies/issues/2064)): all
  known-gene comphet pairs tie on the 0.75 tier and the #2059 sort broke the
  tie by row text (effectively chromosome string), putting an arbitrary gene
  at rank 1 on real data — while `epcr.yml` documents that the Exomiser
  score orders candidates WITHIN a tier. The sort key now inserts the
  gene's Exomiser rank (first appearance in the rank-ordered variants TSV;
  999 = absent/no TSV → deterministic text fallback) between the EPCR and
  the row text. Live mutation O1 pins the reorder and the no-TSV fallback.

- **Exomiser stage died at startup on a fresh install**
  ([#2062](https://github.com/Replikanti/agentis-colonies/issues/2062)):
  `fetch-reference-data.sh` unzipped the CLI + data bundles but never
  provisioned `application.properties` (no `exomiser.data-directory`, no
  assembly data-version — and the distribution default keeps hg19 ACTIVE,
  which we do not download) nor any runnable `exomiser` wrapper. The first
  real `MVA_RUN_EXOMISER=1` run failed with rc=1 ("No GenomeAnalysisService
  instance provided"). Fetch now idempotently provisions the properties
  (managed keys stripped + re-appended, hg19 commented out, distribution
  lines preserved) and generates a podman wrapper running with the CLI dir
  as its working directory (Spring Boot resolves `application.properties`
  from CWD). Offline source-guard added.

- **Refuter's benign-in-population axis read caller `INFO/AF` as a population
  frequency** ([#2056](https://github.com/Replikanti/agentis-colonies/issues/2056)):
  on the first real `MVA_LENS_MODE=1` run every candidate carried the caller's
  sample allele fraction (~0.5) in `INFO/AF`, the hard axis fired on all of
  them BEFORE the LLM skeptic ever ran, and the lens submission came out
  empty. The population-AF source is now the configurable
  `benign_af_info_tag` (default `GNOMAD_AF`; `epcr.yml`), a missing
  annotation no longer short-circuits the skeptic (the benign axis falls to
  the LLM's own knowledge; unrefuted candidates keep the L4 fail-open
  `refuter-error` tag naming the missing tag), and the fixture's `INFO/AF`
  — which always had population semantics — is renamed `GNOMAD_AF`. New
  live mutation L5 pins the exact trap (caller-style `AF=0.5` must not
  hard-refute).

### Security

## [0.1.0] - 2026-08-28

### Added

- **M3 variant-triage lens federation** (opt-in via `MVA_LENS_MODE=1`,
  [#2040](https://github.com/Replikanti/agentis-colonies/issues/2040)): a
  five-lens fan-out + an independent refute gate + a reconciler layered onto the
  M1 candidate pool in `baseline/agents/pipeline.ag`, replaying the dark-factory
  `refuter.ag` devise→refute pattern in genomics. Five blind lenses
  (inheritance-model, mosaicism/low-VAF, HPO phenotype-overlap, known-MVA-gene,
  pathway/novel-gene) each score the whole pool from one angle over the substrate
  memo bus; an adversarial `refuter` judges each candidate on four axes
  (benign-in-population, wrong inheritance fit, phenotype mismatch, artifact),
  fail-open-tagging what it cannot assess; a `lens_reconciler` merges lens
  agreement (promotes a rung) + refutation (demotes into `refuted.tsv`) via the
  substrate `decide()`, and `lens_emitter` writes a second submission
  `agentis-federation_lens.csv` REUSING M1's schema validator/writer. Additive
  `settings/epcr.yml` knobs (`lens_score_threshold`, `lens_agreement_promote_min`,
  `benign_population_af`). Default off leaves the baseline submission
  byte-for-byte identical. Live-agent mutation coverage L1–L4 in
  `baseline/demo-baseline-live.sh`.

- **Real-backend smoke gate** `baseline/demo-lens-smoke-real.sh`
  ([#2046](https://github.com/Replikanti/agentis-colonies/issues/2046)):
  operator-run `MVA_LENS_MODE=1` end-to-end against the operator's own
  `.agentis/config` (the real flat-cyborg backend) with a single-candidate
  pool; fails on any `[llm.timeout]`, any other LLM error, an implausibly
  fast run (`lens_score()` silently falls back to its prior on a failed
  reply, so a completing chain alone proves nothing —
  `GR_SMOKE_MIN_ELAPSED_S`, default 60), or a missing lens CSV. Exports the
  same `FLAT_CYBORG_*` knobs the real launcher uses, neutralizes inherited
  `MVA_VCF`/`MVA_PHENOTYPE_DOC` so real clinical data can never enter the
  synthetic run, and keeps the run tree on failure for post-mortem.
  `demo-baseline-live.sh` wires no LLM backend and cannot catch real-backend
  latency regressions — its header and the README now say so loudly.

- **M6 public-deliverable readiness**
  ([#2050](https://github.com/Replikanti/agentis-colonies/issues/2050)): a
  scoped `grand-rounds/LICENSE` (Creative Commons Attribution 4.0 International,
  the license the MVA Hackathon 2026 submission requires — distinct from the
  repo-root Apache-2.0) and a reproducible `doc/methods.md` methods report
  (pipeline architecture, the EPCR evidence-tier ladder, reproduction steps, and
  honest caveats), grounded in the merged pipeline and carrying no proband data.
  README now links both.

### Changed

- **Representative-variant selection for panel genes + strict EPCR ordering**
  ([#2059](https://github.com/Replikanti/agentis-colonies/issues/2059)):
  Track-1 scoring is variant-level and the padded gene windows are full of
  benign SNPs — the reconciler used to pick arbitrarily (first hom-alt /
  first two hets) and let ANY hom-alt suppress the compound-het pair. Now:
  when the manifest-pinned Exomiser variants TSV exists, its per-variant
  ranking picks WHICH variants represent each panel gene (pair members and
  the hom pick), and the gene's top-ranked hit decides which representation
  LEADS; the other representation is emitted too, as a secondary
  `alt_representation` row (new ladder tier, 0.15 — the submission scores
  secondary rows for free, so a suppressed hypothesis costs nothing).
  Without Exomiser evidence the pair leads by default. Emitted rows are now
  strictly EPCR-ordered (desc, sorted before the cap) because the submission
  ranking is the EPCR ordering. alt_representation rows stay OUT of the
  lens pool (they would double-count the gene in every lens). Live-agent
  mutations R1/R2 + E6/E7; existing E5 updated for the two-representation
  shape.

### Deprecated

### Removed

### Fixed

- **Lens federation timed out on the real flat-cyborg backend**
  ([#2046](https://github.com/Replikanti/agentis-colonies/issues/2046)): a
  heavy clinical-genetics lens prompt takes ~630 s live, but the colony
  inherited agentis-core's 120 s `llm.cli_timeout_ms` default, so every M3
  lens prompt aborted with `[llm.timeout]` and the emitted ranking silently
  degraded to baseline-only. `install.sh` now ships
  `llm.cli_timeout_ms = 1800000` (caps the subprocess on both backend styles)
  and `llm.flat_cyborg.idle_ms = 600000` (native-backend idle cap) in
  `.agentis/config` — existing operator-tuned values survive re-runs;
  `MVA_LLM_CLI_TIMEOUT_MS` / `MVA_LLM_FC_IDLE_MS` override. `start-colony.sh`
  refuses to launch (exit 5) when `llm.cli_timeout_ms` is missing (re-run
  `install.sh` on older installs) or, under `MVA_LENS_MODE=1`, below a
  600000 ms sanity floor (a stale hand-written 120000 reproduces the bug),
  and defaults + exports the wrapper-path knobs
  `FLAT_CYBORG_TIMEOUT_MS=1800000` / `FLAT_CYBORG_IDLE_MS=600000` (operator
  exports win).

- **Silent empty submission on a broken GTF wiring**
  ([#2044](https://github.com/Replikanti/agentis-colonies/issues/2044)): with
  `MVA_GTF` unset, missing, gzipped (the panel lookup greps PLAIN text — and
  both `fetch-reference-data.sh` and `start-colony.sh` used to hand it the
  `.gz`), or pointing at a GTF that resolves no panel symbol, the panel BED
  came out empty, `bcftools view -R` matched 0 records, and the run ended as a
  degenerate CSV with no warning. Now: the `.ag` coordinator preflights the
  GTF (set, present, not `.gz`, resolves EVERY `settings/mva-genes.tsv`
  symbol via the same grep the panel stage uses) and refuses with a named
  abort (`no-gtf` / `gtf-missing` / `gtf-gzipped` / `empty-gene-panel` /
  `panel-genes-unresolved` — the last waivable for a PARTIAL symbol miss via
  `MVA_PANEL_ALLOW_PARTIAL=1`, never when nothing resolves); `panel_reviewer`
  refuses an empty panel BED (`empty-panel-bed`, defense-in-depth) and 0 panel
  records over a non-empty normalized VCF (`panel-zero-records`);
  `fetch-reference-data.sh` provisions the GTF decompressed and points
  `RESOLVED.env` at it; `start-colony.sh` defaults `MVA_GTF` to the plain
  `.gtf` and fails fast (exit 3) on a missing or `.gz` path. Every guard
  persists its reason to the `baseline:abort_reason` memo, and a new
  `bus_read()` wrapper normalizes the Void an aborted producer leaves on the
  bus — previously any abort crashed the downstream tick with a type error
  and the WHOLE run's print buffer (including the refusal message) was
  discarded, so every abort was silent to the operator. Live-agent mutations
  G0–G7 pin the contrast run, all six reachable refusal paths, and the
  partial-panel waiver. **Migration:** existing installs hit the exit-5
  re-wire once (`MVA_PANEL_ALLOW_PARTIAL` joins the managed allowlist) —
  re-run `install.sh`.

### Security

**Requires:** agentis >= 1.22.3

Initial baseline colony for the MVA Hackathon 2026 (Track 1). Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

M3 variant-triage lens federation, M6 public-deliverable readiness, and
comprehensive bug-fix pass on lens timeout and GTF wiring validation.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/grand-rounds-v0.2.0...HEAD
[0.2.0]: https://github.com/Replikanti/agentis-colonies/compare/grand-rounds-v0.1.0...grand-rounds-v0.2.0
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/grand-rounds-v0.1.0
