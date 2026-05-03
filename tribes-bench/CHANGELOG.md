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

- **Stage 2 M3 — baseline harness + long-run defaults + comparison report**
  ([#394](https://github.com/Replikanti/agentis-colonies/issues/394)).
  - `tribes-bench/tools/run-baseline.sh` (new) — fixed-pipeline control
    harness for the M3 thesis verdict. Runs a single tribe scanning the
    same Stage 2 target as the 5-tribe ecosystem with `replicate` /
    `knowledge_buy` / `knowledge_sell` stubbed via tagged `learn` rows
    (`baseline-no-replicate`, `baseline-no-market`). Total CB is
    `5 * initial_cb` so the single-tribe baseline burns the same total
    compute envelope as the federation. Materialises
    `tribes-bench/templates/tribe-baseline/` (new directory under
    version control with `colony.toml.template` +
    `agents/hunter-baseline.ag.template`) into a hermetic per-run dir
    `runs/baseline-<ts>/tribe-baseline/`. Captures
    `agentis-version.txt`, `llm-backend.txt`, `run-meta.json`. Periodic
    snapshots use the new shared `tools/snapshot-stanza.sh` 7-section
    payload. Reliable shutdown via `tools/kill-federation.sh
    --no-backup`. Drives `tools/analyse-stage2.py` at the end. Env vars
    `STAGE2_BASELINE_WALL_CLOCK_S` (default 3600s),
    `STAGE2_BASELINE_LLM_BACKEND` (default `claude`),
    `STAGE2_BASELINE_SNAPSHOT_S` (default 600s). Two stdlib helpers
    (`tools/run-baseline-render.py`,
    `tools/run-baseline-meta.py`) keep the shell heredoc-free per the
    macOS bash 3.2 invariant.
  - `tribes-bench/tools/run-stage2.sh` upgrades for the M3 long-run
    reproduction recipe. Defaults: `STAGE2_WALL_CLOCK_S`
    `3600` -> `172800` (48h); `STAGE2_SNAPSHOT_S` `600` -> `3600` (1h).
    New env `STAGE2_CRASH_AT_S` triggers a `kill-federation.sh +
    exit 99` after the elapsed counter reaches it (drives the M3
    crash-recovery drill). New env `STAGE2_RESUME_RUN_DIR` reuses an
    existing run-dir's `.agentis/` + `bug-ledger.jsonl` +
    `knowledge-market.csv`, continues snapshot numbering from
    `max(elapsed)`, defensively kills any stale daemon state before
    relaunch, prunes `*.colony` files older than the snapshot mtime
    via the new stdlib helper `tools/run-stage2-prune.py`. Snapshot
    payload upgraded to the 7-section header-stanza form via the new
    shared `tools/snapshot-stanza.sh` (`## daemon-list`,
    `## experience-counts`, `## spend-counts`, `## bug-ledger`,
    `## market-csv`, `## reputation-memos`, `## per-tribe-cb`).
    Captures `agentis-version.txt`, `llm-backend.txt`, `run-meta.json`
    once per run; resume path appends `run-meta-resume-<n>.json`
    instead of clobbering the original meta.
  - `tribes-bench/tools/analyse-stage2.py` extended (existing
    behaviour byte-identical when `--baseline` is omitted). New
    `--baseline <path>` flag triggers `<run-dir>/comparison.md`
    emission with 5 fixed sections in plan Decision 4 order:
    (1) Findings volume, (2) Cost per true positive, (3) Replication /
    tribe-size dynamics, (4) Run shape, (5) Knowledge market activity
    (ecosystem only). Section 5 prints `_no market activity in this
    run_` when `knowledge-market.csv` is missing or empty. The
    substrate-revenue aggregation excludes rows where `cache_hit=1`
    per Risk 7 mitigation.
  - `tribes-bench/tools/test-stage2-baseline-runner.sh` (new) — 7-case
    test for the baseline harness. Live smoke skips when `agentis`
    is not on PATH or no LLM API key is in env.
  - `tribes-bench/tools/test-stage2-crash-recovery.sh` (new) — 7-case
    drill (static doc + live crash + live resume + snapshot stanza
    payload). `trap EXIT` cleanup runs `kill-federation.sh`
    unconditionally.
  - `tribes-bench/tools/test-stage2-analyse-comparison.sh` (new) —
    fixture-driven 24-assertion test for the comparison report
    (no live `agentis` spawn).
  - `tribes-bench/README.md` — new "Stage 2 (M3 — long-run + baseline)
    reproduction recipe" section documenting the 3-step recipe
    (`run-baseline.sh` -> `run-stage2.sh` -> `analyse-stage2.py
    --baseline`), the snapshot SHAs to pin at merge, the
    non-determinism caveat (LLM backend dominates), and the 6-test
    inventory split into live-fire vs fixture-only.
  - Stage 0 / Stage 1 / Stage 2 M2 surface (`hunter.ag` files in
    `tribe-{alpha,beta,gamma,delta,epsilon}`, calibration.toml,
    `start-colony.sh` files, `verify-finding{,-stage2}.sh`,
    `analyse-stage{0,1}.py`, `run-stage{0,1}.sh`,
    pre-existing tests) byte-identical. Pre-existing
    Stage 0/1/2 tests continue to PASS unchanged.

- **Stage 2 M2 — cognitive market + reputation** ([#393](https://github.com/Replikanti/agentis-colonies/issues/393)).
  - All 5 `tribe-{alpha,beta,gamma,delta,epsilon}/agents/hunter.ag`
    now (a) update a `reputation:tribes-bench-<tribe>` float memo
    inline (`+0.05` clamp 1.0 on verified findings, `-0.10` clamp 0.0
    on false positives), (b) sell every verified finding via
    `knowledge_sell` on a per-finder topic prefix
    (`tribes-bench-<finder>/<bug_id>`) at the reputation-keyed ask
    `max(1, floor(rep*10) + 1)`, (c) buy a sibling's head ledger row
    via `knowledge_buy` at the start of every 8th tick (pool-aware
    skip below `pool_minimum_for_buy`) at the reputation-keyed
    `max_cb = floor(rep*20) + 5`, (d) list a
    `tribes-bench-bundle/<tribe>` espionage topic once per
    `bundle_period` verified findings when reputation > 0.7, and
    (e) buy the highest-rep sibling's bundle at a 5× premium when own
    reputation < 0.3 and own pool ≥ `cb_surplus_threshold` and at
    least one sibling clears the 0.7 reputation gate. Per-finder
    topic-prefix discipline eliminates the `query_by_tags` seller-
    collision class entirely (plan §9 risk 3). Every buy and every
    sell call wraps a lifecycle-event discriminator
    (`recall_latest("agent:lifecycle:cognitive:last_event_kind")`)
    and emits a `cognitive.cache_hit`-aware `learn("market", ...)`
    row so the federation experience log surfaces free-ride traffic
    (plan §9 risk 1+2).
  - All 5 `tribe-*/scripts/start-colony.sh` seed the new memos
    (`reputation:tribes-bench-<tribe>` = `0.5`, `cb_surplus_threshold`
    = `300`, `bundle_period` = `3`, `pool_minimum_for_buy` = `50`,
    `tribes-bench-<tribe>:knowledge_market_csv` from `RUN_DIR` when
    set) before the daemon loop fires.
  - `tribes-bench/tools/check-agentis-version.sh` (new, ~50 LOC)
    refuses install or start when `agentis --version` parses below
    `v1.5.0` (the floor where `knowledge_buy` / `knowledge_sell`
    ship as `.ag` builtins). Wired into `install.sh` first executable
    line and every `tribe-*/scripts/start-colony.sh` first executable
    line. Refusal exit code is 78 (`EX_CONFIG`); error text points at
    `https://github.com/Replikanti/agentis/releases/tag/v1.5.0`. Plan
    §9 risk 7 mitigation — zero crash exposure on pre-v1.5.0 runtimes.
  - `tribes-bench/calibration.toml` (extended) — new `[reputation]`
    and `[knowledge_market]` blocks documenting the four formulas
    (ask, max_cb, premium_ask, premium_max_cb), the buy-gate modulus,
    pool-aware skip threshold, bundle pacing, and the surplus
    threshold. M1's `[tribe.economy]`/`[tribe.reward]`/`[tribe.death]`
    sections are byte-identical (asserted in
    `test-stage2-scaffold.sh` test 8).
  - `tribes-bench/tools/analyse-stage2.py` (extended) — adds
    `load_market_log` reader, `resolve_downstream_verified` (scans
    each buyer's experience JSONL within 5 ticks of every buy ts to
    mark verified=1 / false=0 / no-finding=""), and `write_market_log`
    that rewrites `<run-dir>/knowledge-market.csv` with a header line.
    Existing `telemetry.csv` schema byte-identical.
  - `tribes-bench/tools/test-stage2-cognitive-market.sh` (new) — 41
    pure-offline assertions covering knowledge_sell + knowledge_buy
    placement, topic-prefix discipline, ask/max_cb formula sanity,
    bundle listing, espionage three-predicate gate, CSV column count,
    and the cache-hit-aware revenue contract (plan §9 risk 2).
  - `tribes-bench/tools/test-stage2-reputation.sh` (new) — 56 pure-
    offline assertions covering initial seed, verified `+0.05`,
    false-positive `-0.10`, ceiling/floor clamps after 30 simulated
    ticks, and the gate effect on ask_price + max_cb. Includes a
    regression check that the four pre-existing test scripts continue
    to PASS unchanged (`test-verify-finding.sh`,
    `test-stage1-replication.sh`, `test-stage1-bug-ledger.sh`,
    `test-stage2-scaffold.sh`).
  - `tribes-bench/tools/test-stage2-scaffold.sh` test 8 relaxed from
    full-file byte-identity to "M1 [tribe.economy/reward/death]
    sections unchanged" — M2 appends `[reputation]` and
    `[knowledge_market]` sections so the M1 byte-identity gate is
    stale; the section-scoped diff preserves the original spirit of
    the assertion (M2 must not edit M1 calibration values).
  - Runtime floor bumped from `agentis >= 1.4.1` to
    `agentis >= 1.5.0` in `tribes-bench/README.md`. README gains a
    Stage 2 M2 ecosystem section (~80 lines) documenting the four
    deliverables, the analyser revenue contract, and the
    calibration knobs.
  - Stage 0/Stage 1 surface (`targets/stage0/`, `targets/stage1/`,
    `targets/stage2/`, `tools/run-stage{0,1,2}.sh`,
    `tools/verify-finding{,−stage2}.sh`, `tools/test-verify-finding.sh`,
    `tools/test-stage1-replication.sh`,
    `tools/test-stage1-bug-ledger.sh`) byte-identical. Pre-existing
    Stage 0/1 + Stage 2 M1 tests continue to PASS unchanged.
- Stage 2 M1 scaffolding: 2 new tribes (`tribe-delta` lifetime/aliasing,
  `tribe-epsilon` concurrency/Send+Sync) bringing the federation to 5
  tribes. Real-world target swap from synthetic Stage 1 → vendored
  `smallvec v0.6.13` snapshot with 5 documented RustSec advisories
  (RUSTSEC-2018-0003, -2018-0018, -2019-0009, -2019-0012, -2021-0003).
  New `tools/verify-finding-stage2.sh` (separate file from the Stage 0/1
  verifier — back-compat preserved), `tools/run-stage2.sh`,
  `tools/analyse-stage2.py`, `tools/test-stage2-scaffold.sh`.
  Calibration parameters unchanged (Stage 1 economy is already per-tribe;
  the federation-wide CB pool delta is zero — that argument lives in
  M2 #393). Stage 0/Stage 1 surface byte-identical; pre-existing
  Stage 0/1 tests pass unchanged. Pure infrastructure — no live
  experimental run yet (that's M3 #394). ([#392](https://github.com/Replikanti/agentis-colonies/issues/392))
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

- Fixed (#398): hunters read `$TARGET_DIR/$TARGET_FILE` instead of hardcoded `vulnerable.rs` / `cmd_exec.rs` (Stage 0/1 carryovers); harness exports `TARGET_FILE=lib.rs` for Stage 2.

### Security

<!--
tribes-bench has no released version yet. `VERSION` carries the placeholder
`0.0.0` until Stage 2 (#365) lands and is judged worth releasing. Once a
real release is cut, this file gains a `## [X.Y.Z] — YYYY-MM-DD` section
plus Keep-a-Changelog comparison links at the bottom (see
`dev-apprenticeship/CHANGELOG.md` for the template).
-->

