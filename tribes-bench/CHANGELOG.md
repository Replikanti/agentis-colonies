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

### Security

- **Verifier becomes sole `bug-ledger.jsonl` writer**
  ([#491](https://github.com/Replikanti/agentis-colonies/issues/491),
  Loose category a). Pre-#491 every `hunter.ag` appended its own JSONL
  row to the shared bug-ledger via an `exec sh "printf ... >> ledger"`
  call **after** the verifier returned `verified=true`. A hunter that
  learned the row format (or simply a hunter whose self-evolved code
  decided to skip the verifier call entirely) could fabricate
  fitness-bearing ledger rows that bypassed the deterministic match
  against `bugs.json`. Post-#491 the verifier
  (`tribes-bench/tools/verify-finding-stage2.sh`) writes the row
  internally on the verified-true path, gated on `BUG_LEDGER_PATH` +
  `TRIBE_NAME` env. First-finder vs subsequent reward (configurable via
  `LEDGER_REWARD_FULL` / `LEDGER_REWARD_SUBSEQUENT`, defaults 200 / 50)
  is decided inside the script by grepping the ledger for any prior row
  claiming the same `bug_id`. Concurrent tribes serialise via
  `flock -x` on `${BUG_LEDGER_PATH}.lock` (util-linux; macOS falls back
  to a plain `>>`). Row schema is byte-identical to the previous
  hunter-emitted shape (`{"ts": <ms>, "tribe": ..., "bug_id": ...,
  "reward": ...}`), so `analyse-stage3.py` and every downstream
  consumer see no change. All 5 `tribe-{alpha,beta,gamma,delta,epsilon}/
  agents/hunter.ag` files lose the append block; the
  `tribe-X:bug_ledger` memo is still read so the bundle-sell tail
  summary keeps working. `run-stage3-docker.sh` adds
  `LEDGER_REWARD_FULL` / `LEDGER_REWARD_SUBSEQUENT` to
  `exec.env_passthrough` and seeds them on the per-tribe
  `start-colony.sh` invocation.

### Added

- **M98 v2 — class-parametrized hunter prompts**
  ([#504](https://github.com/Replikanti/agentis-colonies/issues/504),
  builds on
  [#503](https://github.com/Replikanti/agentis-colonies/issues/503) M98
  reapply + v1.7.9 pin). Closes the cross-class hunting gap from M98:
  pre-#504 every variant — including the class-flipped mutants emitted
  by `pick_variant`'s 10% class-flip path
  ([#499](https://github.com/Replikanti/agentis-colonies/issues/499)) —
  reached the LLM through the same hardcoded uninitialised-memory
  prompt that named smallvec-specific functions
  (`from_buf_and_len_unchecked`, `pub fn insert_many`, `pub fn grow`).
  Mutated lineages were guaranteed verifier-falsepos because the LLM
  could not see the variant's class trait. All 5 hunter.ag files now
  dispatch the `prompt()` call across the 8 classes emitted by
  `_class_pick_universe` (`uninitialised_memory`, `use_after_free`,
  `memory_corruption`, `heap_overflow`, `data_race`, `send_violation`,
  `missing_lock`, `dangling_borrow`) via an if-chain at the call site,
  with each arm passing a generic Rust unsafe-code instruction (no
  smallvec function names) as a string literal first argument so the
  v1.7.9 parser's literal-string requirement on `prompt(...)` is
  satisfied without bumping the runtime floor. The variant string
  parser is hoisted to the top of the tick body so both the prompt
  dispatcher and the verifier-call site reuse the same
  `_variant_class` / `_variant_phrasing` locals (the duplicate parser
  block at the verifier-call site is removed). A new
  `_phrasing_hint(phrasing)` helper maps each of the 35 phrasing tags
  across the 5 tribes (`format-pattern-*`, `source-sink-*`,
  `error-path-*`, `lifetime-*`, `concurrency-*`) to a 1-sentence focus
  hint that sharpens *where* in the file to look (never overrides the
  class); the hint is prepended into `src_with_focus` orthogonally to
  the existing replica-focus line from
  [#439](https://github.com/Replikanti/agentis-colonies/issues/439).
  Tribe-specific surface stays minimal: only `_tribe_default_class()`
  and `pick_variant()`'s pool seeding differ across the 5 hunter.ag
  files (already differed pre-#504); the new `_phrasing_hint` body
  and the 8-arm dispatcher block are byte-identical across all 5
  tribes. Runtime floor unchanged (`agentis >= 1.7.9` per #503); no
  new builtins.

### Fixed

- **M98 hunter CB exhaustion + missing env_passthrough for HUNTER_INITIAL_VARIANT**
  (#499 follow-up). Two regressions surfaced in smoke #49 against PR
  #500:
  1. `cb 50000000;` per-tick budget was insufficient for the post-#500
     hunter.ag tick body (expanded `pick_variant()` from 7 to 14
     literals + class-flip path + variant parser at verifier-call
     site). Daemons hit `CognitiveOverload: budget 0, required 1` on
     every tick → `tick_err: 32, tick_ok: 0` per `agentis daemon list
     --json`. Bumped `cb` declaration in all 5 hunter.ag and matching
     `cb_budget` in colony.example.toml from 50000000 to 200000000
     (4× headroom).
  2. `run-stage3-docker.sh` bootstrap wrote
     `exec.env_passthrough = ... HUNTER_INITIAL_FITNESS` but omitted
     `HUNTER_INITIAL_VARIANT`. Even though M106 wire (agentis-core
     v1.7.8 / #632) correctly set the env on the spawned process,
     hunter's `exec sh "printenv HUNTER_INITIAL_VARIANT"` saw an
     empty string because the agentis sandbox filtered it out. PR
     #498's federation-side reader was a no-op in practice. Added
     `HUNTER_INITIAL_VARIANT` to the env_passthrough list.

  No production logic changes. Hot-fix only — restores B2 v2 + M98
  the way they were meant to behave.

- **`analyse-stage3.py` now reads the variant model observationally**
  ([#495](https://github.com/Replikanti/agentis-colonies/issues/495)).
  The previous build hardcoded a 3-element `VARIANT_CYCLE` and a
  Python `pick_variant()` mirror that synthesised every agent's
  `prompt_variant` and parent/child mutation kind. Post-#494 each
  tribe owns a 7-variant pool with disjoint domain prefixes
  (`format-pattern-*`, `source-sink-*`, `error-path-*`, `lifetime-*`,
  `concurrency-*`), and hunters write per-variant `variant_stats:*`
  memos but no longer emit per-row variant tags. The synthesised
  output silently masked the smoke #42 truth that
  `format-pattern-default` was a 0-verified / 59-falsepos dead
  variant. The analyser now (a) parses each tribe's pool from
  `tribe-<name>/agents/hunter.ag` via `parse_variant_pool()` and
  fails loud on an empty pool, (b) aggregates `variant_stats:*` memos
  per node via `agentis memo list --prefix variant_stats:`, (c)
  replaces the synthetic "Top-3 surviving variants per tribe" table
  with an observational "Variant outcomes per tribe" listing every
  variant with `verified + falsepos > 0` ordered by `verified DESC,
  falsepos ASC, name ASC` plus a per-tribe dead-variants subsection,
  and (d) augments `mutation-diff.csv` with `source` (`observed` /
  `unresolved`), `parent_variant_verified`, and
  `parent_variant_falsepos` columns. New CLI flags: `--fed-root`
  (default autodetect), `--no-variant-stats` (skip memo reads in
  offline tests), `--legacy-top-variants` (emit the pre-#495 table
  alongside for one release of diff-review continuity). The five
  `hunter.ag` files are unchanged.

### Added

- **M98 self-evolution: variant carries `<class>:<phrasing>`, hunters
  evolve hunt strategy via class-flip mutation**
  ([#499](https://github.com/Replikanti/agentis-colonies/issues/499)).
  Builds on [#498](https://github.com/Replikanti/agentis-colonies/issues/498)
  variant inheritance to put the bug-class trait under selection pressure
  alongside the phrasing trait. All 5 hunter.ag files now emit variant
  strings of the form `<class>:<phrasing>` (e.g.
  `uninitialised_memory:format-pattern-strict-literal`); `pick_variant()`
  seeds 14 variants per tribe across 2 sibling bug classes (7 phrasings
  each) instead of the prior 7-phrasings-only pool. Per-tribe seeding
  follows the bench's stage2 RUSTSEC alignment: alpha primary
  `uninitialised_memory` + sibling `memory_corruption`; beta
  `heap_overflow` + `memory_corruption`; gamma `memory_corruption` +
  `dangling_borrow`; delta `use_after_free` + `dangling_borrow`; epsilon
  `use_after_free` + `send_violation`. The 8-class universe also includes
  `data_race` and `missing_lock` — both reachable only via the new 10%
  class-flip mutation (independent from the existing 20% phrasing-flip
  roll, decorrelated with a different prime modulus on the same
  `now_ms_via_shell()` source so a tick can mutate phrasing only, class
  only, both, or neither). At the verifier-call site, the JSON `class`
  field is now derived from the variant string (split on `:`) rather
  than the LLM's `finding.class` -- misalignment between what the LLM
  hunted for (per the still-frozen prompt strings) and what the variant
  claims becomes a verifier-falsepos that selection rewards or penalises
  through the existing `variant_stats:<variant>:{verified,falsepos}`
  memos. Combined with #498's wire-path variant inheritance this
  produces sustained variation × selection × inheritance over the
  hunt-class trait, bypassing the structural bottleneck where pre-#499
  hunter prompts hardcoded one class per tribe and the federation could
  only flow within tribe-pinned class lanes. Each hunter declares a
  `_tribe_default_class()` helper used as a fallback when a variant
  string lacks the `:` separator (legacy memo replay from pre-#499
  builds); empty `_variant` (cold start) and phrasing-only strings both
  collapse to the tribe primary, so the cold-start verifier-payload
  matches pre-#499 behaviour byte-for-byte. The seeded 14-literal pool
  emits bare `return "<class>:<phrasing>";` literals so
  `analyse-stage3.py`'s `parse_variant_pool` regex picks up the post-#499
  pool unmodified; off-pool class-flip mutants are emitted via string
  concatenation by design (the analyser will report them under the
  observational "Variant outcomes per tribe" section as out-of-pool
  entries). Runtime floor unchanged (`agentis >= 1.7.8`); the new
  `index_of` and `substring` builtins used at the verifier-call site
  ship since v1.5.x and are included in the existing v1.7.8 floor.

- **B2 variant-evolution per-instance inheritance — federation-side reader**
  ([#497](https://github.com/Replikanti/agentis-colonies/issues/497)).
  Companion to [agentis-core#632](https://github.com/Replikanti/agentis/issues/632)
  (v1.7.8). All 5 hunter.ag files read `HUNTER_INITIAL_VARIANT` on first
  tick (mirroring the v1.7.7 `HUNTER_INITIAL_FITNESS` path from #494) and
  seed both `hunter:prompt_variant` (tribe-shared, picked up by the
  prompt-prefix branch on the same tick) and `hunter:<ppid>:variant`
  (per-PPID, future-proof attribution for analyse-stage3). Both
  `replicate()` call sites upgraded to the 3-arg `replicate(target,
  fitness, variant)` form: the M2-Malthusian site reuses the local
  `variant` already in scope from `pick_variant()`, the time-based
  reproductive site adds an inline `recall_latest("hunter:prompt_variant")`
  one line above the call. Both stay inside their existing `try/catch`
  so a runtime skew surfaces as a learn row, not a crash. Closes the
  variant-overwrite race observed in smoke #42 (T+5:23 collapse).
  Containerfile.stage3 `AGENTIS_VERSION` pin bumped v1.7.7 → v1.7.8.
  **Requires:** agentis >= 1.7.8.

- **B2 variant evolution: 7-variant prompt pool with mutation + per-variant fitness telemetry**
  (Stage 4 emergence work, follow-up to #490). `pick_variant()` in all 5
  hunter.ag files now picks from a 7-variant pool (vs prior 3-variant
  cyclic) with a 20% mutation rate that breaks cyclic ruts and exposes
  fresh variants to selection pressure. The pseudo-random source is
  `now_ms_via_shell() % 100` (same builtin already cached at top of
  tick). Each tribe keeps its own domain-specific variant set
  (format-pattern-* for alpha, source-sink-* for beta, etc., 7 each).
  Hunters cache the active variant once per tick (`_variant`) and
  increment per-variant counters on every verified finding
  (`variant_stats:<variant>:verified`) and false positive
  (`variant_stats:<variant>:falsepos`). The counters are
  tribe-aggregated and provide selection-feedback observability over
  the variant pool, so analyse-stage3 can produce per-variant fitness
  curves once smoke #42 lands.

- **Multi-LLM config injection in `run-stage2.sh`**
  ([#438](https://github.com/Replikanti/agentis-colonies/issues/438)).
  `agentis init` only seeds `llm.backend` in the hermetic per-run
  config; the matching endpoint / model / api_key_env / timeout keys
  were missing, so picking a non-default backend via
  `STAGE2_LLM_BACKEND` left the daemon falling back to mock at first
  dispatch. `run-stage2.sh` now injects the correct keys when
  `STAGE2_LLM_BACKEND=openai` (`llm.openai.endpoint`, `llm.openai.model`,
  `llm.openai.api_key_env`, `llm.openai.timeout_ms`) or
  `STAGE2_LLM_BACKEND=ollama` (`llm.endpoint`, `llm.model`). Six new
  env vars carry the defaults and are overrideable per-run:
  `STAGE2_OPENAI_MODEL` (default `gpt-4o-mini`),
  `STAGE2_OPENAI_ENDPOINT`
  (default `https://api.openai.com/v1/chat/completions`),
  `STAGE2_OPENAI_KEY_ENV` (default `OPENAI_API_KEY`),
  `STAGE2_OPENAI_TIMEOUT_MS` (default `180000`),
  `STAGE2_OLLAMA_ENDPOINT`
  (default `http://127.0.0.1:11434/api/generate`),
  `STAGE2_OLLAMA_MODEL` (default `llama3.1:8b`). All injections are
  idempotent (skipped when an active key already exists). New test:
  `tools/test-run-stage2-llm-backend.sh`.

- **Install + DX polish** ([#436](https://github.com/Replikanti/agentis-colonies/issues/436)).
  - `tribes-bench/tools/run-verdict-pair.sh` (new) — operator-friendly
    orchestrator that runs `run-stage2.sh` -> `run-baseline.sh` ->
    `analyse-stage2.py --baseline <latest>` and prints `comparison.md`
    inline. Each step is echoed with a leading `+ ` prefix BEFORE
    executing so operators can copy individual lines. Defaults
    `STAGE2_WALL_CLOCK_S=1800` and `STAGE2_BASELINE_WALL_CLOCK_S=1800`
    (30 min each) for a fast verdict pair. Flags: `--dry-run`,
    `--skip-stage2`, `--skip-baseline`. Smoke test:
    `tools/test-run-verdict-pair.sh`.
  - `tribes-bench/README.md` — new **Quick start** section near the top
    (prerequisites + three-line recipe) and **Known gotchas** section
    near the bottom (kill-federation cascade behaviour, links the
    selectivity-fix follow-up #440).
  - `tribes-bench/install.sh` — post-install Next-steps block listing
    the optional dashboard install, the `run-verdict-pair.sh`
    invocation, and the dashboard URL labelled "after starting it".

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

- `tribes-bench/tools/check-agentis-version.sh` missing-binary branch
  now prints a multi-line message pointing operators to
  https://github.com/Replikanti/agentis (the runtime is a proprietary
  closed source binary distributed for free for Linux and macOS) and
  exits 1 instead of 78. The version-floor branch is unchanged
  ([#436](https://github.com/Replikanti/agentis-colonies/issues/436)).

### Deprecated

### Removed

### Fixed

- Fixed (#398): hunters read `$TARGET_DIR/$TARGET_FILE` instead of hardcoded `vulnerable.rs` / `cmd_exec.rs` (Stage 0/1 carryovers); harness exports `TARGET_FILE=lib.rs` for Stage 2.
- Fixed (#399): `tools/test-stage2-crash-recovery.sh` adds bug-ledger size-delta + duplicate-row assertions on resume. Belt-and-suspenders coverage for the existing `RESUMING=0` truncate guard in `run-stage2.sh`.
- Fixed (#402): hunter agents detour `now_ms()` through `exec sh "date +%s%3N"` because agentis 1.6.0 does not expose `now_ms` as an `.ag` evaluator builtin. Every M2 hunter tick was failing with `undefined function: now_ms` before this fix; this is what blocked the operator-driven verdict run. Tracked upstream as a follow-up to register `now_ms` as a proper builtin in agentis-core.
- Fixed (#404): hunters previously CB-exhausted after ~2 ticks because `cb 800;` per-tick budget was insufficient for one LLM `prompt()` call + helper fns. Bumped default `initial_cb` to 8000 (calibration.toml + hunter.ag + colony.example.toml). Harness `tools/run-stage2.sh` now rewrites per-tribe `cb_budget` in scaffolded `colony.toml` from `INITIAL_CB` at launch via new `tools/run-stage2-rewrite-cb.py`. Note: the agent-side `cb <N>;` declaration at the top of `hunter.ag` is still hardcoded at compile time and not yet calibration-driven — tracked as a follow-up.
- Fixed (#405): hunters now read the target source via `file_read()` builtin instead of `exec sh "cat $TARGET_DIR/$TARGET_FILE"` to sidestep agentis 1.6.0's `exec_foreign` capability denial that blocked operator pilots even with `--enable-exec`. Target path is sourced via memo seeds (`hunter:target_dir` + `hunter:target_file`) written by each tribe's `scripts/start-colony.sh` and the baseline `tools/run-baseline.sh` before daemon launch — agentis 1.6.0 has no `env_get`/`getenv` builtin so env-var passthrough is not reachable from `.ag` code. `file_read()` operates under the `FileRead` capability (granted by default in `grant_all()`), so the path stays harness-controlled without requiring `--enable-exec`. Affects all five tribe hunters and the M3 baseline template.
- Fixed (#409): `file_read()` in agentis 1.6.0 hardcodes its sandbox to `<agentis_root>/sandbox/`. Symlinks fail because the runtime canonicalizes the candidate path before the sandbox-containment check — symlink dereferences to its outside-sandbox target. Harness `run-stage2.sh` and `run-baseline.sh` now `cp -r` the target tree into `<agentis_root>/sandbox/targets-stage2` at scaffold time. The `rm -rf + cp -r` sequence is idempotent across resume. Tracked upstream in `Replikanti/agentis` as `--sandbox-allow-path <abs-path>` follow-up.
- Fixed (#415): hunter agents now cache `now_ms_via_shell()` once per tick instead of calling it 3× — `exec sh "date +%s%3N"` subprocess cost was exhausting per-tick CB budget mid-tick. Operator pilot showed 32% tick success rate before, expected >80% after. The shell-detour helper itself is unchanged; just the call pattern.
- Fixed (#416): `analyse-stage2.py` was attributing all hunter findings to a synthetic `unknown` tribe because `kill-federation.sh` cleared the daemon registry before the analyse pass ran. Harness now snapshots `agent_id → tribe` mapping to `<run>/agent-tribe-map.json` before kill-federation. Analyser prefers the snapshot, falls back to daemon-dir scan for legacy compatibility. Critical for #394 M3 comparison.md heatmap accuracy.
- Fixed (#407): the in-source `cb <N>;` per-tick budget declaration in each tribe's `hunter.ag` is now templated from `tribes-bench/calibration.toml` `[tribe.economy] initial_cb` at harness launch via the new `tools/run-stage2-rewrite-cb-decl.py`. Closes the residual gap from #404/#406 — calibration is now the single source of truth for both `colony.toml` `cb_budget` AND the agent-source `cb <N>;` literal. Idempotent: when defaults match, the rewrite is a no-op. Approach A (in-place rewrite mirroring #406) chosen over the issue's Option 1 (hermetic templates dir) for plumbing-pattern consistency.
- Fixed (#421): retargeted hunter prompts on tribes alpha/beta/gamma to Stage 2 RUSTSEC bug classes (`uninitialised_memory`, `heap_overflow`, `memory_corruption`). delta keeps `use_after_free` (already aligned), epsilon retargets to companion `use_after_free` panic-unwind angle. Added `class` field to alpha/beta `Finding` types + verifier-stdin payloads so `verify-finding-stage2.sh` can match by class.
- Fixed (#423): **THE big one.** `agentis init` writes `llm.backend = mock` as default in `<run>/.agentis/config`. Harness wrote `llm-backend.txt` for telemetry but never propagated the chosen backend into the daemon config — every operator pilot since the start of M2 silently ran against the deterministic `mock` backend, returning `line=0` sentinels for every prompt. This masked every prompt experiment and made plumbing fixes impossible to validate against real LLM signal. `run-stage2.sh` and `run-baseline.sh` now force-rewrite `llm.backend` in `.agentis/config` to `STAGE2_LLM_BACKEND` (default `cli` → resolved to `claude` per agentis 1.6.0 alias). After this fix, spend logs show real `cost_usd > 0` + `output_tokens > 0` instead of mock-backend zeros, and hunter findings point at real source-code lines (e.g. 712, 815, 854) instead of the `line=0` sentinel.
- Fixed (#424): all 5 hunter prompts (+ baseline template) now explicitly instruct LLM to report the **function signature line**, not the operation line. Pre-fix pilot: real LLM responses landed at lines 815, 854, 857 (operation-level), but bugs.json anchors bugs at function declaration lines (827, 656, 534) with ±5 tolerance. The mismatch produced 0 verified findings even after #423 unblocked real LLM signal. Updated signature_hint description to require function-name + parameter snippet.
- Fixed (#426): regression of #416 — agent-tribe-map snapshot moved from end-of-pilot (after wall-clock loop) to right after `start-federation.sh + sleep 5` at launch time. End-of-pilot snapshot missed daemons that died mid-run (CB-exhaustion, watchdog kill, llm.cancelled cascade) because their `.colony` registry file is cleaned on shutdown. Pilot 2026-05-04 12:28 CEST showed alpha's 4 findings misattributed to `unknown` tribe because alpha's daemon got killed in tick 5's mid-LLM-call. Launch-time snapshot captures all 5 tribes reliably and survives any mid-run daemon death. Plus harness now sets `daemon.heartbeat_interval_ms = 600000` (10min) in `.agentis/config` — default 120s killed daemons whose LLM call ran longer (Claude Code subscription responses on the smallvec target sometimes exceed 120s).
- Fixed (#428): two synergistic fixes for tribes-bench TP production. (a) `targets/stage2/bugs.json` `S2-SMVOFL-001` anchor moved from line 833 (`iter.size_hint()` operation) to line 827 (`pub fn insert_many` function signature) — consistent with #424 framework where all bugs anchor at function signature; matches the existing pattern of grow's two bugs both at line 656. (b) alpha/gamma/epsilon prompts open with an explicit "Your specific target function is X — it lives near line N" anchor. Pre-fix pilot showed beta finding line 827 five times but rejected because heap_overflow was anchored at 833; alpha/gamma/epsilon wandering 50+ lines from their target functions. Post-#428 5min pilot: TPs jumped from 2 (delta-only) to 14-16 (alpha/gamma/epsilon/delta).
- Fixed: beta hunter prompt also gets the explicit "Your specific target function is `pub fn insert_many`" anchor — same pattern as alpha/gamma/epsilon got in #428. Beta was the only tribe still at 0 TPs after #428 because its prompt lacked the function-name anchor.
- Fixed (#432): baseline template's stub `learn(...)` calls used `"stubbed"` as outcome, which the agentis runtime rejects (allowed: success/failure/partial/timeout/error). Every baseline tick aborted on the first stubbed-learn before reaching `prompt()`. M3 baseline run produced 0 TPs not because the single-tribe baseline can't find bugs but because the daemon never actually called the LLM. Changed `"stubbed"` → `"partial"` in 3 sites of `templates/tribe-baseline/agents/hunter-baseline.ag.template`.
- Fixed (#431): variable-name shadow between `tribe_name()` user fn (`let n = exec sh "printenv TRIBE_NAME"`, returns string) and the post-verified replication block (`let n = parse_int(recall_latest(...":size"))`, expects int) caused every tick post-verified-finding to abort with `tick:error: type error: expected compatible types for Mul, got int and string`. Renamed the local in `tribe_name()` from `n` to `_tn` across all 5 hunter.ag files. Empirically: pre-fix replications=0 across all pilots; post-fix `replicate-nak` learn rows now appear in experience JSONL (replicate() builtin returns "" in single-node setup, so successful replications still 0 — that's expected for tribes-bench's no-peer topology, but the BRANCH IS REACHED).

### Security

<!--
tribes-bench has no released version yet. `VERSION` carries the placeholder
`0.0.0` until Stage 2 (#365) lands and is judged worth releasing. Once a
real release is cut, this file gains a `## [X.Y.Z] — YYYY-MM-DD` section
plus Keep-a-Changelog comparison links at the bottom (see
`dev-apprenticeship/CHANGELOG.md` for the template).
-->

