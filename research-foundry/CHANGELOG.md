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

### Changed

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
