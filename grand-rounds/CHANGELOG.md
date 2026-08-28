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

### Security

## [0.1.0] — 2026-08-26

Initial baseline colony for the MVA Hackathon 2026 (Track 1). Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.22.3

### Added

- `baseline/` colony: a one-shot `agentis go` clinical-genomics prioritization
  pipeline (`agents/pipeline.ag`) wiring seven cooperating agents (a coordinator
  + six stage agents) over the substrate emit/listen bus — preprocess, phenotype
  (with a hash-pinned operator review gate), Exomiser (opt-in via
  `MVA_RUN_EXOMISER`), panel review, reconcile, emit + validate. `.ag` owns the
  whole decision surface; `bcftools` and the pinned Exomiser container do only
  bulk data transforms. String helpers (`replace_all`, `join_str`, `take`) are
  in-`.ag` because agentis has no `replace`/`join`/`range` builtins; the
  normalized-VCF path fans out to four stages via the memo (broadcast) since
  `listen` is consume-once.
- `baseline/scripts/start-colony.sh` — env-contract + safe-work-dir launcher
  (execs `agentis go`, never `agentis daemon`).
- `baseline/scripts/fetch-reference-data.sh` — idempotent, verify-then-skip
  reference-data fetch (Exomiser CLI + hg38 bundle, GRCh38 FASTA, `hp.obo`,
  GENCODE GTF).
- `baseline/settings/` — checked-in, gated-data-free pins: `tools.env`,
  `epcr.yml` (evidence-tier ladder), `exomiser-analysis.template.yml`,
  `mva-genes.tsv` (the known MVA gene panel).
- `baseline/fixtures/` — synthetic, gated-data-free test fixtures.
- `baseline/demo-baseline.sh` — offline, CI-safe structure + source-guard +
  leak-guard mutation test.
- `baseline/demo-baseline-live.sh` — operator-run live-agent mutation test
  (requires `agentis` + `bcftools`; SKIPs loudly otherwise).
- Repo-level leak guard `tools/check-no-gated-data.sh` (wired into
  `tools/colony-lint.sh`).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/grand-rounds-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/grand-rounds-v0.1.0
