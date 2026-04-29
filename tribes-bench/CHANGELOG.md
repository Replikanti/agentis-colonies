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

- **Stage 1 M2+M3 — replication, Malthusian, reward, death** ([#364](https://github.com/Replikanti/agentis-colonies/issues/364), M2+M3).
  - All three `tribe-{alpha,beta,gamma}/agents/hunter.ag` now (a) wire
    `replicate(target_node)` inside a Malthusian per-replica cost gate
    (`C(n) = base + (base * n) / k` with documented `max_replicas`
    cap), with seed-prompt mutation routed via the `hunter:prompt_variant`
    memo set just before the replicate call (the runtime byte-copies
    the agent, so source-level mutation is impossible — splicing the
    variant tag through a memo sidesteps that constraint); (b) credit
    the per-tribe pool with a first-finder full reward / subsequent
    partial reward via the shared `runs/<ts>/bug-ledger.jsonl`, with
    the in-band first-finder check provisional and the analyser
    determining the canonical first-finder post-hoc by `min(ts)` per
    `bug_id` (sidesteps the cross-process race documented in §7 of
    the M2+M3 plan); (c) initiate tribe death via sibling-stop +
    `agentis knowledge export` KB preservation when the pool drains
    below the configured `death_threshold`. The death path is guarded
    by a one-shot `tribe-<name>:death_initiated` memo so racing
    siblings do not all run the preserve+stop sequence.
  - All three `tribe-{alpha,beta,gamma}/scripts/start-colony.sh` now
    pass `--enable-replication --allow-replica-replication` to BOTH
    the main launch and the `--restart-agent` paths, and seed the
    M2+M3 economy memos (pool, size, `replication_base_cost`,
    `replication_k`, `max_replicas`, `reward_full`, `reward_subsequent`,
    `death_threshold`, `bug_ledger`, `run_dir`) before the daemon
    loop fires. Defaults match `calibration.toml` so an operator can
    launch the federation directly without the M3 harness for Stage 0
    reruns or smoke tests.
  - `start-federation.sh` spawns one local `agentis worker
    127.0.0.1:9100` per launch with a randomised per-run secret when
    `RUN_DIR` is set (the harness path); skipped when `RUN_DIR` is
    unset (Stage 0 reruns continue to work). Worker pid recorded in
    `runs/<ts>/worker.pid`, log in `runs/<ts>/worker.log`. The
    `tribes-bench:worker_addr` memo seeds the `replicate(target_node)`
    target for each hunter.
  - All three `tribe-{alpha,beta,gamma}/config/colony.example.toml`
    document the new `[tribe.replication]`, `[tribe.reward]`,
    `[tribe.death]` blocks. The values are documentation defaults
    matching `calibration.toml`; they are NOT consumed by
    `start-colony.sh` — calibration overrides arrive via the env from
    `tools/run-stage1.sh`.
  - `tribes-bench/calibration.toml` (new) — single source of truth
    for the Stage 1 economy (initial CB pool, replication base cost,
    Malthusian `k`, max replicas per tribe, full + subsequent reward,
    death threshold). Each value carries an inline justification
    comment refutable by AC #7 calibration runs.
  - `tribes-bench/tools/run-stage1.sh` (new) — operator-facing
    one-shot harness modeled on `run-stage0.sh`. Reads
    `calibration.toml` via `run-stage1-calibration.py`, exports
    economy env vars + `BUG_LEDGER_PATH` + `RUN_DIR`, expands
    `exec.env_passthrough` so daemons can read the new env, default
    `STAGE1_WALL_CLOCK_S=3600` (vs Stage 0's 900), captures a
    snapshot every `STAGE1_SNAPSHOT_S=600`, runs `analyse-stage1.py`
    at the end. Reaps the colony worker on shutdown.
  - `tribes-bench/tools/run-stage1-calibration.py` (new) — tiny
    stdlib helper sourced by `run-stage1.sh` to dodge the macOS bash
    3.2 heredoc parser bug per CLAUDE.md "no heredocs in tools/*.sh"
    invariant. Returns the requested key with a documented fallback
    default when missing.
  - `tools/analyse-stage1.py` extended to populate the M1
    forward-compat columns from real signals: `is_first_finder` joined
    from `bug-ledger.jsonl` (group by bug_id, min(ts) tribe wins),
    `tribe_size` joined from per-agent alive minutes (replicate-driven
    daemon spawns bump the count). Two new columns appended:
    `replication_event_count` (`replicated`-tagged experience rows
    per (minute, tribe)) and `tribe_death_ts` (sticky timestamp from
    the `died`-tagged experience row onward; empty = alive). Final
    schema: 12 columns.
  - `tribes-bench/tools/test-stage1-replication.sh` (new) — pure
    offline. Asserts `replicate(` calls present, Malthusian arithmetic
    in source, `--enable-replication` on both daemon launch paths,
    `agentis worker` spawn in `start-federation.sh`, and the M2+M3
    memo seeds. 48 assertions; pure-shell with no agentis dependency.
  - `tribes-bench/tools/test-stage1-bug-ledger.sh` (new) — race
    resilience smoke. 10 background workers each append 10 simulated
    finding rows for 10 bug_ids, then asserts the same first-finder
    reduction `analyse-stage1.py` uses produces exactly one
    first-finder per bug_id. Mirrors the post-hoc race resolution
    documented in plan §7.
  - `tribes-bench/tools/test-stage1-bug-ledger-reduce.py` (new) — the
    reducer the bug-ledger test exercises. Same shape as
    `analyse-stage1.load_first_finder_map` for fidelity.
  - `BUNDLE.manifest` lists the new files (`calibration.toml`,
    `tools/run-stage1.sh`, `tools/run-stage1-calibration.py`,
    `tools/test-stage1-replication.sh`, `tools/test-stage1-bug-ledger.sh`,
    `tools/test-stage1-bug-ledger-reduce.py`).
  - Stage 0 surface (`targets/stage0/`, `tools/run-stage0.sh`,
    `tools/analyse-stage0.py`, `tools/verify-finding.sh`,
    `tools/test-verify-finding.sh`) untouched. Stage 0 reruns continue
    to pass.
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

