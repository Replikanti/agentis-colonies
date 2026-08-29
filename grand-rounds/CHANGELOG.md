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

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/grand-rounds-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/grand-rounds-v0.1.0
