# Changelog — tribes-bench

All notable changes to the `tribes-bench/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `tribes-bench-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added

- **Stage 1 infrastructure** ([#364](https://github.com/Replikanti/agentis-colonies/issues/364), M1).
  - `tribe-gamma/` colony — third seed tribe with an error-path
    data-flow seed prompt (orthogonal to tribe-alpha's `format!()`-pattern
    heuristic and tribe-beta's source-to-sink heuristic).
  - `targets/stage1/{cmd_exec,path_io,fmt_str}.rs` — three new synthetic
    Rust files, ~450 LOC total, with 10 planted bugs across three CWE
    classes (CMD-INJ, PATH-TRAV, FMT-STR). Each file carries the
    `TRIBES-BENCH STAGE 1 PLANTED-BUG TARGET. INTENTIONALLY INSECURE.
    NEVER COMPILE INTO PRODUCTION.` header banner.
  - `targets/stage1/bugs.json` — manifest with `class` field. Stage 1
    standardises on the underscore convention (`command_injection`,
    `path_traversal`, `format_string`) matching the bug-ID convention.
    Stage 0's `bugs.json` keeps its hyphen variant (`command-injection`)
    untouched — they never collide because Stage 0 never sends `class`
    on the wire.
  - `tools/verify-finding.sh` extended with optional `class` dispatch
    (back-compat: empty `class` keeps Stage 0 behaviour). Adds
    `--help`, `--class`, `--bug-id` flags for Stage 1 smoke testing.
  - `tools/test-verify-finding.sh` `STAGE1=1` mode adds 6 new fixtures
    (3 known-good + 3 known-bad). Default mode (Stage 0) unchanged.
  - `tools/analyse-stage1.py` produces a 10-column telemetry CSV
    (Stage 0 columns + `bug_class`, `is_first_finder`, `tribe_size`).
    `is_first_finder` and `tribe_size` are forward-compat placeholders
    (always 0 / 1 in M1; populated in M2 and M3 respectively). The
    schema stability avoids a migration when M2/M3 land.
  - `start-federation.sh` `COLONIES=` array gains `tribe-gamma`; banner
    is now stage-agnostic.
  - `install.sh` copy-loop gains `tribe-gamma`.
  - `BUNDLE.manifest` lists tribe-gamma's surface alongside the other
    two tribes.
  - Stage 0 surface (`targets/stage0/`, `tools/run-stage0.sh`,
    `tools/analyse-stage0.py`, `tribe-alpha/`, `tribe-beta/`) untouched.
    Stage 0 reruns continue to pass.
- **Non-forge marker `forge.type = "none"`** ([#373](https://github.com/Replikanti/agentis-colonies/issues/373)).
  Both seed tribes (`tribe-alpha`, `tribe-beta`) now declare
  `[forge].type = "none"` in `colony.example.toml`. The previous
  `[forge.github]` stub block was dropped. `colony-lint` recognises the
  marker as the explicit non-forge opt-out: the `[forge]` section stays
  required (post-#256 contract), but no backend sub-block is needed and
  any present sub-block is ignored. ADR-0002 documents the marker;
  ADR-0003 remains normative for federations that do not talk to a forge.
- **Tribe READMEs corrected** ([#373](https://github.com/Replikanti/agentis-colonies/issues/373)).
  The misleading "Configure your forge or data-source connection in
  `colony.toml`" Setup step in `tribe-alpha/README.md` and
  `tribe-beta/README.md` was replaced with the actual env-var override
  surface (`TARGET_DIR`, `BUGS_MANIFEST`, `VERIFIER_PATH`) that
  `start-colony.sh` consumes. Closes the #363 QA finding #1.
- **Stage 0 wiring test** ([#363](https://github.com/Replikanti/agentis-colonies/issues/363)).
  Two seed tribes (`tribe-alpha`, `tribe-beta`), each with a single
  `hunter` agent. Plus:
  - `targets/stage0/vulnerable.rs` — ~50 LOC Rust file with three
    planted command-injection bugs (`ci-001`, `ci-002`, `ci-003`).
  - `targets/stage0/bugs.json` — ground-truth manifest keyed by id,
    line, line_tolerance, signature.
  - `tools/verify-finding.sh` — pure-shell + jq deterministic verifier
    (`{"line": int}` on stdin, `{"verified": bool, "bug_id":
    string|null}` on stdout).
  - `tools/test-verify-finding.sh` — six-fixture (3 known-good + 3
    known-bad) unit test that exits 0 on pass.
  - `start-federation.sh` — ADR-0003-friendly launcher that starts
    both tribes' `start-colony.sh` and waits.
  - `tools/run-stage0.sh` — one-shot wrapper that creates
    `runs/<utc-timestamp>/`, `agentis init`'s a hermetic `.agentis/`
    inside it, exports `TARGET_DIR` / `BUGS_MANIFEST` /
    `VERIFIER_PATH`, patches the per-run config (`exec.env_passthrough`,
    `experience.enabled`, `telemetry.enabled`), seeds
    `hunter:confidence = 0.7`, sleeps `STAGE0_WALL_CLOCK_S` (default
    900s), kills the federation, and runs the analyser.
  - `tools/analyse-stage0.py` — pure-stdlib analyser that joins
    `.agentis/daemon/<id>.colony` + `.agentis/experience/<id>.jsonl` +
    `.agentis/spend/<id>.jsonl` per (minute, tribe) and emits
    `telemetry.csv` with the seven columns `minute, tribe, agents_alive,
    cb_balance, findings_emitted, true_positives, false_positives`.
- Both hunters start at confidence `0.7` (mid-`propose` per
  [ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md)). Tribe-alpha
  uses a `format!()`-as-shell-builder seed prompt; tribe-beta uses a
  source-to-sink data-flow seed prompt.

### Changed

### Deprecated

### Removed

### Fixed

### Security

<!--
tribes-bench has no released version yet. `VERSION` carries the placeholder
`0.0.0` until Stage 2 (#365) lands and is judged worth releasing. Once a
real release is cut, this file gains a `## [X.Y.Z] — YYYY-MM-DD` section
plus Keep-a-Changelog comparison links at the bottom (see
`dev-apprenticeship/CHANGELOG.md` for the template).
-->

