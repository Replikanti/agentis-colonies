# Changelog — preprint-foundry

All notable changes to the `preprint-foundry/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `preprint-foundry-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added

- `tools/substitute-author.py` helper that rewrites `AUTHOR-PLACEHOLDER`
  in the editor colony's `main.tex` from `config/authors.toml` before
  the latexmk compile pass, so the compiled PDF reflects the real
  author byline + ORCID rather than just the `.tex` inside the
  submission tarball (#616).

### Changed

- `tools/substitute-author.py` now rewrites the first `\author{...}`
  macro found in `main.tex` (matched via a balanced-brace counter)
  rather than the literal token `AUTHOR-PLACEHOLDER`. The upstream
  LLM editor prompt asks for the placeholder but real-world output
  is also `\author{Anonymous}`, `\author{}`, or any other LLM-invented
  byline; the helper must work regardless of what the LLM emits.
  Idempotency is preserved by short-circuiting when the existing
  byline already matches the rendered block (#618).

### Deprecated

### Removed

### Fixed

- Editor colony now invokes `substitute-author.py` after both the
  initial LLM write and the repair-pass rewrite, closing #616 where
  `main.tex` and `main.pdf` shipped with the literal token
  `AUTHOR-PLACEHOLDER` even when `config/authors.toml` carried a real
  author.

### Security

## [0.1.0] — 2026-05-17

Initial release (#596): preprint-generation federation that converts
`claim-auditor` `VERIFIED_NEW` rows into arXiv-ready LaTeX preprints
with a mandatory human-in-the-loop (HITL) gate before any
submission. Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.4.1

### Added

- Five colonies (`introducer`, `theorist`, `computer`, `editor`,
  `submitter`), each with a single agent that gates external writes
  on the four-tier confidence ladder per ADR-0001.
- Phased pipeline (introducer/theorist/computer at `tick-1`, editor
  at `tick-2`, submitter at `tick-3`) consuming the upstream
  claim-auditor + math-foundry memo state via best-effort recall.
- Orchestrator `tools/run-preprint.sh`: filters audit rows on
  `audit_verdict==VERIFIED_NEW AND confidence>=floor`, seeds the
  cross-federation context into the container's memo, and drives
  the per-claim tick loop.
- Containerfile (`tools/Containerfile.preprint`) layered on the
  math-foundry image: TeX Live (latex-extra / fonts-recommended /
  science) + `latexmk` + GAP (`gap-core`) + `ssmtp` for the optional
  arXiv SMTP send path.
- HITL review helper `tools/review-cli.sh` for listing DRAFTED rows
  and writing the per-claim `submitter:<claim-id>:human_status`
  memo flip (approve / reject + reason).
- Federation-level `config/authors.toml.example` with documented
  author / ORCID / endorsement schema. Operator-facing README covers
  pipeline diagram, phased pipeline table, cross-federation memo
  paths, env-var matrix, HITL workflow, arXiv endorsement workflow,
  and Phase 1 limitations.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/preprint-foundry-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/preprint-foundry-v0.1.0
