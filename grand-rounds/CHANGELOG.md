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

### Changed

### Deprecated

### Removed

### Fixed

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
