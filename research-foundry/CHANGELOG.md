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

- `research-foundry/tools/run-research.sh` default `RESEARCH_<COLONY>_REPLICAS` for the four triage-role colonies (`noticer`, `skeptic`, `novelty`, `prior_advocate`) bumped `1` → `3` so the M2-Malthusian replicate gate and the `knowledge_market` `samples>1` density both have non-trivial cross-replica selection pressure on a default run ([#824](https://github.com/Replikanti/agentis-colonies/issues/824)). Pre-bump 17 of 18 colonies defaulted to 1 replica (only explorer ran at 5), so cross-replica diversity in the triage tier was empirically negligible despite the per-colony replicate-gate boilerplate shipped in [#663](https://github.com/Replikanti/agentis-colonies/pull/663). Explorer stays at 5 (already tuned). Sequential preprint pipeline (`formulator`, `verifier`, `introducer`, `theorist`, `computer`, `editor`, `reviewer`, `submitter`), rate-limited searchers (`arxiv-search`, `oeis-search`, `groupprops-search`, `scholar-search`), and the `auditor` stay at 1: extra replicas would either race on single-writer roles, burn shared API rate budget, or contend on `audit-ledger.jsonl`. Effective default daemon count is now 30 across 18 colonies (was 18). Operator override via the same `RESEARCH_<COLONY>_REPLICAS` env-var family is unchanged. `research-foundry/tools/test-replicate-gates.sh` extended with four new assertions (one per diversified colony) so the defaults cannot regress silently.

## [0.2.0] — 2026-05-28

**Requires:** agentis >= `1.8.0`

First versioned release since the federation's initial `0.1.0` scaffold. Accumulated platform work — Mathlib bundling, AI-disclosure footnote, three runtime bumps culminating in agentis v1.8.0, auto-promote rescaling, heartbeat-fallback liveness check, Lean placeholder ban, CB budget normalization, ledger symlink fix, prompt-timeout watchdog defense, outcome-enum tag normalization, ctx-component clamps, and the daemon-aging gate fix — lands as one bundled milestone. The noticer-pilot distillation refactor lands in a follow-up release once the empirical lifecycle is validated end-to-end via a 75-tick run.

### Changed

- `research-foundry/noticer/agents/noticer.ag` now runs a rule-first lookup against the crystallizer before falling back to the LLM ([#819](https://github.com/Replikanti/agentis-colonies/issues/819)). The new `build_canonical_context` helper emits a deterministic, prefix-narrowing context string (`topic=<topic> output_kind=<kind> bucket=<size_bucket> seq=<first8> lines=<count>`) consumed by `crystallizer_lookup_with_confidence("noticer_surprise", ctx, min_confidence)`. Field order is most-discriminating-first so the crystallizer's prefix matcher (`matches_context`) narrows correctly across topics. Rule hits skip `prompt()` entirely and synthesize the Surprise verdict from the rule's `action` field (encoded as `"<bool>|<short_description>"`) via the new `_publish_noticer_rule_hit` helper (the `.ag` grammar disallows inline `Surprise { ... }` struct literals). Misses fall through to the existing LLM path, which now writes `learn("noticer_surprise", canonical_ctx, "<bool>|<desc>", "success", [...])` rows so the crystallizer can distil repeat patterns into rules that the next run's Stage 1 consumes. Calibrated triage bias (noticer biases toward `surprise_found=true` when uncertain, per `_seed_prompt`) is preserved structurally: the LLM verdicts that feed the crystallizer already carry the bias, so distilled rules inherit it via training data rather than via a runtime branch. Env-gated rollback: set `NOTICER_RULE_FIRST=0` to short-circuit the rule branch. Default confidence threshold is `0.85`, overridable via `NOTICER_RULE_CONFIDENCE`. Pilot scope -- other agents unchanged. Primary distillation pilot: noticer ticks on every cycle, so the crystallizer accumulates enough validations within a 75-tick run to crystallise.
- `research-foundry/skeptic/agents/skeptic.ag` now reads `noticer:<noticer_pid>:rule_id:tick-N` after each verdict and calls `crystallizer_record_use(rule_id, agree?, ±delta)` so noticer's distilled rules are reinforced on skeptic agreement (`upheld`, +0.05) and demoted on disagreement (`dismissed`, -0.15) ([#819](https://github.com/Replikanti/agentis-colonies/issues/819)). `unsure` is treated as no signal. `noticer_pid` is resolved via the existing Phase 9 PR-A picker (`_pick_upstream_pid_by_key`) already used elsewhere in the skeptic tick body. Closes the feedback loop end-to-end inside a single tick window.
- `tools/check-learn-tags.sh` schema extended with two new `(topic, outcome)` pairs covering the new noticer + skeptic `learn()` rows ([#819](https://github.com/Replikanti/agentis-colonies/issues/819)): `noticer_surprise:success` (tags: `distilled`, `rule-hit`, `rule-reinforced`, `skeptic-agreement`, `llm-driven`, `math-foundry`), `noticer_surprise:failure` (tags: `rule-demoted`, `skeptic-override`, `math-foundry`). The legacy `notice:partial` / `notice:success` schema entries remain in place for backward compatibility and continue to be emitted by `noticer.ag`'s per-tier observability rows.
- `research-foundry/tools/Containerfile.research` `ARG AGENTIS_VERSION` bumped `v1.7.18` → `v1.8.0` to pull in the runtime fix for the process-lifetime monotonic `string_heap` odometer (agentis-core #663) plus the new `KnowledgeCrystallizer` `.ag` builtins (agentis-core #662). Pre-fix the heap counter never decremented — any LLM workload accumulated bytes for the lifetime of the daemon process and tripped `ResourceExhausted: string_heap limit 16777216 exceeded` after ~30-60 min, surfacing as cascading `_pick_upstream_*` errors. v1.8.0 splits the counter into `transient_string_heap_bytes` (per-tick, reset at tick boundary, hard limit applies) + `retained_string_heap_bytes` (lifetime odometer kept only for `introspect.memory_used` observability). v1.8.0 also adds `crystallizer_lookup`, `crystallizer_lookup_with_confidence`, and `crystallizer_record_use` evaluator builtins so `.ag` agents can consult crystallized rules at tick time and skip `prompt()` calls when a high-confidence rule matches (closes the distillation loop intended since the earliest evolve_self design). The post-bump 25-tick smoke run against a locally-built v1.8.0 confirmed zero string_heap errors across the federation; the full 75-tick verification of the distillation loop lands once the noticer-pilot refactor (separate PR) merges.
- `research-foundry/editor/agents/editor.ag` `_edit_prompt` now requires the LLM to insert an AI-assistance disclosure footnote (single `\\thanks` on the author line) into the paper body itself, not only in any external cover letter. Per arXiv 2024+ AI-assistance disclosure policy and most journal submission requirements; same wording applies to LinkedIn / blog / conference re-postings. The disclosure attributes the draft to an autonomous multi-agent research federation (Replikanti research-foundry) backed by an LLM and explicitly states that mathematical statements + reproducibility script were independently checked and the human author takes full responsibility. Pre-fix the disclosure existed only in `arxiv-metadata.json` cover letter via submitter.ag; the paper body itself carried no notice, which technically failed arXiv 2024+ policy and looked weird on social-media reshares. Explicit guard against nested `\\thanks` blocks (root cause of the `nested-thanks` RECENT PITFALL tag) is retained.
- `research-foundry/tools/Containerfile.research` now bundles **Mathlib 4 (pinned v4.13.0)** alongside Lean 4. The `theorist` agent's `_run_lean_check` invokes `lake env --dir=/opt/mathlib-shell lean <file>` so any `.lean` source produced by the LLM can `import Mathlib` and use real Mathlib types (`Real`, `Complex`, `ZMod`, `Polynomial`, `Matrix`, `SimpleGraph`, `Finset.card`, `Permutations`, ...). Pre-this-change theorist's seed prompt explicitly forbade `import Mathlib` and fell back to a `variable (P : Prop); theorem T : P -> P := fun h => h` axiom-shell pattern (#795) for any claim referencing undefined symbols — this kept the `VERIFIED_BY_LEAN` certificate honest but very limited in scope. With Mathlib in the image, theorist can attempt formal Lean proofs of real number-theoretic / combinatorial / algebraic claims; the `proof_kind=full` gate (#795 + #797) still ensures that only genuine non-trivial proofs earn the `VERIFIED_BY_LEAN` label. Image bloat: ~3 GB precompiled Mathlib via `lake exe cache get` + one cheap `lake build plausible` for the transitive dep that the cache misses. `theorist.ag::_run_lean_check` now reads `MATHLIB_SHELL` env (set by the Containerfile to `/opt/mathlib-shell`) and uses `lake env --dir=$MATHLIB_SHELL lean` when set, falling back to bare `lean <file>` when unset (so an operator who strips the mathlib layer still gets a working stock-Lean container). theorist's `_lean_prompt` updated to instruct the LLM to use Mathlib types and import statements.
- `research-foundry/tools/Containerfile.research` `ARG AGENTIS_VERSION` bumped `v1.7.17` → `v1.7.18` to pull in the `agentis daemon reload` heartbeat-file liveness fallback shipped in v1.7.18 (mirror of colonies #799 + #800 at the runtime CLI layer). The auto-promote sidecar already operates correctly under v1.7.17 because the sidecar uses its own liveness check, but `agentis daemon reload` was still false-negative on containerized daemons until v1.7.18; the reload path is invoked by the sidecar after a successful confidence promotion to notify the daemon of the new tier, so without this bump the sidecar logged `is not running (zombie)` warnings on every promotion despite the memo write succeeding. v1.7.18 also includes 6 new regression tests for the reload path. No other API surface change. Empirical evidence: in the pre-v1.7.18 claude run `20260526T184127Z` the sidecar journal shows 24× successful confidence-bump promotions paired with 24× `agentis daemon reload: <id> is not running (zombie)` warnings; expected post-bump observation is zero such warnings on the next claude run.
- `tools/auto-promote-config.yaml` thresholds rescaled for finite-run research windows: `min_entries` 200→30, `min_acting_entries` 60→10, `min_runtime_hours` 48→0.5, `delta_slope_window` 100→20, and the review-gated→autonomous `min_acting_entries_override` 120→30. Pre-fix the autonomous tier was structurally unreachable in a 75-tick run (the autonomous-gated substrate primitives — `replicate`, `evolve_self`, `knowledge_sell` pre-#792, auditor #761 audit-guard `decide()`, `_publish_*`'s autonomous-only ledger writes — were therefore dead code in practice). The autonomous-step override stays tighter than the global threshold (30 acting entries vs 10) so the rule-of-three safety margin for terminal writes is preserved at a 10% reject-rate target.
- `tools/auto-promote-decisions.py` adds a heartbeat-file fallback to the containerized liveness check. Pre-fix the sidecar trusted `<agent>:last_check` memo freshness only, but the `.ag` tick-body convention (`memo_write("<colony>:last_check", now)` at end of every tick) is unreliable: many tick bodies short-circuit before reaching the write (missing-upstream picker-empty paths, tier branches that bail early, `exec sh` failures on the `date -u +%Y-...` helper). Concrete reproducer: `noticer.ag` wrote 20 `last_check` entries across 118 actual ticks (~17% coverage) during the post-#798 claude run, because the noticer-without-upstream-output path returns before either of its two write sites. Result was the auto-promote sidecar skipping all 18 research-foundry colonies with reason `memo last_check stale` while the runtime was clearly ticking them. Fallback reads `<fed_dir>/.agentis/daemon/<agent_id>.heartbeat` line 1 (ms-since-epoch of the last completed tick, written by `write_heartbeat_ext` every tick regardless of `.ag` branch taken) and applies the same staleness window as `last_check`. `tools/test-auto-promote.sh` updated to assert on the new reason string and the rescaled CFG_* values; 40/40 tests pass.
- `research-foundry/reviewer/agents/reviewer.ag` `_seed_prompt` now asks the LLM for `hallucinated_claims` as a plain newline-separated string (format `claim_text | line_or_section | why_unsupported` per line) instead of a list of objects. The `Verdict.hallucinated_claims` type was declared `string` since #623 but the prompt schema advertised `[{claim_text, line_or_section, why_unsupported}]`; the agentis runtime treats `prompt() -> T` as loose-typed and accepts whatever shape the LLM returns, so a list value silently passed type-check at prompt() return but then triggered `type error: expected compatible types for Add, got string and list` 71× per claude run when `_publish_reviewer` concatenated `verdict.hallucinated_claims` into the verdict_json string. Discovered live during the post-#795 claude flat-tariff run: pre-claude LLMs (qwen / V4-Flash) had returned plain strings even when the prompt asked for lists, so the bug was latent. Aligning the prompt spec to the declared type is the minimal fix; downstream consumers (memo dump for inspection, no parser) are unaffected.
- `research-foundry/{auditor,reviewer,submitter}/config/colony.example.toml` `cb_budget` bumped `2000` → `200_000_000` and the matching `cb` declaration in each `.ag` file bumped to match (per the CLAUDE.md convention that the two must agree). The previous `cb 2000` left these three colonies starved on heavy ticks at the autonomous tier: auditor at autonomous runs `prompt() + decide() (#761 audit-guard) + ~10 learn() rows`, which can burst past 2000 CB per tick. With the previous low ceiling the daemon dropped to 0% success rate within ~30 ticks of reaching autonomous confidence in the claude run, surfacing `CognitiveOverload: budget X, required Y at: operation costing Z CB` every tick. The seven LLM-heavy colonies (`explorer`, `noticer`, `formulator`, `skeptic`, `verifier`, `novelty`, `computer`) had been bumped to `200_000_000` long ago; this PR brings the rest of the LLM-driven cascade tail to the same ceiling. Search-only colonies (`arxiv-search`, `oeis-search`, `groupprops-search`, `scholar-search`) and the IO-light `editor` / `introducer` / `prior_advocate` / `theorist` are intentionally left at the lower seed because their per-tick CB cost is structurally below 200 CB.
- `research-foundry/theorist/agents/theorist.ag` + `research-foundry/auditor/agents/auditor.ag` now reject degenerate Lean placeholders so `VERIFIED_BY_LEAN` reflects an actual formal proof of the upstream claim, not the unit-true type. Three-layer change: (1) theorist `_lean_prompt` forbids `theorem T : True := trivial` fallback (substituted with the `variable (P : Prop) ; theorem T : P -> P := fun h => h` axiom-shell pattern when a referenced symbol cannot be translated without mathlib); (2) theorist `_run_lean_check` adds a regex defense (`: *True *:=`) that downgrades any matching `lean_source` to `incomplete` so the verdict cannot reach `verified` even if the LLM ignores the prompt; (3) auditor fans in `theorist:<pid>:proof_kind:tick-N` alongside the Lean verdict and the seed_prompt now requires BOTH `lean_verdict='verified'` AND `proof_kind='full'` for `VERIFIED_BY_LEAN` -- `computational` / `empty` proof_kind degrade to `VERIFIED_NEW` (if other novelty signal is strong) or `NEEDS_HUMAN`. Discovered during the post-#794 V4-Pro 75-tick #778 re-run: every emitted `VERIFIED_BY_LEAN` certificate corresponded to a `theorem T : True := trivial` Lean source, i.e., Lean correctly certifying "True is True" rather than the upstream math claim. PR #752 originally permitted the fallback as a cascade-keeping measure when stock Lean (no mathlib) could not formalize an undefined symbol; the cost of the safety net was a quality-bar collapse on the strongest verdict label.
- `research-foundry/tools/Containerfile.research` `ARG AGENTIS_VERSION` bumped `v1.7.16` → `v1.7.17` to pull in the runtime `cb_max_accumulated` default 10k → 1M fix that was previously paired with the colonies-side `novelty.knowledge_sell` tier-gate relax (#792 / agentis v1.7.17). Without this bump the container's bundled `agentis` binary still clamps the accumulated CB budget at 10k, immediately re-creating the exhaustion that #790 / #791 tried to work around at the per-tick level. Empirical pre-fix smoke under v1.7.16 logged 252 CognitiveOverloads in 15 ticks even with `RESEARCH_DAEMON_CB_PER_TICK=100000`; under v1.7.17 the same smoke logged 0.

### Fixed

- `_age_tick_and_check` helper in all 18 colonies (`arxiv-search`, `auditor`, `computer`, `editor`, `explorer`, `formulator`, `groupprops-search`, `introducer`, `noticer`, `novelty`, `oeis-search`, `prior_advocate`, `reviewer`, `scholar-search`, `skeptic`, `submitter`, `theorist`, `verifier`) now consults the `env:RESEARCH_AGING_ENABLED` gate BEFORE constructing `age_key` or calling `memo_write`, restoring the no-op contract promised in [#767](https://github.com/Replikanti/agentis-colonies/issues/767) when aging is disabled (the default). Pre-fix the helper unconditionally wrote `<colony>:<pid>:age_ticks` every tick and only then checked the gate, so every daemon consumed string-heap room for a counter no consumer reads — visible in the post-#798 claude run as `_age_tick_and_check` `tick:error` entries in the two heaviest byte-budget colonies (auditor: 13, submitter: 66) once their per-daemon 16 MiB `string_heap` was full. The deeper `string_heap` saturation in those two daemons (also surfacing in `_pick_upstream_by_confidence` / `_pick_upstream_pid_by_key`) is tracked separately in [#804](https://github.com/Replikanti/agentis-colonies/issues/804). The gated path (`RESEARCH_AGING_ENABLED=1` + `RESEARCH_AGING_THRESHOLD=N`) is unchanged. ([#803](https://github.com/Replikanti/agentis-colonies/issues/803))
- `research-foundry/{submitter,auditor,theorist,explorer}/agents/*.ag` now clamp each per-component ctx string to 4 KB before assembling the LLM prompt, defending the per-tick string heap against the 16 MB runtime ceiling. Pre-fix the submitter and auditor tick bodies both ran ~14 `_pick_upstream_by_confidence` calls per tick (each captures the full ~140 KB `agentis memo list` output and a picked memo value), then concatenated the picked values into a single unbounded `ctx` together with `to_string(rec)` from the AdaptiveEngine (which has no inherent upper bound on returned KB entries). On a 75-tick `claude-full-stack` run this drifted the per-tick string heap close to the 16 MB cap and tripped `EvalError::StringHeapLimitExceeded` in two daemons (submitter at `_pick_upstream_pid_by_key`, auditor at `_pick_upstream_by_confidence` on tick 61); both cascaded into `_age_tick_and_check` errors every tick afterward. Per-component 4 KB clamp matches `research-foundry/computer/agents/computer.ag:318-320` (`max_result_bytes=4096`) and `research-foundry/explorer/agents/explorer.ag:166-170` (`EXPLORER_PROMPT_MAX_BYTES`); worst-case submitter ctx ~40 KB, worst-case auditor ctx ~60 KB, two orders of magnitude under the heap limit with full headroom for picker overhead and `agentis memo list` growth. The `to_string(rec)` projection is now clamped at all three call sites (`submitter.ag`, `theorist.ag`, `explorer.ag`) so future KB growth cannot re-introduce the same drift in any AdaptiveEngine consumer. The LLM-relevant prefix of each component (the head, the typical signal carrier) is preserved across the clamp. ([#804](https://github.com/Replikanti/agentis-colonies/issues/804))
- `research-foundry/tools/run-research.sh` now surfaces the four autonomous-tier ledger files (`discovery-ledger.jsonl`, `audit-ledger.jsonl`, `preprint-ledger.jsonl`, `replication-ledger.jsonl`) at the run-root via symlinks into `laptop-node/`, instead of pre-creating empty top-level files that were never written to. **This is a diagnostic / path-contract fix, not a substrate bug**: the daemons inside the container have been writing to the correct ledger paths all along (the container's `/run-root` is bind-mounted to `<run-dir>/laptop-node/` on the host, so all ledger writes land there). The host-side empty files at the run-root caused operator-facing observers (dashboards, ad-hoc inspection, the acceptance check in the issue) to incorrectly conclude "ledgers are empty / autonomous tier never fires". Investigation on a real 75-tick run found `laptop-node/audit-ledger.jsonl` at 20kB / 22 rows, `laptop-node/discovery-ledger.jsonl` at 21kB / 186 rows, `laptop-node/preprint-ledger.jsonl` at 39kB / 19 rows, `laptop-node/replication-ledger.jsonl` at 611B / 5 rows — i.e. the autonomous-tier writes were firing correctly the whole time. Symlinks preserve the public path contract (`<run-dir>/<name>-ledger.jsonl` still resolves) with zero copies and zero sync logic. The container bootstrap that truncates the actual ledger files inside `/run-root` is unchanged. ([#801](https://github.com/Replikanti/agentis-colonies/issues/801))
- `research-foundry/computer/agents/computer.ag` + `research-foundry/tools/run-research.sh` now defend the `computer` daemon against the unbounded-`prompt()` watchdog SIGKILL observed in the post-#800 claude run. Two-dimension fix: (1) every daemon spawn line emitted by `write_bootstrap()` now carries `--prompt-timeout-s "$DAEMON_PROMPT_TIMEOUT_S"` (default 600s via the new `RESEARCH_DAEMON_PROMPT_TIMEOUT_S` env knob), so a stuck upstream LLM call returns as a tick-level error within the wall-clock cap rather than holding the entire 1800s heartbeat budget and inviting a watchdog kill; the 3x safety margin under the default heartbeat keeps recovery automatic. (2) `tick()` clamps the two unbounded upstream-explorer recall_latest payloads (`claim:explorer_code:tick-N` + `claim:explorer_output:tick-N`) at `MAX_CTX_FIELD_BYTES = 16384` each before concatenating into the prompt ctx and emits a `learn("compute", ..., "partial", ["ctx-clamped", "preprint-foundry"])` row when clamping fires, so a pathological 200KB+ explorer memo on the 56-daemon shape cannot stall the LLM past the heartbeat budget. The two fixes are independently sufficient (#1 recovers from any prompt() hang regardless of cause; #2 prevents the most common runaway-ctx cause) and ship together for defense in depth. New `tools/test-prompt-timeout-flag.sh` is wired into `colony-lint.sh` and asserts every `agentis daemon /run-root/.../agents/<colony>.ag` line in `run-research.sh` carries the `--prompt-timeout-s` flag. `tools/check-learn-tags.sh` extends the `compute:partial` allowlist with the new `ctx-clamped` literal. ([#802](https://github.com/Replikanti/agentis-colonies/issues/802))
- `research-foundry/theorist/agents/theorist.ag` + `research-foundry/explorer/agents/explorer.ag` + `research-foundry/prior_advocate/agents/prior_advocate.ag` no longer pass federation-domain vocabulary strings (`verified` / `incomplete` / `failed` / `cache_hit` / `rejected`) into the `outcome` slot of `learn()`. The agentis runtime outcome enum is `{success, failure, partial, timeout, error}`; the per-call vocabularies are now placed in the `recommendation` slot (preserving log readability + `check-learn-tags.sh` disambiguation) while the outcome slot carries the runtime-valid enum value (`verified→success`, `incomplete→partial`, `failed→failure`, `cache_hit→success`, `rejected→failure`). Discovered during the post-v1.7.17 V4-Pro 75-tick #778 re-run: theorist daemon listed at 20% success rate in `agentis daemon list`, log carrying `[tick:error] invalid outcome 'verified': expected success/failure/partial/timeout/error` per Lean-verified tick. Pre-existing since PR [#752](https://github.com/Replikanti/agentis-colonies/pull/752) (Lean integration) on theorist and since PR [#741](https://github.com/Replikanti/agentis-colonies/pull/741) (knowledge market) on the two buyers; tribes-bench hunter.ag files carry the same latent pattern (`market:cache_hit` / `market:rejected`) and are not fixed in this PR — `tools/check-learn-tags.sh` keeps the legacy pairs as aliases during the transition so existing tribes-bench code lints clean. The unit test `tools/test-check-learn-tags.sh` continues to pass 25/25.
- `research-foundry/novelty/agents/novelty.ag::_publish_novelty` no longer gates its three `knowledge_sell` calls (NOVEL / BORDERLINE / NOT_NOVEL+`classical_identifier`) behind `if final_write`. `final_write` only flips at the autonomous tier per ADR-0001, but no novelty daemon reaches autonomous confidence inside a default 75-tick foundry run, so the entire sell side of the knowledge market was dormant — while the buyer side (`explorer` + `prior_advocate` `knowledge_buy` calls) was already ungated and always cache-missing. The ADR-0001 argument for the gate doesn't hold for this specific call: external-write gating (ledger / cross-handoff) is genuinely terminal, but selling to the local knowledge market is internal state with no external side effect, so propose-tier participation is consistent with the contract. Hunter (`tribes-bench/tribe-alpha/agents/hunter.ag::L1327`) — the precedent the original implementation cited — itself calls `knowledge_sell` unconditionally, so this PR brings novelty into line with the existing convention rather than carving out a new policy. Empirical 15-tick V4-Flash smoke (combined with the agentis runtime `cb_max_accumulated=1M` patch in v1.7.17): 0 → 6 `.agentis/knowledge/*.json` entries (4× `permutation_order_facts:<topic>` at ask_price=3, 2× `known_priors:<topic>` at ask_price=2), with `samples > 1` on several entries confirming buyers found sellers in-run. ([#792](https://github.com/Replikanti/agentis-colonies/pull/792))
- `research-foundry/tools/run-research.sh` default `RESEARCH_DAEMON_CB_PER_TICK` bumped `10000` → `100000` (10×) to handle V4-Pro at 180s tick interval. PR #789 bumped from 2000 to 10000, which was validated on V4-Flash at 60s tick (smoke produced 26 PDFs, 0 overloads). V4-Pro test at 180s tick re-broke the cap: all 18 daemons exhausted within their first few ticks, accumulating 6547 CognitiveOverload errors over 3h and 0 verdicts. Root cause: `daemon.cb_per_tick` is the per-tick **cap** (not a cumulative bonus); longer orchestrator tick interval lets daemons accumulate larger work backlog per tick (multiple prompt() rounds × 50 CB + picker reads × 4 search colonies × multiple pids + Phase 9 PR-C overlay reads + memo writes + fitness updates), commonly bursting > 10000 CB in a single tick. CB is internal accounting (not API \$\$), so the 10× over-allocation has zero real cost while removing the per-tick ceiling as a runtime concern. Auto-scaling cb_per_tick by tick_interval (Path B in #790) is a cleaner follow-up but Path A unblocks the V4-Pro A/B re-run now. ([#790](https://github.com/Replikanti/agentis-colonies/issues/790))
- `research-foundry/tools/run-research.sh` default `RESEARCH_DAEMON_CB_PER_TICK` bumped `2000` → `10000` (replenishment that lands in `daemon.cb_per_tick` of the hermetic `.agentis/config`). The previous 2000 was insufficient for thirsty agents (auditor, submitter, editor, introducer, theorist, 4 search colonies) whose per-tick burst cost — picker reads + LLM `prompt()` + ctx dump + memo writes + Phase 9 PR-C overlay reads + fitness updates — exceeded the replenishment, producing `CognitiveOverload: budget 0, required 1` mid-tick and pinning those daemons in a no-op state. Discovered during smoke validation of the post-#787 main: 1240 overload errors over a 75-tick V4-Flash run, auditor stuck at n=32 from tick ~32 onward. PR #785 had only bumped `computer.ag`'s seed `cb` declaration, which addressed first-tick exhaustion but not the steady-state per-tick burst. The replenishment-side fix is the broadly applicable lever (no per-agent .ag edits). Overridable via `RESEARCH_DAEMON_CB_PER_TICK` env. Substrate-aligned follow-up (wire affected agents into `knowledge_market` as buyers/sellers per `feedback_agentis_substrate_use` operator memo) deferred to the [#459](https://github.com/Replikanti/agentis-colonies/issues/459) Stage 4 emergence epic. ([#788](https://github.com/Replikanti/agentis-colonies/issues/788))
- `research-foundry/tools/run-research.sh` `start_auto_promote_sidecar` no longer races against container daemon bootstrap. The supervisor subshell previously checked `agentis daemon list --json | grep -Fq '"state":"running"'` as its first action and exited "no running daemons; sidecar exiting" within 1-2 seconds of orchestrator launch — but container daemons typically need 5-15 seconds to fully bootstrap after `podman run`. Result was sidecar dying before its first real tick, dashboard banner staying DEGRADED for the rest of the run, and operator-side manual respawn of the supervisor loop required. Replaced exit-on-empty cold-start gate with a bounded retry wait (30 iterations × 2s = 60s ceiling) BEFORE the steady-state `while :; do` loop; the exit-on-empty inside the steady-state loop stays untouched (handles graceful-drain shutdown when daemons stop mid-run, not cold-start race). 60s ceiling is long enough for normal bootstrap, short enough to surface real failures (no daemons spawned at all → exit cleanly). ([#781](https://github.com/Replikanti/agentis-colonies/issues/781))
- `research-foundry/computer/agents/computer.ag` CB budget bumped `2000` → `200000000` to align with peer LLM-driven daemons (verifier, novelty, both already at `200000000`). The computer agent's python-sandbox-driven workload (script generation prompt + exec + memo writes + Phase 9 PR-C overlay reads + fitness updates) costs ~150-250 CB per tick, so the previous 2000 budget exhausted by ~tick 10 on a 75-tick V4-Flash run. Symptom in daemon logs after exhaustion: every tick logs `CognitiveOverload: budget 0, required 1`, the daemon process stays alive but produces no more memo writes; editor / downstream PDF generation cope without further computer outputs because the first ~10 ticks already populated the relevant `claim:explorer_code` / `claim:explorer_output` claim memos for early problems. `research-foundry/computer/config/colony.example.toml` `cb_budget` updated to match per the CLAUDE.md convention (`cb <N>;` in `.ag` must match `cb_budget` in colony.example.toml). ([#782](https://github.com/Replikanti/agentis-colonies/issues/782))
- `research-foundry/verifier/agents/verifier.ag` now runs mechanical Lagrange-class sanity gates BEFORE the LLM `prompt()` call. Two regex-driven detectors over `problem_text` + `stated_answer`: (1) symmetric group claims (`S_n` or `symmetric group on n`) require a numeric `stated_answer` to divide `n!`, and (2) cyclic / dihedral claims (`C_n`, `D_n`, `Z/nZ`) require subgroup orders to divide the cited group order (`|D_n| = 2n`). On detection, the verifier short-circuits to `verdict.verdict = "FALSIFIED_LAGRANGE"` without burning an LLM call — the mechanical check is ground truth that the LLM verifier's broadly-trained classical-math prior cannot override (the failure mode is the LLM verifier agreeing with the producer's bad output). The gate is inconclusive (empty return, fall-through to the regular LLM gate) when no recognised group is cited, when `stated_answer` is non-numeric (typical LaTeX claims), or when the numeric stated_answer is 0 / negative; the short-circuit fires only when BOTH the group order AND the numeric answer parse cleanly AND divisibility fails. New `_publish_falsified_verdict` helper writes the synthetic verdict directly to memo (`verifier:<pid>:verdict:tick-N` + `verdict_label:tick-N`) and records the fitness delta as REJECT-equivalent (-1) so a misbehaving variant that trips the gate often is penalised in replication selection. `verdict.verdict` vocabulary extended with `FALSIFIED_LAGRANGE` (active) and `FALSIFIED_RANGE` (reserved for wave-2 numerical-range sanity gates over OEIS-bounded claims, not emitted yet); downstream consumers (novelty, auditor) already gate on the `verdict_label` memo key and treat any non-ACCEPT label as a hard reject, so the new label rides the existing reject path without schema change. New `research-foundry/tools/test-verifier-sanity-gates.sh` covers 3 trip cases (`S_5` answer 9, `S_7` answer 11, `C_12` subgroup 7), 3 valid-divide pass-through cases (`S_5` answer 15, `C_6` answer 3, `D_6` answer 4), 3 inconclusive fall-through cases (LaTeX answer, no group token, empty answer), plus drift checks asserting the helper fn names + regex literals are present in `verifier.ag` and the gate hook precedes the LLM `prompt()` call. ([#776](https://github.com/Replikanti/agentis-colonies/issues/776))
- `_pick_upstream_by_confidence` in all 9 downstream cascade colonies (editor, skeptic, noticer, formulator, novelty, verifier, auditor, submitter, reviewer) now does **backward-scan over upstream tick numbers** instead of strict exact-tick match. When an upstream colony skips a tick (picker-empty short-circuit, CB exhaustion, prompt timeout), downstream consumers accept the latest tick N ≤ target_tick where data exists. Without this, a single upstream tick gap propagated as cascade starvation: empirically observed on a clean 75-tick V4-Flash run where `verifier` wrote `verdict_label:tick-{0,2,5,29}` and `novelty` (looking for tick 27 = tick_idx − 5) starved forever, producing 0 auditor verdicts despite 30+ minutes of healthy explorer/noticer/skeptic activity. Backward-scan picker yielded 26+ auditor verdicts and 21 PDFs in a matched 75-tick run. The standalone `_pick_upstream_pid_by_key` (used by 4 pid-only call sites in skeptic, novelty, submitter) remains unchanged. Single python invocation now does pid selection by confidence_field + value read at the actual found tick, replacing the prior pid-pick + `recall_latest(exact_tick)` two-step. ([#779](https://github.com/Replikanti/agentis-colonies/issues/779))
- `research-foundry/auditor/agents/auditor.ag` + `research-foundry/reviewer/agents/reviewer.ag` seed prompts carried the same gatekeeper anti-pattern as pre-[#773](https://github.com/Replikanti/agentis-colonies/pull/773) skeptic and pre-[#775](https://github.com/Replikanti/agentis-colonies/pull/775) noticer/novelty — anchored on "You are a strict X". Closes the prompt-shaping sweep for all five LLM-driven gate-bearing colonies (skeptic, noticer, novelty, auditor, reviewer). Run #19 attempt 4 evidence: auditor wrote 9 experience rows but 0 audit-ledger entries (decision biased toward KNOWN_PRIOR / NEEDS_HUMAN over VERIFIED_NEW); reviewer wrote 7 experience rows and only 2 ctx with 0 actual approval outputs (decision biased toward 'rejected' on minor formatting differences). Rewritten following the same template as [#773](https://github.com/Replikanti/agentis-colonies/pull/773) / [#775](https://github.com/Replikanti/agentis-colonies/pull/775): anchor "your job is to triage, not gatekeep", explain cost asymmetry ("false negatives drop the research / block the submitter; false positives waste reviewer compute / push hallucinations to publication"), make the permissive label (`NEEDS_HUMAN` / `approved`) the explicit safe default when uncertain, tighten the negative label (`KNOWN_PRIOR` / `rejected`) to "near-EXACT match" or "central claim with no stdout support whatsoever", loosen the positive label (`VERIFIED_NEW`) to "novel structural angle, even if it touches classical territory". Reviewer prompt now explicitly excludes peripheral motivating remarks from the rejection criterion. Verdict-label vocabulary preserved unchanged: auditor `{VERIFIED_NEW, VERIFIED_BY_LEAN, KNOWN_PRIOR, NEEDS_HUMAN}`, reviewer `{approved, rejected}`. ([#777](https://github.com/Replikanti/agentis-colonies/issues/777))
- `research-foundry/noticer/agents/noticer.ag` + `research-foundry/novelty/agents/novelty.ag` seed prompts carried the same gatekeeper anti-pattern as pre-[#773](https://github.com/Replikanti/agentis-colonies/pull/773) skeptic. Noticer's "If the output just confirms a classical formula, mark boring (surprise_found=false)" and novelty's "You are a strict novelty referee. DEFAULT to NOT_NOVEL" biased a broadly-trained LLM toward false negatives, dropping ~50% of upstream signal at each stage. Run #19 attempt 2 cascade evidence: noticer dropped 32 of 64 formulator ticks at "surprise not found" (50% loss); novelty wrote `claim:*` keys for only 7 of 14 verdicts (50% loss) because the claim-write gate at `novelty.ag:245-269` fires for both NOVEL and BORDERLINE labels but only ~half of verdicts landed in those buckets. Rewritten as triage (not gatekeeping) following the same template as [#773](https://github.com/Replikanti/agentis-colonies/pull/773): anchor "your job is to triage", explain cost asymmetry ("false negatives starve downstream research; false positives waste compute / push trivia toward the auditor"), make the permissive label (`surprise_found=true` / `BORDERLINE`) the explicit default when uncertain, tighten the negative label (`surprise_found=false` / `NOT_NOVEL`) to "near-EXACT re-derivation of a SPECIFIC famous result you can name (cite it)", loosen the positive label (`NOVEL`) to "novel structural angle, even if it touches classical territory". Novelty header comment updated to remove the stale "defaults to NOT_NOVEL" framing. Addresses 2 of 3 blockers tracked in [#774](https://github.com/Replikanti/agentis-colonies/issues/774); the reviewer tick-window blocker remains open.
- `research-foundry/skeptic/agents/skeptic.ag` seed prompt biased the LLM toward dismissing ~100% of noticer surprises by anchoring on "strict skeptic, DEFAULT to dismissing" and requiring `upheld=true` only when "the surprise resists matching to ANY classical result you can identify." Claude Opus's broad classical-math training meets that criterion for essentially any input, so Run #19 attempt 1 (75 ticks × 18 colonies × 2 daemons) measured 100% dismissal across 30 verdicts; the formulator gate (skip on `dismissed`, Phase 4 PR-A [#625](https://github.com/Replikanti/agentis-colonies/issues/625)) then blocked the entire downstream chain — formulator/verifier/theorist/computer/novelty/auditor/introducer/editor/reviewer/submitter all stuck at 1 bootstrap experience row each, 0 substrate primitives fired. Rewritten as a calibrated triage: anchor "your job is to triage, not gatekeep", explain cost asymmetry in-prompt ("false negatives starve downstream research; false positives waste compute"), make `unsure` the explicit safe default, tighten `dismissed` to "near-EXACT re-derivation of a SPECIFIC classical identity you can name (cite it)", loosen `upheld` to "novel structural angle, even if it touches classical territory". A/B re-run (Run #19 attempt 2, same env) measured 100% dismissed → 33% dismissed + 67% unsure + 0% upheld; formulator/verifier/novelty experience rows rose from 1 each to 20/18/16, four search colonies + prior_advocate from 1 each to 8-9 each. `upheld` stays 0 (Opus remains conservative) so the formulator's strict gate still skips most ticks and substrate primitives stay at 0 — that gate calibration and noticer surprise-generation rate are tracked as separate follow-ups. ([#772](https://github.com/Replikanti/agentis-colonies/issues/772))
- `tools/persistent-snapshot.py` now carries the M98 v3 evolved-prompt state across runs by adding an `explorer:` prefix glob (filtered to four cross-run suffixes: `:exploration_prompt`, `:exploration_generation`, `:lineage_id`, `:specialty`). The `_evolve_exploration_prompt` loop in `research-foundry/explorer/agents/explorer.ag` (lines 204-263, mirroring `tribes-bench/*/agents/hunter.ag::_evolve_hunting_prompt`) was already shipped, but the evolved-prompt memo key `explorer:<pid>:exploration_prompt` was not in the snapshot writer's allowlist, so every container relaunch dropped the variant pool back to the `_seed_prompt()` baseline. Per-tick noise keys (`explorer:<pid>:code:tick-N`, `:output:tick-N`) are filtered out by an explicit suffix allowlist to bound snapshot size. New test (5) in `tools/test-persistent-snapshot.sh` pins the round-trip + noise-filter contract. The forensic correction (no `evolve_self()` runtime builtin -- it is a language keyword, M98 v3 is hand-rolled via `prompt(meta, "")`) is documented in the `explorer.ag` header. ([#739](https://github.com/Replikanti/agentis-colonies/issues/739))

### Changed

- Lower default `RESEARCH_<COLONY>_REPLICAS` from 2 to 1 for all 17 non-explorer colonies, and split the claude model per colony (8 opus quality-critical: explorer, formulator, verifier, novelty, prior_advocate, auditor, theorist, editor; 10 sonnet mechanical: noticer, skeptic, 4 searchers, computer, introducer, reviewer, submitter). New per-colony env knob `RESEARCH_<COLONY>_CLAUDE_MODEL`. Wired via `ANTHROPIC_MODEL=` on each daemon spawn line (the claude CLI honors it natively); the shared `llm.args` config drops the `--model` slot. Drops federation peak request rate from ~78 -> ~44 calls/min and shifts ~55% of calls onto sonnet (~5x faster) so the 9-stage cascade clears within the 60-min default run window. Unblocks the zero-preprint stall observed in Run #9-12. ([#711](https://github.com/Replikanti/agentis-colonies/issues/711))
- Bumped `AGENTIS_VERSION` in `tools/Containerfile.research` from `v1.7.12` to `v1.7.13` so the federation container ships with the memo unlimited-by-default + LRU eviction fix from [agentis-core #647](https://github.com/Replikanti/agentis-core/pull/647). Resolves the silent-write-failure cascade that bit research-foundry runs hitting the 500-key memo cap mid-run ([#703](https://github.com/Replikanti/agentis-colonies/issues/703)). The cleanup-sidecar workaround documented in #703 is no longer needed and can be retired.


### Fixed

- `_pick_upstream_by_confidence` helper (9 `.ag` copies) used a hardcoded `meta` role-to-ranking-key map that ignored the caller's `output_key`. For formulator (with 4 output keys: `problem`, `problem_text`, `answer`, `novelty_claim`), every call collapsed to enumerate `formulator:*:problem:tick-N` and either raced bare-string writes or swallowed errors silently → empty return → downstream stages (verifier, novelty, audit pipeline) never called `prompt()`. Run #12 evidence: 222 verifier ticks, all bailed at "no problem text for tick=N" despite formulator writing the data. Fix: explicit `(role, ranking_key, output_key, confidence_field, tick)` signature drops the meta map. Single-replica fast path (1 candidate → skip JSON parse) handles N=1 race-free. Empty-pid path now `print()`s for observability. ([#712](https://github.com/Replikanti/agentis-colonies/issues/712))
- Orchestrator (`tools/run-research.sh start_auto_promote_sidecar`) now writes `<fed-dir>/.auto-promote-install.toml` (TOML schema matching dev-apprenticeship's `install.sh:864-899` for parser compatibility) so the dashboard's sidecar liveness probe reports `installed=true, status="ok"` instead of `running_orphan=true, status="orphan"`. Cleanup trap removes the file on EXIT/INT/TERM to prevent stale install state confusing the dashboard between runs. ([#699](https://github.com/Replikanti/agentis-colonies/issues/699))
- Move `<colony>:last_check` memo write from end-of-tick to top-of-tick (after `_jitter_sleep()`) in all 18 `.ag` agents. Pre-fix, 15 colonies skipped the write whenever early-return gates fired (e.g. waiting on upstream signals), so the dashboard's [#686](https://github.com/Replikanti/agentis-colonies/issues/686) memo-freshness liveness probe flipped them to `pid_alive=false` despite their daemons being alive and ticking. Idempotent — the end-of-tick write is preserved as a no-op refresh on happy paths. ([#697](https://github.com/Replikanti/agentis-colonies/issues/697))
- 4 search colonies (`arxiv-search`, `oeis-search`, `groupprops-search`, `scholar-search`) now use the canonical dashed `<basename>:confidence` memo key — matches on-disk basename per [CLAUDE.md Agent conventions](../CLAUDE.md) and is consistent with the [#688](https://github.com/Replikanti/agentis-colonies/issues/688) `last_check` rename. The bootstrap-loop colony list in `tools/run-research.sh` (3 occurrences) and the `recall_latest` call in each of the 4 `.ag` files were renamed in lockstep so the seeded confidence is now actually consumed by the agents (pre-fix the writers and the readers AGREED on the underscored form internally but Phase 5 PR-A's snapshot writer used the dashed form, so cross-run persistence silently dropped searcher confidence). `prior_advocate` already used its canonical form (matches `prior_advocate/` dir on disk). ([#694](https://github.com/Replikanti/agentis-colonies/issues/694))

### Added

- Phase 5 PR-C: cross-run fitness aggregation. New `--cross-run --window N`
  opt-in flag in `tools/auto-promote-decisions.py` appends a per-run
  record to `persistent/run-history.jsonl` (aggregating per-pid
  `evidence.colony_fitness` rows by specialty) and derives
  `persistent/fittest_specialties.json` from the last N runs using
  exponential decay (factor 0.7; oldest run in window gets weight
  0.7^(N-1), most recent gets 1.0). PR-B's hot-start specialty bias now
  has a populated `fittest_specialties.json` to consume after the first
  successful run. The orchestrator (`tools/run-research.sh`) invokes
  the aggregator once at run-end (after the PR-A memo snapshot, before
  the run-research: done emit_step) via `auto-promote-decisions.py
  --preview --containerized --cross-run --window N --persistent-dir
  <dir>`. New env knob `RESEARCH_CROSS_RUN_WINDOW` (default 5).
  Byte-identity preserved for legacy `--preview` callers (test 12 of
  `test-auto-promote.sh` enforces; new `tools/test-cross-run-fitness.sh`
  pins the PR-C math + 8 edge cases). Closes Phase 5 of [#626](https://github.com/Replikanti/agentis-colonies/issues/626).
- Phase 5 PR-B: hot-start consumers wired into `tools/run-research.sh`.
  At run start the bootstrap reads `persistent/memo-snapshot.json` to
  restore per-colony `<colony>:confidence` (was hardcoded 0.7), and
  reads `persistent/fittest_specialties.json` to bias the 5-explorer
  specialty distribution (top 60% by `avg_fitness` get 4 slots
  round-robin; 1 slot is forced mutation from non-top variants).
  Missing files (or `RESEARCH_PERSISTENT_DISABLED=1`) -> byte-identical
  to pre-PR-B behaviour. New helper `tools/persistent-load.py` with
  two subcommands (`load-confidence`, `weighted-specialty-slots`),
  mirroring the heredoc-free / argv-driven pattern of
  `persistent-snapshot.py`. New `tools/test-hot-start.sh` covers
  round-robin fallback, biased distribution, snapshot-restore, missing-
  key fallback, and bootstrap byte-identity for the no-persistent
  path. PR-C will populate `fittest_specialties.json` from cross-run
  fitness aggregation. Reference: [#626](https://github.com/Replikanti/agentis-colonies/issues/626).
- Phase 5 PR-A: `research-foundry/persistent/` directory scaffolding
  with `SCHEMA_VERSION=1`. At run end the orchestrator snapshots curated
  memo namespaces (`formulator:learned_*`, `editor:learned_pitfalls`,
  `feedback:hitl_*`, `<colony>:confidence` for all 18 colonies) into
  `persistent/memo-snapshot.json` via a new
  `research-foundry/tools/persistent-snapshot.py` helper. Atomic write
  (tmpfile + rename). No consumers yet -- PR-B will read the snapshot
  at bootstrap to bias new replicas toward fit specialties, PR-C adds
  cross-run fitness aggregation. New env knobs:
  `RESEARCH_PERSISTENT_DIR` (default `<fed-dir>/persistent`),
  `RESEARCH_PERSISTENT_DISABLED=1` opt-out. Reference: [#626](https://github.com/Replikanti/agentis-colonies/issues/626).

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
