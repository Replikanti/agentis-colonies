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

### Fixed

- Four `research-foundry` search colonies (`arxiv-search`, `oeis-search`,
  `scholar-search`, `groupprops-search`) wrote their per-tick liveness memo
  to the underscored key `<agent>_search:last_check` instead of the
  canonical dashed `<agent>-search:last_check`. The
  `federation-dashboard` freshness probe and any operator tooling that
  follows the `<basename>:last_check` convention (CLAUDE.md "Agent
  conventions") therefore reported these four agents as stale or missing
  even when they ticked normally. Rename is mechanical (one `memo_write`
  call per file) and matches the basename of each `.ag` file. No reader
  of the underscored form existed in-tree (#688).

### Changed

- Lifecycle (birth + death + respawn) is now **on by default** in the
  30-tick `run-research.sh --dry-run`/live invocation (#679). Four knobs
  in `research-foundry/tools/run-research.sh` were flipped so the
  M2-Malthusian replicate gate fires and the Phase 3 PR-3 cull cycle
  engages without operator opt-in:
  - `RESEARCH_CULL_ENABLED` default `0 -> 1` (cull cycle on).
  - `RESEARCH_CULL_INTERVAL_TICKS` default `20 -> 5` (a 30-tick default
    run now sees ~6 cull cycles instead of 1).
  - `RESEARCH_<COLONY>_REPRODUCTIVE_FITNESS_THRESHOLD` default `10 -> 3`
    across all 18 colonies (`explorer`, `noticer`, `skeptic`,
    `formulator`, `verifier`, `novelty`, `arxiv-search`, `oeis-search`,
    `groupprops-search`, `scholar-search`, `auditor`, `prior_advocate`,
    `introducer`, `theorist`, `computer`, `editor`, `reviewer`,
    `submitter`) so the per-pid fitness gate fires within a short run.
  - `RESEARCH_CULL_MIN_ACTING` default `10 -> 3` so short default runs
    accumulate enough acting rows to be eligible for cull.

  `RESEARCH_CULL_MIN_EXPLORERS=3` (floor protection so the cull cycle
  never empties the explorer pool) is unchanged. `MAX_REPLICAS`, `POOL`,
  `TICK_INTERVAL_S`, and the per-colony fitness-scoring `.ag` formulas
  are also unchanged — this PR is purely defaults. Operators who want
  the previous opt-in behaviour can still set
  `RESEARCH_CULL_ENABLED=0` and the previous thresholds via env.
  Coverage added in `research-foundry/tools/test-run-research.sh`
  (test 22a-22f); existing replicate-gate and jitter tests remain green.

- Per-tick jitter + lowered replica default to keep
  research-foundry under the Claude API ~100 req/min ceiling (#670
  follow-up to Phase 9 PR-C of #663). Each of the 18 colony `.ag`
  files now defines a `_jitter_sleep()` helper called once at the top
  of `fn tick(...)`; the helper sleeps for `awk
  'BEGIN{srand();print rand()*5}'` seconds (uniform on [0, 5)) and is
  bypassable via `RESEARCH_JITTER_DISABLED=1` for tests and
  deterministic replays. The disable flag is on the
  `exec.env_passthrough` allowlist that `tools/run-research.sh` emits
  into the hermetic config. Default
  `RESEARCH_<COLONY>_REPLICAS` is lowered from 3 to 2 for the 17
  non-explorer colonies, leaving the explorer count at 5 untouched.
  New shape: `5 + 17*2 = 39 daemons * 2 ticks/min = 78 req/min`,
  22% headroom under the 100 req/min ceiling. New
  `research-foundry/tools/test-jitter.sh` enforces helper definition
  + disable check + awk-srand pattern + per-`tick()` call site in
  all 18 `.ag` files; `tools/test-run-research.sh` asserts the
  flipped default + the `RESEARCH_JITTER_DISABLED` allowlist entry.

- preprint-foundry: `preprint-ledger.jsonl` schema + audit-trail
  provenance + JSON-escape polish (#600 QA follow-up from #599). Every
  ledger and replicate-ledger row in the 6 preprint colonies is now
  constructed via `python3 -c 'import json; ...'` (same pattern as
  `gitlab-api.sh`); quotes / newlines / control characters in
  LLM-emitted titles, abstracts, cover letters, SMTP error messages,
  and operator-supplied HITL rejection reasons can no longer corrupt
  the line. DRAFTED rows now emit `msc_codes` as a JSON array
  alongside the back-compat `msc_codes_csv` string (#596 spec
  alignment) and carry `reproducibility_runs_ok` sourced from
  `computer:<pid>:runs_ok:tick-<N>`. DRAFTED, SUBMITTED, and
  HUMAN_REJECTED rows now also carry a `provenance` block
  (`editor_pid`, `computer_pid`, `introducer_pid`, `tick`) so a
  SUBMITTED row can be traced back to the exact editor / computer /
  introducer chain that produced it. Schema contract documented in
  `research-foundry/submitter/README.md`; regression coverage in
  `research-foundry/tools/test-preprint-ledger-schema.sh`.

- Wired M2-Malthusian replicate gates into all 17 non-explorer
  colonies and flipped the per-colony spawn loops in
  `tools/run-research.sh` from singletons to N=3 across the board
  (Phase 9 PR-C of #663). Container shape goes from `5 explorers + 13
  singletons = 18 daemons` to `5 explorers + 17 colonies * 3 = 56
  daemons`. Each non-explorer `.ag` gains the same helper set as
  `explorer.ag` -- `_variant_overlay_suffix()`,
  `_specialty_overlay_suffix(self_pid)`, `_extract_pp_hash`,
  `_publish_prompt_body_and_wrap_variant`, per-colony `pick_variant(n)`
  sourced from `colony-variants.json`, a first-tick specialty-claim
  block keyed off `$DAEMON_ID`, and the M2-Malthusian replicate path
  inside `_publish_<role>`. The replicate ledger row gains a `side`
  field (`discovery|audit|preprint`) sourced from `colony-variants.json`,
  emitted by both the .ag replicate path and the cull / respawn rows
  in `tools/cull-replicas.sh`. `RESEARCH_CULL_COLONIES` expands its
  default to all 18 colonies. Per-pid fitness in each `.ag` ships a
  minimal +1/-1 approximation tied to the role-appropriate decisive
  outcome (matches found, decisive verdict, compile OK, etc.); PR-D
  (cross-run fitness aggregation) tunes the formulas via
  `tools/colony-fitness.py`. New
  `research-foundry/tools/test-replicate-gates.sh` enforces helper
  presence + the replicate call site for the 17 non-explorer colonies.
  Extended `research-foundry/tools/test-run-research.sh` asserts the
  new env defaults + per-colony spawn loops + replication flags.
  Explorer paths (PR-A picker, PR-B fitness/cull rename) are untouched.

- Generalised Phase 3 explorer-specific tooling to per-colony shape
  across the 18 research-foundry colonies (Phase 9 PR-B of #663).
  Renames + back-compat wrappers preserve every existing callsite
  byte-identically; behaviour is unchanged in this PR (still 5
  explorers + 13 singletons, cull cycle still fires for the explorer
  colony only). PR-C uses the new machinery to flip per-colony
  replica counts.
  - `tools/cull-explorers.sh` -> `tools/cull-replicas.sh` with a new
    positional `<colony_name>` argument and runtime variant lookup
    against `research-foundry/tools/colony-variants.json`. Legacy
    `tools/cull-explorers.sh` wrapper forwards with
    `colony=explorer`.
  - `tools/explorer-fitness.py` -> `tools/colony-fitness.py` with a
    `--colony <name>` flag dispatching to discovery / audit /
    preprint side formulas. Legacy `tools/explorer-fitness.py` shim
    forwards with `--colony explorer`.
  - `tools/auto-promote-decisions.py` decorates every recognised
    colony's decision record with top-level
    `pid + agent_id + specialty + fitness_score` and
    `evidence.colony_fitness` (PR-C populates the per-pid memo keys
    for non-explorer roles). `evidence.explorer_fitness` is kept as
    a back-compat alias for the explorer row so the dashboard's
    pre-PR-B Promote Candidates renderer keeps working without
    changes. Test 12 (legacy vs preview byte-identity) and test 14
    (prereq structure) stay green.
  - New `research-foundry/tools/colony-variants.json` source-of-truth
    table: 18 colonies x 5 variants x 5 overlays. Explorer overlays
    preserved byte-identically from the Phase 3 hardcoded text; the
    other 13 colonies get 1-line stubs PR-C will refine.
  - `research-foundry/tools/run-research.sh` bootstrap loop reads
    the variants table to seed every colony's specialty pool
    instead of hardcoding the 5 explorer entries. Adds per-colony
    `RESEARCH_<COLONY>_REPLICAS` / `_MAX_REPLICAS` / `_POOL` /
    `_REPRODUCTIVE_FITNESS_THRESHOLD` env knobs (all default to 1 /
    8 / 5000 / 10) and seeds the M2-Malthusian replicate gate memos
    for all 18 colonies. New `RESEARCH_CULL_COLONIES` env knob
    (default `explorer`) lets the auto-promote sidecar iterate the
    cull cycle over multiple colonies once PR-C lights up
    replication. The spawn loops are NOT touched in PR-B; daemon
    counts stay at today's 5 explorers + 13 singletons.

- Replica-safe handoff via winner-by-confidence picker across 9
  downstream `.ag` files (Phase 9 PR-A of #663, pre-blocker for the
  entire phase). Every `recall_latest("replay:current_<role>_pid")` +
  pid-keyed memo read is replaced with
  `_pick_upstream_by_confidence(role, output_key, tick)` — the picker
  enumerates `<role>:*:<decision_key>:tick-<N>` memos via `agentis
  memo list`, ranks by the embedded confidence field
  (`confidence_in_surprise` / `confidence` / `self_check_confidence`
  depending on role), and returns the value of the picked output_key.
  With N=1 the picker collapses to a single match identical to the v1
  LWW behaviour; with N>1 it stops the last-writer-wins stomp that
  blocked replicating any role beyond explorer. Files touched:
  noticer, skeptic, formulator, verifier, novelty, auditor, editor,
  reviewer, submitter. New colony-lint check
  `tools/check-no-replay-current-pid.sh` fails any future regression
  to the `replay:current_<role>_pid` consumer pattern. The two
  pre-existing replica-safe sites (`reviewer:<claim>:approved` claim-
  keyed, auditor's `claim:audit_*:tick-N` tick-keyed writes) are
  preserved. PR-B (tooling generalisation) and PR-C (per-`.ag`
  replicate machinery) ride on this wire change.

- Flipped `evolve.dry_run` and `evolve.mutation.enabled` for
  research-foundry (Phase 7 PR-C of #628). The explorer agent now
  runs in live evolve mode: the LLM mutator proposes candidates, the
  A/B harness spawns a sibling daemon under a synthetic agent_id,
  scoring goes through `tools/explorer-fitness.py` (PR 2 of #624),
  and a winning candidate atomically replaces the parent `.ag` with
  a respawn of the canonical daemon. The other 14 agents stay in
  observe-only mode behind a new `evolve.mutation.allowed_agents`
  list (`["explorer"]`). Configs that omit the key (dev-apprenticeship,
  tribes-bench) keep the legacy `*` fallback so flipping
  `mutation.enabled` later does not trip the gate. Fixes two PR-B
  blockers along the way: the candidate daemon SPAWN_CMD now uses
  the container-side `/run-root/...` path instead of the host fed-dir
  prefix (#660), and the mutator-stderr clipper strips the
  double-quote byte so `mutation_rejected` rows always have a
  parseable JSON `reason` field (#661). Header docs on
  `tools/auto-evolve-ab.sh` updated to match the implementation; 3
  new smoke-test assertions in `tools/test-auto-evolve-ab.sh`
  (total 18/18).

### Fixed

- `novelty/agents/novelty.ag` seeded the `claim:problem_text` /
  `claim:answer` / `claim:novelty_claim` / `claim:explorer_*`
  `:tick-N` memos only when `_publish_novelty` was called with
  `final_write=true`. Tier dispatch passes `final_write=true` only
  on the `autonomous` branch — `review-gated` and `propose` both
  passed `false` — so in the default `propose` tier the claim
  handoff keys were never written, and the downstream audit +
  preprint pipeline (4 searcher colonies + `auditor` reading
  `claim:*:tick-N` at their next tick advance) never started. Fix
  hoists the NOVEL / BORDERLINE `claim:*:tick-N` writes out of the
  `final_write` gate so they fire on every NOVEL / BORDERLINE
  verdict regardless of tier. The on-disk discovery-ledger.jsonl
  append (the actual final-write side effect) stays inside the
  `final_write` gate, matching ADR-0001 tier policy (autonomous +
  review-gated emit ledger rows; propose skips). No tier semantics
  changed; no fitness or replicate logic changed. Coverage:
  existing `tools/test-replicate-gates.sh` stays 29/29,
  `tools/test-jitter.sh` stays 72/72. (#687)

### Added

- LLM-driven `.ag` mutator + real A/B harness in dry-run mode for
  Phase 7 (PR-B of #628). New `tools/auto-evolve-mutate.py` reads the
  parent `.ag` plus the last K experience rows, computes a failure-
  mode summary by tag, and asks the configured LLM
  (`RESEARCH_LLM_BACKEND`, default `claude` + `RESEARCH_CLAUDE_MODEL`,
  default `opus`) to propose ONE focused mutation. Hard constraints
  on the prompt: complete `.ag` output, preserve `tier()` /
  `learn()` / `recommend()` / `cb <N>;` / `fn tick(...)`, no new I/O
  primitives, no markdown fences. A shape validator rejects empty /
  fenced / cb-missing / fn-tick-missing / tier-literal-missing
  responses with exit 2 + `mutation_invalid_shape`.
  `MUTATE_LLM_STUB=<path>` env bypasses the LLM call and returns the
  fixture verbatim for hermetic CI.
  `tools/auto-evolve-ab.sh` now invokes the mutator in step 2 (was a
  cosmetic-comment stub in PR-A) and runs a real two-daemon A/B in
  step 4: spawns the candidate under a synthetic agent_id
  `<agent>-cand-gen-<N>` via `podman exec <container> bash -c
  "agentis daemon ... &"`, waits `K * tick_interval_ms` bounded by
  the new `evolve.ab.absolute_max_wait_s` knob (default 1800), and
  scores both daemons via the
  `(acting_count - reject_count) / max(acting_count, 1)` proxy
  before comparing with `ab.min_delta`. Verdict surfaces as
  `evolve_cycle` (winner candidate / canonical) or `ab_inconclusive`
  on the evolution ledger. `evolve.dry_run: true` (PR-B default)
  keeps the harness in observation mode: ledger captures everything,
  no `.ag` file rename, no archive, no daemon respawn -- those are
  PR-C's job. 4 new smoke-test assertions in
  `tools/test-auto-evolve-ab.sh` (total 15/15).
- `skeptic/` colony (Phase 4 PR-A of #625). Reads the noticer's
  surprise record and runs a strict skeptic prompt that defaults to
  dismissing the surprise unless it cannot be matched to a classical
  result. Verdict label gates the formulator (pass-through default --
  empty skeptic memo does not block). Formulator/verifier/novelty
  `upstream_tick` offsets bumped by one to absorb the new pipeline
  stage. New `(topic, outcome)` pairs in `tools/check-learn-tags.sh`
  for `skeptic_dismiss:partial` and `skeptic_dismiss:success`.
- `prior_advocate/` colony (Phase 4 PR-B of #625). Reads the same
  claim seed the four web searchers consume and runs an adversarial-
  reviewer prompt that argues the claim is already known (cites the
  closest theorem / lemma / identity). Verdict is folded into the
  auditor's synthesis ctx as an additional KNOWN_PRIOR signal
  alongside the four web-search reports; the auditor's seed prompt
  is updated to count a strong prior_advocate match as a KNOWN_PRIOR
  signal and the Verdict struct gains an `evidence_prior_advocate`
  field. Pass-through default -- empty prior_advocate memo does not
  block the auditor. New `(topic, outcome)` pairs in
  `tools/check-learn-tags.sh` for `prior_match:partial` and
  `prior_match:success`. The auditor persists
  `claim:report_prior_advocate:tick-N` alongside the four searcher
  reports on VERIFIED_NEW.
- `reviewer/` colony (Phase 4 PR-C of #625). Reads the editor's final
  main.tex and the computer's reproducibility stdout, extracts every
  numerical / symbolic claim from the .tex, and flags every claim
  that lacks direct support in the reproducibility output. The
  structured Verdict (`approved` / `rejected`) is persisted to memo
  and -- on `approved` verdicts only -- the per-claim gate
  `reviewer:<claim>:approved` is set to `"true"`. Reviewer enforces
  block-by-default semantics -- submitter requires
  `reviewer:<claim>:approved == "true"` before writing DRAFTED.
  Operator override via
  `agentis memo set reviewer:<claim>:approved true`. The submitter's
  `upstream_tick` offset bumps from `tick_idx - 3` to `tick_idx - 4`
  to absorb the new pipeline stage. New `(topic, outcome)` pairs in
  `tools/check-learn-tags.sh` for `review:partial`, `review:success`,
  and `review:failure`.

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
