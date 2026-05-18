# Changelog — research-foundry

All notable changes to the `research-foundry/` federation will be
documented in this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `research-foundry-v<X.Y.Z>` so other
federations in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

History of the three retired federations consolidated into this one
(math-foundry / claim-auditor / preprint-foundry) is preserved under
`docs/archive/` and in git history.

## [Unreleased]

### Added

- `skeptic/` colony (Phase 4 PR-A of #625). Reads the noticer's
  surprise record and runs a strict skeptic prompt that defaults to
  dismissing the surprise unless it cannot be matched to a classical
  result. Verdict label gates the formulator (pass-through default --
  empty skeptic memo does not block). Formulator/verifier/novelty
  `upstream_tick` offsets bumped by one to absorb the new pipeline
  stage. New `(topic, outcome)` pairs in `tools/check-learn-tags.sh`
  for `skeptic_dismiss:partial` and `skeptic_dismiss:success`.

## [0.1.0] — 2026-05-18

**Requires:** agentis >= 1.7.12

Initial release. Consolidates three retired research federations
(`math-foundry/` + `claim-auditor/` + `preprint-foundry/`) into one
15-colony pipeline driven by a single orchestrator and a single
container (#638).

### Added

- 15 colonies wired end-to-end for compute-first novelty discovery
  through to arXiv preprint submission. Math pipeline: `explorer/`,
  `noticer/`, `formulator/`, `verifier/`, `novelty/`. Claim-auditor:
  `arxiv-search/`, `oeis-search/`, `groupprops-search/`,
  `scholar-search/`, `auditor/`. Preprint pipeline: `introducer/`,
  `theorist/`, `computer/`, `editor/`, `submitter/`.
- `tools/run-research.sh` merged orchestrator with the standard
  hermetic config block (experience.enabled, telemetry.enabled,
  daemon.cb_per_tick=2000 per trading-binance #579,
  daemon.heartbeat_interval_ms=1800000 per #583, pii_transmit=allow
  per #581, memo.max_keys=50000 per #587). Spawns one container
  (`research-foundry-laptop`) hosting all 15 daemons under one
  shared `.agentis/`. Tick-stream payload seeds only the explorer
  pipeline; the 9-10-tick cascade through 14 downstream daemons
  happens inside the container with no cross-fed JSONL
  reconstruction.
- `tools/Containerfile.research` -- preprint superset image
  (Ubuntu 24.04 + Python scientific stack + TeX Live + GAP +
  ssmtp + agentis runtime + claude CLI).
- `tools/test-run-research.sh` -- dry-run smoke assertions including
  single-container spawn, 15-daemon bootstrap, and single
  auto-promote sidecar block invariant.
- `tools/fetch-papers.py`, `tools/test-fetch-papers.py` -- one-time
  arXiv corpus bootstrap helper carried forward from
  `math-foundry/`.
- `tools/review-cli.sh`, `tools/substitute-author.py` -- preprint
  review + author substitution helpers carried forward from
  `preprint-foundry/` (review-cli.sh container name updated to
  `research-foundry-laptop`).
- `tools/auto-promote-config.research-foundry.yaml` -- consolidated
  auto-promote config under `<repo>/tools/`. Adopts preprint's
  most-lenient prerequisites (`min_acting_entries: 10`,
  `min_runtime_hours: 1.5`). Per-colony prereq variation deferred
  as a Phase 2 chore.
- `claim:*:tick-N` memo handoff (#638). The novelty.ag agent writes
  `claim:problem_text:tick-N` / `claim:answer:tick-N` /
  `claim:novelty_claim:tick-N` / `claim:explorer_*:tick-N` on
  positive verdict (NOVEL / BORDERLINE). The auditor.ag agent
  writes `claim:audit_*:tick-M` and `claim:report_*:tick-M` on
  VERIFIED_NEW. Replaces the cross-fed JSONL recall the retired
  orchestrators did by probing upstream run dirs.
- `docs/archive/` -- final CHANGELOGs from the three retired
  federations.

### Removed

- Three retired orchestrators (`math-foundry/tools/run-foundry.sh`,
  `claim-auditor/tools/run-auditor.sh`,
  `preprint-foundry/tools/run-preprint.sh`) and their per-fed
  Containerfiles. Replaced by one merged orchestrator and one merged
  image.
- Cross-federation memo recall code paths in the retired
  orchestrators (~200 LOC). Each downstream agent now reads its
  upstream colleague's memo directly via the shared in-container
  store.
- Three retired auto-promote configs
  (`tools/auto-promote-config.{math-foundry,claim-auditor,preprint-foundry}.yaml`).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/research-foundry-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/research-foundry-v0.1.0
