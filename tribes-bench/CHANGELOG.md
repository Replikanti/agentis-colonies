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

- **Feat(invariants):** optional environmental-invariant surface under
  `tribes-bench/config/invariants/` that formalizes the ad-hoc reputation
  penalties as content-addressed `.inv` predicate modules (agentis-core RFC
  #929, ADR-0009; [#1735](https://github.com/Replikanti/agentis-colonies/issues/1735)).
  ONE shared signal binding —
  `signal reputation = memo("reputation:tribes-bench-<colony>")` — expressed at
  two severities: `reputation-floor-costly.inv` (`class = costly`, advisory,
  `when reputation < 0.3`) and `reputation-floor-inviolable.inv`
  (`class = inviolable`, real `replicate()` refuse / in-tick self-cull,
  `when reputation < 0.1`). The `<colony>` substitution token (agentis-core
  #953) resolves each daemon to its own tribe (`--colony tribe-<name>`), so the
  single shared module set scopes correctly per tribe with no cross-tribe
  contamination — deliberately not the role/`<self>` token, which resolves to
  the shared basename `"hunter"` for all five tribes. `run-stage2.sh` wires the
  keys (`evolution.invariants_dir`, `daemon.invariant_gate`,
  `daemon.invariant_sweep`) into the shared hermetic `.agentis/config` under a
  new `STAGE2_INVARIANTS` knob (default `1`; `0` leaves every key unset —
  byte-identical feature-off) and HARD-ABORTS when `STAGE2_INVARIANTS=1` on an
  `agentis < 1.28.0` runtime (below the `<colony>` floor the token stays literal
  and all five tribes collapse onto one memo key — unsafe under `inviolable`).
  A forensic `invariant-set-hash.txt` sidecar is written per run. The inline
  `+0.05`/`-0.10` reputation arithmetic in `hunter.ag` is unchanged — it is what
  writes the reputation these invariants read; the modules are an additive audit
  / enforcement layer, not a second write path. New pin
  `tribes-bench/tools/test-invariants.sh` (grammar + `<self>`-absence + memo
  contract + `--colony` launch-flag), wired into `tools/colony-lint.sh`.

### Fixed

- **Fix(market):** `tribes-bench/tribe-{alpha,beta,gamma,delta,epsilon}/agents/hunter.ag` no longer pass `"cache_hit"` / `"rejected"` into the `outcome` slot of the `knowledge_market` `learn()` rows. The agentis runtime outcome enum is `{success, failure, partial, timeout, error}`; pre-fix the runtime rejected each call with `[tick:error] invalid outcome 'cache_hit'` (and analogous for `rejected`) so the per-tick error count was inflated even though the federation otherwise worked correctly. Mirrors the research-foundry fix from agentis-colonies PR #794 — the per-call vocabulary (`cache_hit` / `rejected`) is now placed in the `recommendation` slot (preserving log readability + `tools/check-learn-tags.sh` disambiguation) while the outcome slot carries the runtime-valid enum value (`cache_hit→success`, `rejected→failure`). 20 sites patched (5 tribes × 4 sites each: buy_topic cache_hit/rejected + espionage_topic cache_hit/rejected). Pre-existing since [#493](https://github.com/Replikanti/agentis-colonies/pull/493) (Loose category (c) market lifecycle) on each hunter — was kept latent in #794 via the `market:cache_hit` / `market:rejected` aliases in `tools/check-learn-tags.sh`; this PR is the follow-up that migrates the actual sites. `tools/check-learn-tags.sh` schema retains the alias entries during the transition so a partial future revert still lints; the aliases can be removed in a separate cleanup.
- **Fix(emergence):** `STAGE3_DAEMON_HEARTBEAT_MS` env knob (default 1800000 ms = 30min).
  Replaces hardcoded 600000 ms (10min) which was killing Sonnet caveman daemons mid-tick
  due to LLM call latency variance. Take-19 had only 2 ticks/daemon over 30min wall;
  with 30min heartbeat daemons can complete 20+ ticks unimpeded ([#571](https://github.com/Replikanti/agentis-colonies/issues/571)).
- **Fix(rotation, layer 6):** rotation timer now derives `hunter:bugs_manifest` from
  `raw_bm` (user's STAGE3_TARGET_X_BUGS) via separate case conversion, not from
  `$td` source dir. Fixes stage0-3 where bugs.json lives one dir above crate
  (`targets-stage2/bugs.json` vs source at `targets-stage2/smallvec/...`).
  Unlocks cross-stage verification — verifier no longer falls back to env when
  rotated bm path was constructed against wrong location
  ([#569](https://github.com/Replikanti/agentis-colonies/issues/569)).
- **Fix(rotation, layer 5):** orchestrator container bootstrap now copies stage4-*
  crate dirs into sandbox alongside stage0/1/2/3, enabling cross-stage rotation
  to stage4 RUSTSEC crates ([#567](https://github.com/Replikanti/agentis-colonies/issues/567)).
- **Fix(rotation, layer 4):** rotation timer now writes sandbox-relative paths
  (`targets-stage2/smallvec-v0.6.13`) instead of absolute filesystem paths
  (`/run-root/targets/stage2/smallvec-v0.6.13`) which were rejected by agentis
  file_read as 'outside sandbox' ([#567](https://github.com/Replikanti/agentis-colonies/issues/567)).
- **Fix(rotation, layer 3):** stage3/bugs.json bug.file paths stripped of `bumpalo-v3.2.0/`
  prefix to match the convention used by stage2 and stage4 manifests (relative to target
  source root, not to stage dir). Unlocks cross-stage rotation for stage3 hunters which were
  previously hitting 'path outside sandbox' due to doubled prefix
  ([#565](https://github.com/Replikanti/agentis-colonies/issues/565)).
- **Fix(rotation, layer 2):** verifier scripts (`verify-finding.sh`, `verify-finding-stage2.sh`)
  now read `BUGS_MANIFEST` and `TARGET_DIR` from `hunter:bugs_manifest` / `hunter:target_dir`
  memos (set by orchestrator rotation timer per #546/#547), with env-var fallback. Enables
  cross-stage rotation — hunters can now hunt stage4 crates and have findings verified
  against the rotated manifest ([#561](https://github.com/Replikanti/agentis-colonies/issues/561)).
- **Fix(rotation):** orchestrator's rotation timer now writes the memo keys hunters
  actually read (`hunter:target_dir`, `hunter:target_file`, `hunter:bugs_manifest`)
  instead of unread `tribes-bench:*` variants — hunters now rotate in lockstep with
  `STAGE3_ROTATION_INTERVAL_S` ([#546](https://github.com/Replikanti/agentis-colonies/issues/546)).

### Changed

- **chore(llm-backend):** stage runners default LLM backend → `flat-cyborg` (flat-rate Claude via the flat-cyborg PTY wrapper) instead of `cli`→`claude` (stage2) / `openai` (stage3). Host stage2 + both stage3 orchestrators inject `llm.backend = flat-cyborg` + `llm.flat_cyborg.idle_ms` (default 4000, override `STAGE{2,3}_FLAT_CYBORG_IDLE_MS`; optional `STAGE{2,3}_FLAT_CYBORG_MODEL` shared `llm.model`). The Docker path bind-mounts host `~/.claude` → `/root/.claude:rw,z` for flat-cyborg as well as claude (`:z` SELinux relabel for Fedora; [#535](https://github.com/Replikanti/agentis-colonies/issues/535)/[#537](https://github.com/Replikanti/agentis-colonies/issues/537)); `Containerfile.stage3` installs flat-cyborg. `openai` (still enforces its key + injects `[llm.openai]`), `ollama`, and metered `claude` (still injects `llm.command = claude` + effort/model) remain opt-in fallbacks via `STAGE{2,3}_LLM_BACKEND`; 5 tribe configs `cli` → `flat-cyborg`. CAVEAT: the flat-cyborg wrapper drives the `claude` TUI via `--extract` screen-scrape (output fidelity tracks TUI layout) and runs flat-rate (`usage=None`); needs flat-cyborg >= 0.9.0 with `--no-jitter` ([#1136](https://github.com/Replikanti/agentis-colonies/issues/1136), part of [#1132](https://github.com/Replikanti/agentis-colonies/issues/1132)).
- **chore(llm-backend):** `tools/Containerfile.stage3` bumps `ARG AGENTIS_VERSION` `v1.7.12` → `v1.19.0` — the agentis-core release that introduced the native `flat-cyborg` backend. The #1136 default (`llm.backend = flat-cyborg`) is a v1.19.0 feature; the prior pin would reject it at real container runtime (dry-run/CI never executes agentis, so it was latent). The `.sha256` is fetched from the same release tag, so the integrity check self-verifies ([#1141](https://github.com/Replikanti/agentis-colonies/issues/1141), part of [#1132](https://github.com/Replikanti/agentis-colonies/issues/1132)).
- **chore(rate-limit):** `STAGE3_CLAUDE_MODEL` env knob (default `sonnet`). Adds explicit
  `--model` flag to claude CLI invocation; without it, Claude Code defaults to subscription
  tier model (Opus on Max 20x), burning ~5x more tokens than necessary. Restores agentis-core's
  original Sonnet design intent. Operators can opt to Haiku/Opus via override ([#563](https://github.com/Replikanti/agentis-colonies/issues/563)).
- **chore(rate-limit):** `STAGE3_CLAUDE_CAVEMAN` default flipped from 0 to 1 after take-13
  acceptance smoke confirmed caveman+medium effort is quality-equivalent to baseline (5/5
  stage2 bugs identified) at 52% native cost / 80% output tokens. Operators wanting default
  Claude Code session behavior can opt out via `STAGE3_CLAUDE_CAVEMAN=0` ([#559](https://github.com/Replikanti/agentis-colonies/issues/559)).
- **chore(rate-limit):** hunter tick interval now overridable via `STAGE3_HUNTER_TICK_MS`
  env, default 240000 ms (was hardcoded 60000). Extends wall-clock observation window
  ~4x for emergence experiments within Claude Code flat-rate 5h ceiling ([#552](https://github.com/Replikanti/agentis-colonies/issues/552)).
- **chore(rate-limit):** orchestrator now caps per-tribe replicas at 3 by default via
  `STAGE3_MAX_REPLICAS` env var. Keeps total concurrent daemon count predictable for
  Claude Code flat-rate budgets ([#549](https://github.com/Replikanti/agentis-colonies/issues/549)).

### Added

- **chore(rate-limit):** `STAGE3_CLAUDE_EFFORT` env knob (low|medium|high|xhigh|max, default
  medium). Tunes claude CLI reasoning depth in caveman mode. Replaces PR #555's hardcoded
  `--effort low` after take-12 showed 46% verified-hit regression at low ([#557](https://github.com/Replikanti/agentis-colonies/issues/557)).
- **chore(rate-limit):** `STAGE3_CLAUDE_CAVEMAN` env knob (default off). When set to 1,
  orchestrator passes `--tools "" --system-prompt <minimal> --effort low` to claude CLI,
  stripping default Claude Code session overhead from ~38K to ~11K tokens per hunter call.
  Reduces flat-rate weekly burn ~50% per smoke ([#554](https://github.com/Replikanti/agentis-colonies/issues/554)).
- **Stage 4 Phase 1 chunk 2: vendor 5 new RUSTSEC-anchored planted-bug crates + population-scaling knobs (#544)**.
  Brings the Stage 4 planted-bug substrate from 5 bugs / 3 classes
  (chunk 1: `crossbeam-deque`, `owning_ref`, `generator`) to 12 bugs /
  4 classes by vendoring five additional crates at deliberately-vulnerable
  historical tags:
  `ticketed_lock 0.3.0` (RUSTSEC-2020-0119, missing_lock),
  `lock_api 0.3.4` (RUSTSEC-2020-0070 / CVE-2020-35910, missing_lock —
  3-for-1: `MappedMutexGuard` + `MappedRwLockReadGuard` +
  `MappedRwLockWriteGuard`),
  `atomic-option 0.1.2` (RUSTSEC-2020-0113, send_violation),
  `atom 0.3.5` (RUSTSEC-2020-0044, data_race), and
  `syncpool 0.1.5` (RUSTSEC-2020-0142 / CVE-2020-36462, send_violation).
  Class-coverage delta: missing_lock 0 → 4 (closes the gap that left
  the entire bug class untargetable by hunters), send_violation 1 → 3,
  data_race 1 → 2, dangling_borrow 3 (unchanged). Each vendored
  directory follows the chunk-1 template byte-for-byte: 2-line
  `// TRIBES-BENCH STAGE 4 PHASE 1 CHUNK 2 PLANTED-BUG TARGET. INTENTIONALLY VULNERABLE`
  banner prepended on the source file holding the bug, `publish = false`
  in `Cargo.toml`, verbatim `LICENSE-{APACHE,MIT}` files (matching each
  upstream's actual license — `lock_api` is dual; `ticketed_lock` /
  `atom` are Apache-2.0-only; `atomic-option` / `syncpool` are
  MIT-only), `PROVENANCE.md` documenting upstream commit / advisory /
  intentionally-vulnerable warning, and `bugs.json` with line numbers
  derived via `grep -n` against the post-banner source (each upstream
  line shifts +2). All 7 new manifest entries roundtrip clean through
  `verify-finding-stage2.sh` (`{"verified": true, "bug_id": "S4-..."}`).
  `run-stage3-docker.sh` gains `STAGE3_TARGET_F..J_{DIR,BUGS}` env-var
  slots (header docblock + variable declarations + rotation-array
  init blocks parallel to C/D/E from #519); the round-robin counter +
  indirect-expansion logic already generalises to 10 targets. Population
  scaling knobs: `STAGE3_ROTATION_INTERVAL_S` default 1200 → 600 (10
  targets need shorter dwell to cycle inside 6h), `STAGE3_TRIBE_INITIAL_POOL`
  default 0 → 20000 (~10-generation replication runway), and a new
  hermetic-config emit line `printf "memo.max_keys = 50000\n"` to cover
  ~50 hunters × ~100 distinct per-pid keys after the
  `max_replicas_per_tribe` bump. `calibration.toml`: `max_replicas_per_tribe`
  5 → 10 for the long-wall-clock smoke. The originally-planned
  `memo.gc_interval_ticks = 100` emit line was dropped after verifying
  the key does not exist in agentis-core v1.7.12 (`memo.max_keys` is
  the only memo config knob upstream wires); `memo.max_keys = 50000`
  ships solo. Default invocation (no F-J env vars set) emits
  byte-identical dry-run to the chunk-1 baseline — the legacy A/B
  phase-alternation branch in `rotation_timer` is still selected when
  no extra targets are configured. test-run-stage3-docker.sh assertion
  count 150 → 165 (5 header-docs for F/G/H/I/J + 6 rotation-array /
  no-phase-alternation in 10-target mode + 4 config-knob asserts;
  memo.gc_interval_ticks assertion correspondingly absent). colony-lint
  170/0/3 baseline preserved.
- **Containerfile.stage3: bump `AGENTIS_VERSION` v1.7.11 → v1.7.12**.
  Picks up agentis-core [#642](https://github.com/Replikanti/agentis-core/issues/642) (M106 `prepare_replica_spawn` propagates parent's `exec.env_passthrough` resolved values to replica spawns via new wire trailer). Unblocks take-8 multi-tribe federation: M106-spawned replicas in v1.7.11 died on verifier exec sh because `$VERIFIER_PATH` / `$TARGET_DIR` / `$BUG_LEDGER_PATH` weren't propagated from parent. With v1.7.12, replicas inherit the parent's allowlisted env vars and can run their own verifier exec sh round trips. Build verified: `agentis --version` → `agentis v1.7.12` inside the rebuilt image.
- **`run-stage3-docker.sh`: add `:z` SELinux relabel to claude bind-mount (#540)**.
  Take-7 multi-tribe federation smoke surfaced that on SELinux-enforcing hosts
  (Fedora, RHEL, openSUSE) the post-#536 mount `-v $HOST_CLAUDE_DIR:/root/.claude:rw`
  is invisible to containers because `~/.claude` carries `user_home_t` SELinux
  type which `container_t` processes cannot read — regardless of UID or
  permission bits. Inside the container, `stat /root/.claude/.credentials.json`
  returned `Permission denied` and `claude --print` returned `Not logged in`.
  Take-7 was unblocked by a manual `chcon -t container_file_t /tmp/claude-dir
  -R` workaround. Adding `,z` to the bind-mount tells podman to apply a shared
  SELinux relabel automatically — the same approach used by other rootless
  podman tooling. `:z` is a no-op on SELinux-disabled hosts (Ubuntu, Debian).
  Operator security notes expanded in the script comment block: (1) existing
  `.credentials.json` exposure warning preserved; (2) NEW warning not to debug
  the credentials path with raw `cat`/`stat` (terminal scrollback leakage);
  (3) NEW warning that `:z` mutates the SELinux type of the host source
  directory permanently. test-run-stage3-docker.sh assertion count 149 → 150
  with one new "claude mount includes :z SELinux relabel suffix" check.
  colony-lint 170/0/3 baseline preserved.
- **Re-apply #493 consumer-side `knowledge_buy` answer validation (Loose category c)**.
  PR #508 (commit aa21220) originally added a `_validate_bought_answer` gate
  to every `knowledge_buy` callsite in `hunter.ag`, cross-checking the
  returned answer's claimed `bug_id` against the seller-tribe's
  verifier-stamped `bug-ledger.jsonl` before trusting it. The surgical
  restore PR #517 reverted to the pre-#493 baseline (9aacf65) to recover
  from an unrelated regression; PR #518 brought back #491 (verifier-only
  ledger writes) but not #493. This re-applies #493 byte-identically
  across all 5 hunter.ag files: same helper body, same two-callsite gate
  (single-finding buy + bundle/espionage buy), same `rejected_unverified`
  outcome on the per-tick `emit_market_csv` column, same
  `learn("market", ..., "rejected", [..., "reason:unverifiable"])` tag
  schema (already covered by `tools/check-learn-tags.sh`). Rejection is
  non-punitive (no reputation hit, just discard the answer + suppress
  the `hunter:bought_context` memo write so downstream prompts never see
  an unverifiable bought answer); fail-safe defaults collapse every
  parse / exec / lookup failure to `false` (reject), never to accept.
  Closes the Loose category (c) gap re-opened by PR #517.
- **run-stage3-docker.sh `--help` no longer truncates env-var docs + claude-backend test coverage (#537)**.
  Two LOW-severity follow-ups from the #536 QA report. (1)
  `run-stage3-docker.sh --help` used a fixed `sed -n '2,98p'` range
  that truncated as the env-var docblock grew past line 98; new env
  vars from #535 (`STAGE3_HOST_CLAUDE_DIR`), #528 (`STAGE3_DAEMON_CB_PER_TICK`),
  the `STAGE3_OPENAI_*` family, and `STAGE3_LLM_BACKEND` itself were
  all invisible to `--help`. Replaced the fixed range with an
  `awk '/^#/ {sub(/^# ?/,""); print; next} {exit}'` extractor that
  prints every leading comment line until the first non-comment line —
  future env-var additions will surface automatically. (2)
  `test-run-stage3-docker.sh` (145 → 149 assertions) now covers the
  #535 claude-backend wiring: default-openai dry-run contains no
  `/root/.claude` reference; claude-backend dry-run with a valid host
  dir mounts `-v <host>:/root/.claude:rw` into BOTH containers (asserted
  by count, not just presence); claude-backend with a missing host dir
  exits 1. The two other LOW findings from the #536 QA report
  (`/root/.claude.json` builder userID bake + claude installer not
  version-pinned) are deferred — both documented inline in the
  Containerfile and only relevant if/when the image is published to a
  public registry. No behavior change for `--dry-run` or non-help paths.
- **Containerize Claude Code CLI in Stage 3 docker image (#535)**.
  Unblocks full Stage 3 docker federation with claude backend — the
  path to real population-scale emergence research. Tonight's marathon
  shipped 5 architectural fixes to M98 v3 and validated cross-class
  drift end-to-end via take-6 single-process smoke; the substrate
  works. But replication never fires in single-process (M106 needs
  peer workers), no multi-tribe competition, no real selection
  pressure. The full Stage 3 docker orchestrator already wires all of
  that — only blocker was that the container had no LLM client
  installed (assumed OpenAI HTTP backend). This PR fixes that.
  Containerfile changes: bump `AGENTIS_VERSION` v1.7.9 → v1.7.11
  (picks up agentis-core #640 sticky-degraded fix) + install Claude
  Code CLI via the Anthropic-published `claude.ai/install.sh`
  installer + symlink `/root/.local/bin/claude` →
  `/usr/local/bin/claude` so the agentis CLI backend resolves it via
  PATH. Orchestrator changes (`run-stage3-docker.sh`): new env var
  `STAGE3_HOST_CLAUDE_DIR` (default `$HOME/.claude`); when
  `STAGE3_LLM_BACKEND=claude`, bind-mounts the host directory into
  each container's `/root/.claude` (read-write so the Claude Code
  CLI can refresh session tokens). OpenAI-backend code path unchanged
  when `STAGE3_LLM_BACKEND=openai` (default). Build + smoke-verified:
  `podman build` succeeds; `agentis --version` → `v1.7.11`,
  `claude --version` → `2.1.139` inside the image. Operator security
  note shipped in the script comments + header doc-block: mounting
  ~/.claude exposes `.credentials.json` to the container; acceptable
  on single-user dev machines; shared CI runners should provision a
  dedicated session.
- **hunter.ag: pass LLM `finding.class` directly to verifier (closes M98 v3 architectural hole)**
  ([#533](https://github.com/Replikanti/agentis-colonies/issues/533),
  follows the take-5 emergence smoke that exposed every prior M98 v3
  fix (#527/#528/#640/#531) as architecturally bypassed by frozen
  verifier-payload class.) Pre-#533 the verifier received `class` from
  `_variant_class`, derived from `hunter:<pid>:variant` memo — which
  was empty for any local-spawn hunter, falling back to
  `_tribe_default_class()`. Cross-class drift was therefore
  structurally unreachable: the diversification meta-prompt (#530)
  rewrote the LLM-facing text, the LLM correctly described non-UM
  patterns, but the verifier still received `class=uninitialised_memory`
  → every non-UM line attempt was a false positive, and the K=3
  verified threshold (#524) for re-firing evolution never met. Take-5
  confirmed: 17 ticks, 2 verified UM, 15 false positives, evolution
  never re-fired. The fix is one-line per `hunter.ag`: replace the
  `_variant_class` derivation with `finding.class` from the LLM
  output, with a defensive fallback to `_tribe_default_class()` when
  the LLM returns an empty class string. The variant memo is still
  maintained for M106 hash-pointer inheritance (`pp:<sha>|<variant>`)
  + `variant_stats:*` selection signal — only the verifier-facing
  class label changes. The class-alias map (#532) catches LLM-grammar
  ambiguity for any LLM-picked class outside the canonical 8;
  out-of-set classes fall through to false-positive and selection
  still punishes via variant_stats. Option D from the issue body;
  Option C (re-introduce `pick_variant()`) and Option E (couple
  variant class to evolved prompt) deferred — Option D is the
  smallest change that unblocks emergence and preserves the existing
  M98 v3 inheritance + selection scaffolding.
- **verify-finding-stage2.sh: class-alias map breaks false-positive local optimum in cross-class drift**
  ([#531](https://github.com/Replikanti/agentis-colonies/issues/531),
  follows the M98 v3 take-4 emergence smoke surfaced after #527
  ([#530](https://github.com/Replikanti/agentis-colonies/pull/530))
  and #528 ([#529](https://github.com/Replikanti/agentis-colonies/pull/529))
  shipped. Take-4 confirmed cross-class drift behaviorally — hunter
  drifted from line 534 (saturated UM) to line 827 (`insert_many`,
  heap_overflow zone) — but 9/9 attempts were false positives because
  the LLM labelled the described pattern `memory_corruption` while
  the planted bug's `class` field is `heap_overflow`. The verifier
  was strict on class equality, so the LLM-grammar ambiguity blocked
  every verified hit, which in turn prevented the meta-prompt
  evolution from firing again (PR #524 only triggers on K=3 verified
  hits). The daemon ended stuck at a local optimum in false-positive
  loop.) The verifier (`tribes-bench/tools/verify-finding-stage2.sh`)
  now accepts class-alias matches when `STAGE3_VERIFIER_CLASS_ALIASES`
  is `1` (default; set to `0` for strict matching). Alias groups
  capture the LLM-naming ambiguities the smoke surfaced:
  `{heap_overflow, memory_corruption, buffer_overflow}` (out-of-bounds
  writes), `{use_after_free, dangling_borrow}` (references to invalid
  memory), `{data_race, missing_lock}` (concurrent state mutation).
  Singletons `{uninitialised_memory}` and `{send_violation}` stay
  strict — they are unambiguous and aliasing them would dilute the
  cross-class signal. Aliased matches emit one line to stderr so
  post-mortems can distinguish strict vs aliased verifications
  without changing the stdout verdict shape. 5 new tests added to
  `test-verify-finding-stage2.sh` (4→9 cases): strict mode rejects
  alias, alias mode accepts heap↔memcorr, alias mode accepts uaf↔
  dangling, alias mode keeps UM strict (singleton), exact-class
  match still works in alias mode. No new env vars beyond
  `STAGE3_VERIFIER_CLASS_ALIASES`. No bugs.json edits. Anti-gaming
  invariant unchanged — the alias map is in the verifier (the
  ground-truth side); the hunter still cannot influence what counts
  as a verified hit through prompt content. Option B from the issue
  body; Option A (failure-driven mini-evolution) is deferred.
- **M98 v3 meta-prompt rewritten to drive diversification (exploration), not exploitation**
  ([#527](https://github.com/Replikanti/agentis-colonies/issues/527),
  follows the plan-test-7 emergence smoke from #520 / [PR #526](https://github.com/Replikanti/agentis-colonies/pull/526).)
  The pre-#527 meta-prompt template in `_evolve_hunting_prompt()` said
  `"Focus on patterns that produced verified hits."` — which is an
  explicit exploitation directive. Empirically (M98 v3 smoke at
  `/tmp/m98v3-smoke-*`): 6/6 verified hits on the same `S2-SMVMEM-001`
  uninitialised_memory bug, evolved prompt converged to hyper-target
  `from_buf_and_len_unchecked` line 534. Zero cross-class drift —
  exactly opposite of the plan-test-7 success criterion. The rewrite
  in this PR replaces the convergence directive with an explicit
  expansion directive: "if all (or most) verified findings are in one
  bug class, the rewrite MUST explicitly probe for OTHER classes from
  the stage2 verifier set (use_after_free, heap_overflow,
  memory_corruption, data_race, send_violation, missing_lock,
  dangling_borrow, uninitialised_memory) in the same target file. The
  goal is a hunter that finds the NEXT class of bug, not more
  instances of the same one." Identical text applied to all 5 tribes
  (`tribe-{alpha,beta,gamma,delta,epsilon}/agents/hunter.ag`) since
  every tribe's `_evolve_hunting_prompt()` body is byte-identical at
  the meta-prompt site. Anti-gaming and #491/#493 guardrails are
  unchanged (the meta-prompt rewrites the prompt body that the
  hunter sends to the LLM; the verifier remains a deterministic
  shell script with zero LLM in the path, and selection pressure
  still flows only from real verified hits). No new env vars, no
  new memo keys, no new helpers — purely a string rewrite at one
  site per tribe.
- **Bump `daemon.cb_per_tick` from agentis-core default 100 to 2000 in the Stage 3 docker orchestrator hermetic config**
  ([#528](https://github.com/Replikanti/agentis-colonies/issues/528)).
  Surfaced by the M98 v3 plan-test-7 emergence smoke: hunter daemons
  CB-exhausted after ~10 LLM-heavy ticks, became zombies (alive,
  ticking, watchdog-happy) that consumed wall clock + LLM API spend
  without producing any verified findings. M98 v3 evolution-path ticks
  spend ~250-300 CB on prompt + meta-prompt + schema-sanity ping +
  exec-sh helpers; the agentis-core default of 100 CB/tick refill is
  net-negative against this workload and drains the `cb 200000000;`
  lifetime budget within ~10 ticks. New env var
  `STAGE3_DAEMON_CB_PER_TICK` (default 2000) is written into both
  hermetic `.agentis/config` files as `daemon.cb_per_tick = <value>`.
  2000 gives ~7× safety headroom on evolution ticks and sustained
  operation across the full 6-hour wall clock. Lower the value only
  when intentionally reproducing CB-exhaustion behaviour. Affects only
  the docker orchestrator; the non-orchestrator entry points
  (`start-colony.sh` direct invocations) still inherit the
  agentis-core default unless the operator overrides in their own
  `.agentis/config`.
- **M98 v3 PR 3/3 — M106 hash-pointer inheritance across replicate() — M98 v3 COMPLETE**
  ([#520](https://github.com/Replikanti/agentis-colonies/issues/520),
  PR 3/3 of three and the FINAL piece of M98 v3; depends on PR 1/3
  ([#523](https://github.com/Replikanti/agentis-colonies/pull/523))
  merged + PR 2/3
  ([#524](https://github.com/Replikanti/agentis-colonies/pull/524))
  merged + agentis-core v1.7.10
  ([#638](https://github.com/Replikanti/agentis-core/issues/638));
  [#515](https://github.com/Replikanti/agentis-colonies/issues/515)
  carries the architectural rationale.) Evolved hunting prompts now
  propagate from parent to child across `replicate()` over the M106
  wire via a hash-pointer scheme that sidesteps the pre-existing
  `MAX_VARIANT_TAG_BYTES = 1024` cap — **no agentis-core change is
  required**. Mechanics: before each `replicate(target, fit,
  variant_tag)` call (both call sites: M2-Malthusian on a verified
  finding, and the #490 reproductive path on a high-fit parent), the
  parent (a) computes `h = sha256(hunting_prompt)` of its current
  prompt body via a single `python3 -c hashlib.sha256(...)` exec sh
  one-liner, (b) write-once memos the body in the content-addressed
  registry `hunter:prompt_body:<h>` (read-before-write, so steady-
  state replicates churn zero memo writes after the first), and (c)
  wraps the variant_tag as `pp:<sha>|<old_variant>`. Delimiter `|`
  is deliberate: SHA-256 hex is 0-9a-f only and the #499 variant
  pool tokens (`format-pattern-*`, `<class>:format-pattern-*`) never
  contain `|`, so the split is unambiguous on both sides. Encoded
  length: 3 (`pp:`) + 64 (hex) + 1 (`|`) + ≤original variant length
  (≤200 bytes observed) = ≤268 bytes, trivially under
  `MAX_VARIANT_TAG_BYTES`. On the child side, the bootstrap block
  added in PR 1/3 now checks `_variant` for a `pp:` prefix BEFORE
  falling back to the tribe's seed prompt; on a hit, the child
  reads `hunter:prompt_body:<sha>`, adopts the parent's evolved
  body as its starting hunting prompt, and resets
  `hunter:<pid>:hunting_prompt_generation` to `"0"` so the child
  gets a fresh K-window (per the M98 v3 plan; without this, an
  inherited child at gen=5 would evolve only 5 more times before
  cap-reset, defeating the purpose of cross-replicate inheritance).
  Cache miss / empty body / non-hex SHA fall through to the seed
  bootstrap and emit a `learn("hunter_prompt_inherit", _tribe + "/"
  + _self_pid, "sha=<12-hex-prefix>", "failure",
  ["prompt-inheritance", "miss", "tribes-bench"])` row so
  `analyse-stage3.py` can surface inheritance misses (a successful
  adoption emits the same topic with `"success"` /
  `["prompt-inheritance", "adopted", "tribes-bench"]`; both
  outcomes are now allowlisted in `tools/check-learn-tags.sh`).
  **Hex validation is load-bearing:** a corrupted or malicious
  variant_tag starting with `pp:` but with non-hex characters in
  the 64-char SHA slot would otherwise produce an
  unconstrained-byte `hunter:prompt_body:<garbage>` memo lookup;
  `_extract_pp_hash` strips through `tr -d '0-9a-f' | wc -c` and
  returns `""` on any leftover, forcing the bootstrap to fall
  through to the seed instead of attempting the bad memo read.
  **Empty-body guard:** `_publish_prompt_body_and_wrap_variant`
  returns the original variant_tag unchanged when the parent's
  hunting_prompt memo is empty (cold-start race), so an inheriting
  child never adopts an empty body — sha256 of an empty string is
  a valid hex digest and would otherwise propagate, hitting the
  v1.7.10 typechecker's warn-only empty-first-arg path and
  producing zero useful LLM output. **Cache management for the
  `hunter:prompt_body:<sha>` registry:** content-addressed
  write-once. Within a single colony lifetime, sha256 collisions
  are impossible in practice, so no eviction is needed; on colony
  restart memos persist, so cached bodies survive across reboots
  and the new replicas spawned post-restart can still adopt their
  parent's pre-restart body if the parent's pid registry was
  preserved. Three new pure helpers added to each tribe's
  `hunter.ag`: `_extract_pp_hash(variant_tag) -> string` (returns
  the 64-hex SHA on a valid `pp:<sha>` prefix, `""` otherwise — one
  exec sh on the inheritance path only, never the per-tick hot
  path), `_strip_pp_prefix(variant_tag) -> string` (returns the
  original variant flavor after the `pp:<sha>|` prefix; preserves
  legacy first-generation variant strings as-is when no prefix is
  present), and `_publish_prompt_body_and_wrap_variant(self_pid,
  variant_tag) -> string` (the parent-side write-and-wrap helper).
  **Anti-gaming invariant intact:** the verifier remains a
  deterministic shell script with zero LLM in the verification
  path; parent→child prompt inheritance is information bandwidth
  (the child inherits its parent's best-evolved hunting heuristic),
  not selection pressure (the verifier still classifies on `(line,
  signature)` only, independent of prompt body). #491 (no direct
  ledger writes from `.ag`) and #493 (no `knowledge_sell`
  answer-validation bypass) guardrails are unchanged. **Now
  testable end-to-end:** the cross-class drift smoke from the M98
  v3 plan test 7 — 90 min, single tribe — should now produce ≥1
  verified finding in a non-primary class for lineages where
  `variant.class != tribe.default_class`; the pre-#505 baseline is
  0 such findings (lineages drifted off-class get the wrong seed
  every time without inheritance). `tools/check-learn-tags.sh`
  extended with `hunter_prompt_inherit:success` and
  `hunter_prompt_inherit:failure` outcome rows; tribes-bench/tools/
  test-run-stage3-docker.sh extended from 73 to 142 passing
  assertions (per-tribe helper presence + bootstrap branch + both
  replicate-site wraps; hex validation regression; sha256 reference;
  M106 cap fit). With this PR landed, M98 v3 is **complete** and
  ready for the cross-class drift smoke (operator-driven HItL).

- **Retro-add `publish = false` to all 5 vendored target `Cargo.toml` files**
  ([#522](https://github.com/Replikanti/agentis-colonies/issues/522)).
  Defence-in-depth against accidental `cargo publish` of intentionally
  vulnerable vendored code. Covers `tribes-bench/targets/stage2/smallvec-v0.6.13/`,
  `targets/stage3/bumpalo-v3.2.0/`, `targets/stage4-crossbeam-deque-v0.7.2/`,
  `targets/stage4-owning_ref-v0.4.1/`, `targets/stage4-generator-v0.6.25/`.
  No production-leak path exists today (no top-level `Cargo.toml` workspace,
  no `cargo publish` invocation anywhere in repo or CI) — this is a belt-and-braces
  addition so crates.io would reject upload of duplicate-version-by-non-owner
  even if someone runs `cargo publish` in a vendored target dir.
- **M98 v3 PR 2/3 — verified-buffer + meta-prompt evolution + anti-degeneracy guards**
  ([#520](https://github.com/Replikanti/agentis-colonies/issues/520),
  PR 2/3 of three; depends on PR 1/3
  ([#523](https://github.com/Replikanti/agentis-colonies/pull/523))
  merged + agentis-core v1.7.10
  ([#638](https://github.com/Replikanti/agentis-core/issues/638));
  PR 3/3 will add the M106 hash-pointer inheritance path. M98 v2
  ([#505](https://github.com/Replikanti/agentis-colonies/issues/505))
  stays reverted.) Each hunter now maintains a per-pid rolling buffer
  of recent verified findings in `hunter:<pid>:verified_buffer`
  (JSON-array string, truncated to the last
  K = `STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD`, default 3). Every
  verified finding pushes a `{bug_id, line, signature_hint}` row;
  once the buffer reaches K, the hunter fires a meta-prompt LLM call
  that asks the writer model to rewrite the hunting prompt body
  given the verified findings while preserving the
  `Finding{class, line, severity, rationale, signature_hint}` JSON
  output schema. The candidate is then gated by three
  anti-degeneracy guards before it can replace the live prompt:
  (a) **length clamp** at `HUNTER_PROMPT_MAX_BYTES` (default 4096,
  reused from PR 1/3), (b) **Levenshtein floor** — dissimilarity
  between old and new prompt (integer percent, 0..100, computed via
  a single `python3 -c` round trip on the evolution path only,
  never the per-tick hot path) must be at least
  `STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR` (default 5%); below the
  floor the rewrite is treated as a no-op (old prompt kept,
  generation not bumped, buffer untouched), (c) **schema-sanity
  ping** — the candidate is dry-run against a fixed minimal Rust
  fixture and must yield a parseable `Finding` with non-empty
  `class` / `signature_hint` / `rationale` and a non-negative
  `line`; any failure reverts to the prior working prompt without
  bumping generation. Only when all three guards pass does the
  rewrite commit (memo write, generation increment, buffer cleared
  to `"[]"`). **Generation-cap seed reset:** once
  `hunter:<pid>:hunting_prompt_generation` reaches
  `STAGE3_HUNTER_PROMPT_GEN_CAP` (default 10), the next evolution
  resets the hunting prompt to the tribe's seed (verbatim
  `_seed_prompt_for_class(_tribe_default_class())`), generation to
  `"0"`, and increments a per-pid lineage counter
  `hunter:<pid>:lineage_id` (initialised `"0"`) for telemetry
  traceability (consumed by `analyse-stage3.py`'s per-class
  fitness curves). The meta-prompt LLM call still fires once
  before the cap check — intentional per design, lets the
  verifier reward the last evolved prompt before lineage
  rollover. Three new env vars are threaded through
  `run-stage3-docker.sh`'s `exec.env_passthrough` and per-tribe
  bootstrap line:
  `STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD` (default `3`) →
  `HUNTER_PROMPT_EVOLUTION_THRESHOLD`,
  `STAGE3_HUNTER_PROMPT_GEN_CAP` (default `10`) →
  `HUNTER_PROMPT_GEN_CAP`,
  `STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR` (default `5`) →
  `HUNTER_PROMPT_LEVENSHTEIN_FLOOR`. The
  `_levenshtein_ratio_pct`, `_push_verified_finding`,
  `_schema_sanity_ok`, and `_evolve_hunting_prompt` helpers are
  inlined byte-identically into each of the five `hunter.ag`
  files; a follow-up will refactor them into a shared
  `tribes-bench/lib/` once that directory is created.
  **Anti-gaming invariant preserved verbatim:** the verifier
  remains a deterministic shell script with no LLM in the path.
  Hunters still cannot influence verifier behaviour through
  prompt content. Selection pressure flows only from real
  verified hits; the meta-prompt LLM call is writer-side only and
  operates on verified-buffer evidence that the deterministic
  verifier already accepted. The
  [#491](https://github.com/Replikanti/agentis-colonies/issues/491)
  ledger-write monopoly and the
  [#493](https://github.com/Replikanti/agentis-colonies/issues/493)
  knowledge-sell answer-path guardrails are preserved verbatim —
  PR 2/3 introduces no new direct ledger writes, no new
  knowledge-market answer paths; the buffer push and evolution
  trigger only fire inside the existing verified-finding branch
  (after the `verified_str == "true"` check that consumes the
  deterministic verifier verdict). M98 v2's 0%-hit-rate
  recurrence is structurally blocked: the first tick of any
  fresh hunter still uses the pre-#505 seed prompt (PR 1/3),
  evolution only fires AFTER K=3 verified findings, so the
  pre-evolution hit-rate floor is byte-identical to current
  main. **M106 hash-pointer inheritance** (`pp:<sha256>` variant
  tag + `hunter:prompt_body:<sha256>` content-addressed memo)
  remains pending in PR 3/3 — cross-`replicate()` inheritance
  and the agentis-core `MAX_VARIANT_TAG_BYTES` sidestep ship
  there. **Manual smoke verification:** the agentis-core runtime
  has no isolated unit-test harness for `.ag` agents; verification
  is via the `colony-lint.sh` parse + tier-branch pass (gates
  every commit, must report `170 passed / 0 failed / 3 skipped`
  with agentis v1.7.10 installed) plus a wall-clock pilot of
  `tools/run-stage3-docker.sh` (30-min smoke baseline, currently
  16 verified findings per the issue acceptance criteria).
- **M98 v3 PR 1/3 — memo-stored hunting prompts + per-tribe seed bootstrap**
  ([#520](https://github.com/Replikanti/agentis-colonies/issues/520),
  PR 1/3 of three; PR 2/3 will add the verified-buffer + meta-prompt
  evolution path, PR 3/3 will add the M106 hash-pointer inheritance
  path. M98 v2 ([#505](https://github.com/Replikanti/agentis-colonies/issues/505))
  stays reverted; M98 v3 supersedes both M98 v1 (hardcoded smallvec
  prompts) and the M98 v2 generic class templates).
  Each hunter's hunting prompt body now lives in
  `hunter:<pid>:hunting_prompt` instead of a baked literal string at
  the `prompt()` call site. On the first tick of a fresh hunter the
  memo is empty, so the hunter falls back to `_seed_prompt_for_class(_tribe_default_class())`
  — a per-tribe registry that restores the pre-#505 hardcoded prompt
  verbatim — and writes it back to memo together with
  `hunter:<pid>:hunting_prompt_generation = 0`. This preserves
  byte-identical hunting behaviour on the first tick of a fresh colony
  (seed equals pre-#505 prompt; no evolution yet). The hunting call
  becomes `prompt(prompt_text + _variant_overlay_suffix(), src)` — the
  #439 variant-prefix overlay is preserved verbatim, moved from a
  prefix on the source to a suffix on the instruction. A new
  `STAGE3_HUNTER_PROMPT_MAX_BYTES` env var (default 4096) clamps the
  seed body length on bootstrap-read; it is threaded through
  `exec.env_passthrough` so hunter.ag reads it via `printenv`.
  **Depends on agentis-core v1.7.10 ([#638](https://github.com/Replikanti/agentis-core/issues/638))**:
  the new `prompt(prompt_text + ..., src)` shape needs the v1.7.10
  parser relaxation that accepts a non-literal first argument; pre-v1.7.10
  builds will fail to parse hunter.ag with
  `parse error: expected string literal for prompt instruction`.
  **Anti-gaming invariant unchanged**: the verifier remains a
  deterministic shell script with no LLM in the path. Hunters cannot
  influence verifier behaviour through evolved prompt content;
  selection pressure flows only from real verified hits. The
  [#491](https://github.com/Replikanti/agentis-colonies/issues/491)
  ledger-write monopoly and the
  [#493](https://github.com/Replikanti/agentis-colonies/issues/493)
  knowledge-sell answer-path guardrails are preserved verbatim. PR 1/3
  introduces no new direct ledger writes, no new knowledge-market
  answer paths, no evolution call, no inheritance call, no buffer
  maintenance, and no anti-degeneracy guards beyond the length clamp
  — those are PR 2/3 and PR 3/3 territory.

### Added

- **Stage 4 Phase 1 chunk 1 — vendor 3 real RUSTSEC crates with 5 planted bugs covering 4 previously-missing stage2 classes**
  ([#519](https://github.com/Replikanti/agentis-colonies/issues/519),
  closes the bug-class-coverage gap surfaced in
  [#515](https://github.com/Replikanti/agentis-colonies/issues/515),
  follow-up to
  [#459](https://github.com/Replikanti/agentis-colonies/issues/459)).
  Three new vendored target directories under
  `tribes-bench/targets/`:
  `stage4-crossbeam-deque-v0.7.2/`
  ([RUSTSEC-2021-0093](https://rustsec.org/advisories/RUSTSEC-2021-0093.html),
  `data_race`, 1 planted bug `S4-CBDR-001` on
  `Stealer::steal`),
  `stage4-owning_ref-v0.4.1/`
  ([RUSTSEC-2022-0040](https://rustsec.org/advisories/RUSTSEC-2022-0040.html),
  `dangling_borrow`, 3 planted bugs `S4-ORDB-001`/`002`/`003` on
  `OwningRef::map`, `OwningRef::map_with_owner`,
  `OwningRef::as_owner_mut`),
  `stage4-generator-v0.6.25/`
  ([RUSTSEC-2020-0151](https://rustsec.org/advisories/RUSTSEC-2020-0151.html),
  `send_violation`, 1 planted bug `S4-GENSV-001` on the
  unsound `unsafe impl<A, T> Send for Generator<'static, A, T>`).
  Each target ships verbatim `LICENSE-APACHE` + `LICENSE-MIT`
  (owning_ref is MIT-only — see its
  `PROVENANCE.md`), a `PROVENANCE.md` documenting upstream URL +
  commit SHA + RUSTSEC advisory + reproduction recipe, a verifier-
  anchored `bugs.json` whose `line` fields are derived via `grep -n`
  against the post-banner source so the +2 banner shift is baked in.
  All 5 bugs roundtrip cleanly through
  `tribes-bench/tools/verify-finding-stage2.sh`. The
  atomicwrites slot from the original plan was substituted with
  `generator` at vendoring time because
  `advisory-db/crates/atomicwrites/` does not exist — recorded in
  `stage4-generator-v0.6.25/PROVENANCE.md` and the PR body.
  With smallvec (5 bugs) and bumpalo (2 bugs) the planted-bug pool
  now stands at **12 bugs across 5 targets** covering the stage2
  classes `use_after_free`, `uninitialised_memory`,
  `memory_corruption`, `heap_overflow`, `data_race`,
  `dangling_borrow`, and `send_violation` — so M98 mutation
  cross-class drift now has real bugs to find in the 4 classes the
  pre-#519 pool was missing.
- **`run-stage3-docker.sh` rotation timer extended to 5-target round-robin**
  ([#519](https://github.com/Replikanti/agentis-colonies/issues/519)).
  Three new optional env vars
  (`STAGE3_TARGET_C_DIR` / `STAGE3_TARGET_C_BUGS`,
  `STAGE3_TARGET_D_DIR` / `STAGE3_TARGET_D_BUGS`,
  `STAGE3_TARGET_E_DIR` / `STAGE3_TARGET_E_BUGS`) let the orchestrator
  round-robin across up to 5 planted-bug targets per pilot. Each
  optional slot is activated only when both its `_DIR` and `_BUGS`
  pair are set; missing/partial pairs collapse silently so a
  half-configured override never emits an empty memo. **Backward
  compat: when no C/D/E vars are set, the rotation emits the
  byte-identical legacy A/B alternation** — existing pilots see no
  change. `test-run-stage3-docker.sh` adds 13 new assertions
  covering both modes; baseline now 65 passed / 0 failed.

### Removed

- **M98 v2 class-parametrized hunter prompts ([#505](https://github.com/Replikanti/agentis-colonies/issues/505)) — REVERTED via [#515](https://github.com/Replikanti/agentis-colonies/issues/515) finding.** Per smoke validation, generic class-prompt templates structurally drop LLM hit rate from ~30% (with M98 smallvec-specific prompts, smoke #51 baseline = 16 verified in 30 min) to ~0% on real-Rust targets (smokes against original + 7 injected bugs covering all 8 stage2 classes: 0 verified at T+15 min across two fitness-param sweeps). Cross-class drift via M98 mutation is not viable at current LLM capabilities + hand-engineered generic prompts. The hardcoded single-prompt M98 (#503) baseline is restored. Future emergence work pivots to either M98 v3 (LLM-generated prompts learning from past verified finds) or Stage 4 Phase 1 (#459) with diverse vendored real crates re-architected per-crate rather than per-class.

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

- **Static `learn()` tag-schema lint for tribes-bench hunters**
  ([#492](https://github.com/Replikanti/agentis-colonies/issues/492),
  Loose category b). Fitness aggregation reads free-form `learn()` tags
  as authoritative — auto-promote / selection-fitness classifies
  experience rows by tag (`acted`, `replicated`, `false-positive`,
  `reward=<int>`, ...). Once Stage 4 lineage variation lands, an
  evolved hunter could emit
  `learn("hunt", ..., "success", ["acted", "reward=999"])` without
  producing a verified finding and harvest selection reward. New
  `tools/check-learn-tags.sh` walks every
  `tribes-bench/tribe-*/agents/*.ag`, parses each `learn(` call (topic,
  outcome, tag list), and rejects any literal tag that is not in the
  per-`(topic, outcome)` allowlist — the schema covers the 11 pairs
  emitted by the current `hunter.ag` (19 call sites × 5 tribes = 95
  identical-shape sites). Unknown `(topic, outcome)` pairs always FAIL,
  forcing an explicit schema update on every new call site. Suppression
  marker `// colony-lint: learn-tags-ok` is available for intentional
  experimental violations. Wired into `tools/colony-lint.sh` (baseline
  168 → 169 passing checks). Self-test: `tools/test-check-learn-tags.sh`
  (15 cases). **Known gap — dynamic tag evasion:** a tag list built
  from a variable or `+`-concatenation cannot be proven correct
  statically. Default mode WARNs on every such call site; set
  `COLONY_LINT_STRICT_LEARN_TAGS=1` to upgrade to a hard FAIL. A
  core-side runtime validator is the long-term fix and remains a
  follow-up.

- **Consumer-side `knowledge_buy` answer validation (Loose category c)**
  ([#493](https://github.com/Replikanti/agentis-colonies/issues/493),
  partial pair with the verifier-only ledger-writer hardening tracked in
  [#491](https://github.com/Replikanti/agentis-colonies/issues/491)).
  Every `knowledge_buy` callsite in `tribes-bench/tribe-*/agents/hunter.ag`
  now runs a `verify-then-trust` gate on the returned answer before the
  buyer treats it as truth: the claimed `bug_id` is parsed out of the
  answer string and cross-checked against the seller tribe's
  verifier-stamped `bug-ledger.jsonl` via `grep -F`. Two callsites are
  gated — the single-finding buy (`tribes-bench-<sibling>/<bug>` topic)
  parses ` bug=<ID>` from the `line=N bug=ID rationale=...` producer
  format, and the espionage bundle buy (`tribes-bench-bundle/<sibling>`
  topic) verifies every `;`-separated id in the producer's bundle list.
  Both gates are fail-safe — empty answer, missing seller-ledger memo,
  parse failure, or non-zero `exec sh` exit all collapse to "reject the
  answer" (`false`), never to "accept" — and rejection is non-punitive
  (no reputation hit, just discard) because punishment-on-rejection is
  itself a gaming vector that needs adversarial-reputation analysis
  before it lands. The gate runs *after* the existing lifecycle-event
  switch so the four memo-store outcomes (`cache_hit` / `succeeded` /
  `rejected` / `fallback`) stay attributable; a failed semantic
  validation collapses the outcome to a new distinct
  `rejected_unverified` value emitted on both the `learn("market", ...)`
  tag set (with `reason:unverifiable`) and the per-tick
  `emit_market_csv` outcome column. On rejection the
  `memo_write("hunter:bought_context", ...)` is suppressed so the
  buyer's downstream prompt never sees an unverifiable answer. The
  `_validate_bought_answer(answer, seller_tribe, topic_kind)` helper
  and both gate sites are byte-identical across all 5 hunter.ag files;
  no new runtime builtins, no agentis floor bump. **Limitation**: the
  gate only catches sells whose claimed `bug_id` is absent from the
  seller's verifier-stamped ledger. A sell that quotes a `bug_id` that
  *did* happen but lies in the `rationale=<...>` substring is not
  caught — the verifier never inspects free-text rationale. Closing
  that gap (rationale-string anchoring to measurements) is an explicit
  Loose follow-up.

### Added

- **`analyse-stage3.py` per-class fitness curves + `variant-trajectory.csv`**
  ([#513](https://github.com/Replikanti/agentis-colonies/issues/513)).
  Closes the observability gap for the
  [#459](https://github.com/Replikanti/agentis-colonies/issues/459)
  Stage 4 Phase 1 commit decision: until #513, `comparison-stage3.md`
  reduced fitness to a per-tribe variant table that hid cross-tribe
  drift on the 8 stage2 bug classes the post-#499 class-flip path emits
  (`uninitialised_memory`, `use_after_free`, `memory_corruption`,
  `heap_overflow`, `data_race`, `send_violation`, `missing_lock`,
  `dangling_borrow`). Two new artefacts: a `variant-trajectory.csv`
  reconstructed per-(tribe, class, phrasing) time series, and a
  `### Per-class fitness summary` markdown section appended to the
  existing comparison report with 8 fixed rows (one per stage2 class,
  zero-row included so cross-run diffs stay comparable) plus a
  trailing `unknown:<class>` block for any off-pool class-flip
  mutations. The trajectory CSV is a **proportional reconstruction**
  over the `mutation-diff.csv` event timeline -- end-of-run totals
  distributed across replicate-event ordinals -- not observed history;
  the file carries an inline `# trajectory: reconstructed from
  end-of-run totals + replicate-event timeline. Hunter-side
  write-through is the observed alternative, deferred (#513).` header
  comment and the markdown section repeats the caveat so downstream
  readers do not misread the curve as real per-tick dynamics. No
  hunter-side changes; reuses the `variant_stats:*` memos hunters
  already increment plus the per-event timeline that #496 emits. Per-run
  only, no cross-run aggregation. Schema:
  `ts,tribe,class,phrasing,verified_cumul,falsepos_cumul,hit_rate`.

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

