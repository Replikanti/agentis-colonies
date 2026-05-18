# Changelog — claim-auditor

All notable changes to the `claim-auditor/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `claim-auditor-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [0.1.1] — 2026-05-18

Merged into `research-foundry/`. See `research-foundry/CHANGELOG.md` (#638).

## [Unreleased]

### Added

- Five colonies wired end-to-end for literature verification of
  math-foundry novelty claims (#595): `arxiv-search/`, `oeis-search/`,
  `groupprops-search/`, `scholar-search/`, `auditor/`. Each ships one
  `.ag` agent with the standard ADR-0001 tier-branch shape. The four
  searchers hit external HTTPS endpoints (arxiv.org, oeis.org,
  groupprops.subwiki.org, api.semanticscholar.org) via `exec sh
  "python3 -c '... urllib ...'"` and the auditor synthesises their
  reports into a single audit verdict.
- `tools/run-auditor.sh` orchestrator: tails an upstream math-foundry
  `discovery-ledger.jsonl`, picks `verdict in {NOVEL, BORDERLINE}`
  rows, seeds `claim:problem_text:tick-N` etc. into the auditor
  container's memo, and lets the five colonies tick. Mirrors
  math-foundry/tools/run-foundry.sh shape (emit_step helper,
  `--replace` podman idiom, hermetic config with daemon.cb_per_tick=2000
  per trading-binance #579, daemon.heartbeat_interval_ms=1800000
  per #583, pii_transmit=allow per #581, memo.max_keys=50000 per #587).
- `tools/Containerfile.auditor` base image: agentis + Python +
  sympy/numpy/networkx + curl + python3-requests + claude CLI. No
  `--network none`; outbound HTTPS via rootless podman default
  slirp4netns egress.
- Operator-facing `install.sh` (XDG-friendly prerequisite + config
  copy, no GitLab credentials needed).
- `README.md` with operator-facing setup, cross-federation memo read
  paths, env-var matrix, audit-ledger row schema.

### Changed

### Deprecated

### Removed

### Fixed

### Security

## [0.1.0] — 2026-05-17

Initial scaffold via `tools/new-federation.sh`. Conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md).

**Requires:** agentis >= 1.4.1

### Added

- One starter colony: `arxiv-search/` with placeholder agent slot.
- ADR-0003-compliant `scripts/start-colony.sh` (supports
  `--restart-agent`, `--rate-limit-status`, exit 2 on unknown flag).

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/claim-auditor-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/claim-auditor-v0.1.0
