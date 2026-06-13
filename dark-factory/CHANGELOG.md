# Changelog — dark-factory

All notable changes to the `dark-factory/` federation will be documented in
this file.

This federation follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
at the federation level. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tags use the prefixed form `dark-factory-v<X.Y.Z>` so other federations
in this repo can release independently without collision.

Every release declares its runtime floor as `**Requires:** agentis >= X.Y.Z`.

## [Unreleased]

### Added

- Release wiring (#1002) — `dark-factory` is now a first-class release target. The shared
  `tools/make-federation-bundle.sh dark-factory <X.Y.Z>` already stages a curated tarball from
  `BUNDLE.manifest`; this change registers the `dark-factory-v*` tag prefix in
  `.github/workflows/release.yml` so a tag push builds the bundle and creates/updates the GitHub
  release automatically (same flow as the other federations). `dark-factory/` was already tracked by
  `tools/check-changelog.sh` (added in #965), so the `[Unreleased]` soft-check covers it too. After a
  release PR merges: `git tag dark-factory-v<X.Y.Z> <merge-sha> && git push origin dark-factory-v<X.Y.Z>`.

- `contest-watch.sh` — a durable, host-cron-able watcher for newly-opened audit competitions (Sherlock
  API + Cantina/Code4rena probes). On a fresh contest it notifies via a state file / optional webhook /
  optional command, so an early audit pass can start day-1; it survives across sessions, unlike an
  in-session reminder. Validated: detects a RUNNING contest, stays silent when the platforms are dry.

- Discovery: **function-level slicing** + a 600s deep-read budget (#863). A scope entry can now be
  written `file@fn1+fn2` to feed the hunter ONLY those functions (plus the contract header) instead of
  the whole file — `auditor/slice-fns.sh` (awk, brace-matched) extracts them, wired through
  `hunter.ag`'s `cat_file` (via the `SLICER` env) and `run-discovery.sh`. This fixes the deep
  liquidation/redemption cells timing out on big contracts, where a whole-file concat overflowed the
  LLM per-call budget (e.g. a Compound-fork `CToken.sol` 1193→134 lines, a credit-vault
  `CollateralVaultBase.sol` 611→152 lines). The discovery LLM timeout is also raised 300s→600s — the
  reasoning, not the payload, is the real cost, and one 600s attempt beats three wasted 300s retries.

- Custom-code DISCOVERY track — the colony can now hunt bugs in bespoke, never-forked protocols, not
  just match known-fork patterns (#863). The DAG matcher (`auditor.ag`) fires only where in-scope code
  recurs a seeded pattern, so it returns nothing on custom contest code (a fresh stablecoin, a new
  vault). The discovery track closes that gap, entirely on the agentis substrate:
  - `auditor/agents/hunter.ag` — a substrate discovery agent. One invocation hunts ONE bug class over
    ONE subsystem: it slurps the in-scope contracts, loads the taxonomy lens + protocol brief, runs a
    deep adversarial `prompt()`, and records the attempt via `learn()` (+ `emit`) so per-class fitness
    reweights over targets (the #861 evolve loop, now over discovery).
  - `auditor/bug-taxonomy.md` — the discovery knowledge: 14 DeFi bug classes (share-price/ERC4626,
    oracle, cross-chain/LZ, withdrawal-queue, access-control, accounting, sig-replay, reentrancy,
    decimals, liquidation, first-depositor, slippage, compliance, fork-delta), each with a "hunt" lens
    distilled from real audits.
  - `run-discovery.sh` — operator entrypoint. Takes `--repo` + a `--scope` manifest
    (`subsystem | classes | files`) + a `--brief` (invariants-to-break, known-issues-to-exclude, trust
    model) and fans out one substrate hunter per (subsystem × class), collecting `CANDIDATE` leads into
    a report. Never posts to a platform; surfacing harness-checkable leads is the whole job.
  - `evm-harness/forge-verify.sh` — the multi-contract verification gate. A custom protocol needs a full
    Foundry deployment + attacker tx + invariant assertion (not the single-function revm harness), so a
    candidate is VERIFIED only when its `Exploit.t.sol` PoC PASSES against the in-scope repo. A lead that
    does not reproduce is not a finding (no junk submitted).
  - **Proven end-to-end on a live, 3×-audited custom yield-bearing-stablecoin Sherlock contest**: the
    substrate hunter read the ERC4626 savings + rewards-distributor contracts under the C1 share-price
    lens and returned a reasoned `SAFE` — a rigorous negative, the valid outcome on audited code. Wiring
    is mock-smoke-tested; the real claude pass completes the full prompt→verdict→learn loop.

- M4 evolution — the matcher granularity tunes itself by fitness (#861). The fuzzy matcher's
  granularity (shingle-Jaccard threshold × shingle width `k`) is the knob no human can hand-tune:
  too loose floods synthesis, too tight misses forks, and the sweet spot is unknown a priori — a
  search problem, and the fork-pair recall harness IS the fitness function. `auditor/agents/
  pattern-evolver.ag` + `evolve-matcher.sh` search the genome against a held-out fork-pair oracle
  (forkpair-recall.js), record EACH candidate as substrate experience via `learn()`, select the
  F-beta-max config (beta>1 = recall-leaning, since the two-sided gate absorbs false matches), and
  write `evolved:fuzzy_threshold` / `evolved:fuzzy_k`. `run-audit.sh --use-evolved <dir>` adopts that
  config (also `--fuzzy-threshold` / `--fuzzy-k` to set them directly); `fuzzy-match.js` /
  `forkpair-recall.js` gained a `k` arg, and reconn/recall-match pass `FUZZY_K`.
  - **Proven end-to-end on Compound→Venus**: the hand-set default (th=0.35, k=4) scores F-beta 0.549
    (recall 54%); the evolver searched 15 genome points and picked **th=0.25, k=4 → F-beta 0.674
    (recall 85%)** — a config no human chose — then `run-audit --use-evolved` adopted it
    (`adopted evolved matcher granularity threshold=0.25 k=4`) and fuzzy-matched a real fork. The
    granularity is now fitness-driven, not hand-guessed; `--beta` tunes the recall/precision trade.

- M3 held-out recall harness + knowledge-market sharing (#861). Measures whether the seeded DAG
  catches a finding's FORK it did not see seeded, and shares the corpus across the federation:
  - `recall.sh` + `auditor/agents/recall-match.ag` seed with the real `seed-patterns.ag` (zero
    seed-side drift) and match each held-out target with a mirror of reconn's exact + structural
    matchers, then tally exact-only vs structural recall per class + precision on negatives.
  - `evm-harness/make-variants.js` generates realistic fork variants of a seeded function (rename /
    reformat / re-literal = what a real N-day fork is) plus structural negatives (call-kind swap,
    injected guard) that MUST NOT match. Reuses `struct-sig.js`'s exported KEEP set so a renamed
    fork keeps the same signature; `struct-sig.js` now `module.exports` its token rules.
  - `harvest-sherlock.js` handles BOTH Sherlock judging layouts — the old `NNN-H`/`NNN-M` folders
    and the new flat `NNN.md` files (severity inside the file).
  - **Synthetic result** on 41 real shape-based findings from 4 Sherlock contests (164 held-out
    forks): exact-only recall 6%, structural recall 94%. But these forks are GENERATED
    (rename/reformat/re-literal) — exactly the transforms struct-sig was built to be invariant to —
    so 94% is an **upper bound on near-verbatim forks**, not a real-world hit-rate.
  - **Real fork-pair result** (`evm-harness/forkpair-recall.js`, the honest measurement): seed a
    function from one protocol and match the SAME function as actually deployed in a protocol that
    forked it — Compound `CToken.sol` vs its Venus `VToken.sol` fork, 48 shared functions. Exact
    signature recall is **17%** (only the simple getters; the vuln-bearing functions like
    `redeemFresh`/`accrueInterest` are ~2x rewritten in the fork and never hit). Two struct-sig
    fixes surfaced by this (modifier-order canonicalization + `uint`/`uint256` aliasing) lifted it
    from 0% to 17%.
  - **Fuzzy matcher** (`evm-harness/fuzzy-match.js`) — the recall lift for REAL forks. Matches on
    shingle-Jaccard SIMILARITY instead of signature equality, so a restructured fork still hits:
    Compound->Venus fuzzy recall **69% @ 0.30 / 54% @ 0.35 / 46% @ 0.40** (incl. the vuln functions),
    at ~52-67% precision (structurally-similar-but-different functions also match — gate-safe, a
    false candidate costs one inconclusive synthesis, never a finding). Wired into reconn
    (`match_seeded_fuzzy_evm`, the third fallback after exact + structural) and the recall harness.
    Proven end-to-end through the colony: seed Compound `redeemFresh`, audit Venus's real forked
    `redeemFresh` (Jaccard 0.41) -> `SEEDED FUZZY MATCH -> Reentrancy`, guard fired `[High]` where
    exact + structural both missed.
  - Known limitation: the in-`.ag` `strip_comments` accumulates an O(n^2) string heap and overflows
    on a full ~1500-line real contract target (the exact/structural paths run it first). Real
    full-contract auditing needs that rewritten; single-function and mid-size targets are unaffected.
  - `auditor/agents/share-patterns.ag` + `run-audit.sh --share-patterns` publish each seeded
    `bugpat:exact:<hash>` / `bugpat:struct:<hash>` to the knowledge market (`knowledge_sell`, keyed
    by content hash) so other federation members can `knowledge_buy` it — "share the DAG via the
    knowledge market". The buy side is a real economic exchange (the buyer escrows the ask price
    from its CB pool), so importing a shared pattern requires a funded consumer.

- M1+ structural-variant bug-pattern matching (#861) — `evm-harness/struct-sig.js` + a new reconn
  fallback. Exact-hash seed matching (the prior M1) catches only a byte-identical N-day fork of a
  recorded finding; this also catches a RENAMED / REFORMATTED / RE-LITTERED fork. `struct-sig.js`
  normalizes each Solidity function to a parser-free structural signature (identifier names → `_`,
  literals → `0`, keeping Solidity keywords / types / external-call kinds), so a variant collapses to
  the same content hash as the seed — no solc, so it works on a bare harvested fragment too.
  `seed-patterns.ag` now seeds `bugpat:struct:<hash> = class` alongside the exact one (guarded to sigs
  that carry a call-kind or storage-write, so a trivial getter is never seeded), and reconn
  (`match_seeded_any_evm`) tries the exact match first, then the structural fallback. Proven end-to-end
  through the colony: a Reentrancy seed matched a renamed/reformatted variant (`SEEDED STRUCTURAL
  MATCH -> Reentrancy`, guard fired `[High]`) where exact-match returned nothing, while a CEI-reordered
  SAFE version correctly did NOT match. A structurally-edited variant (reordered statements / changed
  expression shape) is out of scope for v1 — that needs an AST/semantic signal. An over-broad match can
  never mint a false finding: it only sets the candidate class; the two-sided synthesis gate stays the
  only source of truth.

### Fixed

- Real FULL-contract auditing — `strip_comments` no longer overflows the string heap (#861). The
  in-`.ag` `strip_comments` builds its result with `reduce(lines, |acc,l| acc + ...)`, which is
  O(n²) string allocation and overflowed the 16 MiB per-tick string heap on a full ~1500-line real
  contract — so reconn/guard died before ever matching, and the colony could only audit extracted
  single functions. agentis has no `join`/`regex_replace` builtin for an in-`.ag` O(n) rewrite, so
  the EVM path now offloads to `evm-harness/strip-comments.js` (O(n), reuses struct-sig.js's
  stripComments); the Rust path keeps the in-`.ag` stripper. Seed + match both offload, so exact
  hashes stay aligned. Proven: the full 84 KB Venus `VToken.sol` (65 functions) now audits
  end-to-end — `distilled 65 sub-graph(s)` → `SEEDED FUZZY MATCH -> Reentrancy` → guard fired
  `[High]`, where before it died in `strip_comments` with `string_heap limit exceeded`.
- Decomposed-synthesis EXPLOIT slot now uses `try_call`/`try_call_value` (revert-tolerant) for the
  attack step instead of `call`/`call_value` (which `die` on a revert). On a secure target the attack
  reverts — which means the invariant HELD — but a plain `call` turned that into a false
  `HARNESS ERROR` (exit 2) that masked the verdict and burned `retry(5)` rounds. Surfaced running the
  colony on a real complex target (Cyfrin Puppy Raffle): the decomposed synthesis produced
  sophisticated correct exploit code and CONTROL passed, but the exploit's `call` reverted → exit 2.
- Real-repo compile robustness in `evm-harness/solc-resolve.js`: (1) handle caret/range pragmas
  (`^0.7.6`, `~0.8.4`, `>=0.7.0 <0.8.0`) by selecting the floor solc version when its minor differs
  from the local pinned build (real repos overwhelmingly use caret pragmas; an exact-pin-only match
  fell through to the local solc and failed with "requires different compiler version"); (2) resolve
  Foundry-default remappings written WITHOUT a trailing slash (`@openzeppelin/contracts=lib/…/contracts`)
  via `path.join` instead of `path.resolve` (the no-trailing-slash remainder starts with `/`, which
  `path.resolve` treated as absolute and discarded the project prefix → "import not found"). Surfaced
  by running the colony on a real OpenZeppelin-based Foundry target (compiles 0.7.6 + resolves OZ imports).

### Added

- M2 harvest — `harvest-sherlock.js` pulls real findings from a Sherlock judging repo (the `NNN-H`/`NNN-M`
  valid-finding folders) into a seed manifest for the DAG bug-pattern matcher (#861). It maps each
  finding's title/lead to one of the colony's verifiable classes (Reentrancy / AccessControl /
  UncheckedCall / OracleManipulation / IntegerOverflow) by keyword cue, extracts the vulnerable function
  from the finding's `solidity` block, and emits `<NNN>.sol` + a `Class|path|func-marker` manifest that
  `run-audit.sh --seed-manifest` feeds to the seeder. Findings whose root cause is NOT one of the five
  classes (subtle / multi-contract logic) are skipped — the harness can't verify them anyway. Proven on
  the Alchemix Sherlock contest: 20 findings -> 4 real patterns seeded with their actual functions.
  (Exact-hash match catches verbatim N-day forks of these; structural-variant matching is the next step.)

- DAG bug-pattern matching — seed the federation's content-addressed DAG with real findings so the
  colony recognizes recurring patterns (N-day forks) on real targets (#861). `seed-patterns.ag` +
  `run-audit.sh --seed-manifest` record a finished-contest finding's vulnerable-function sub-graph as
  `bugpat:exact:<hash> = class`; reconn's new `match_seeded_evm` looks up each target sub-graph against
  the seed (mirroring `distill_subgraphs_evm`'s hashing) and guard fires the matched class **directly**,
  beating the LLM classifier's conservative SAFE on real audited code (which returned SAFE on 13/13 real
  contracts in testing). The two-sided real-EVM gate still verifies, so a stale/over-broad seed can never
  mint a false VERIFIED — worst case one inconclusive synthesis. Proven end-to-end: seed VulnToken's
  `mint` (AccessControl) → a fork (renamed contract, identical `mint`) matches → guard fires via the seed
  (no LLM) → synthesis VERIFIED. Exact-hash match catches byte-identical N-day forks; structural-variant
  matching + a harvest of real findings are the next steps.
- Decomposed EVM PoC synthesis (#982). The synthesis agent no longer asks the LLM for the WHOLE
  `poc.rs` in one prompt — a large OUTPUT that stalls `claude -p` on a non-trivial contract (a real
  target's one-shot never returned at a 600s timeout; a small-output fragment prompt returns in
  ~40s). Instead a fixed skeleton (`evm-harness/poc-skeleton.rs`) carries all the revm-14 boilerplate
  + helpers, and the LLM fills only two small slots — the CONTROL block and the EXPLOIT block (~15
  lines each) — which `evm-harness/assemble-poc.js` splices in. Each generation is small + fast and
  the LLM writes far less error-prone code (the helpers handle the fiddly revm API). The two-sided
  gate (`CONTROL OK:` + `INVARIANT VIOLATED:` + exit 101) is unchanged. Validated end-to-end through
  the live colony: a real OpenZeppelin Foundry target reaches VERIFIED in ~48s on the first attempt.
  Solana / std-only targets keep the single one-shot prompt (their PoCs are smaller).
- Real multi-file Foundry/Hardhat target support (#980). The EVM colony can now compile + run on
  real multi-file projects (OpenZeppelin/lib imports, inheritance, a project-pinned solc), not just
  self-contained single-file contracts. A project-aware compiler (`evm-harness/compile-project.js`
  + shared `evm-harness/solc-resolve.js`) resolves a target contract's imports via the project's
  remappings + layout (lib/ submodules, node_modules) and selects/loads the project's solc version
  (offline from an on-disk soljson cache, host-side `--warm` pre-download); a dep-fetch helper
  (`fetch-target.sh`) clones a target repo with its submodules/deps; `run-audit.sh` gains
  `--repo` / `--in-scope` / `--contract`; and the `auditor.ag` `compile_run` + reconn (`ast.js`)
  paths dispatch to the project compiler when a repo target is set. The colony detects + verifies
  the single-contract bug classes on real code via the unchanged two-sided real-EVM gate; complex
  multi-contract protocol-exploit verification remains the later frontier.
- EVM/Solidity auditing — M4 (agentis-core#858). The EVM calibration corpus + harness, the peer of
  the Solana `calibrate-sealevel.sh` / `sealevel-scorecard.md`. A five-class vuln+safe corpus in
  `evm-harness/contracts/` (Reentrancy + AccessControl reused from M1–M3, plus new UncheckedCall,
  OracleManipulation, and IntegerOverflow pairs — each vuln written to be unambiguously its own
  class, all solc-0.8.26-compileable with committed `contracts/bin/*.bin`), `calibrate-evm.sh`
  (runs `run-audit.sh` over the five class pairs, tallies true-positive / false-VERIFIED /
  non-SAFE, parameterized by `BACKEND`/`AGENTIS`/`EVM_HARNESS_DIR`), and `evm-scorecard.md` (the
  scorecard doc with the corpus table, methodology, and an operator-fillable RESULTS template).

- EVM/Solidity auditing — M2 + M3 (agentis-core#858). **M2**: real Solidity reconn ingest
  (`evm-harness/ast.js`, solc AST → the canonical `{kind,name}` node stream → DAG), replacing
  M1's `.sol` bypass so EVM targets get the full reconn→guard→tracker pipeline (target hash
  unchanged → verdict cache + two-sided gate intact). **M3**: the full EVM class set —
  `classify_evm_llm` returns Reentrancy | AccessControl | UncheckedCall | OracleManipulation |
  IntegerOverflow | Safe, each with a per-class CONTROL/EXPLOIT invariant (`evm_invariant_for`)
  fed to the revm-PoC synthesis, plus the EVM peer of the #852 anti-forgery gate
  (`pocChallenge_<nonce>` injected into the target; a supplied `--poc` must surface the nonce or
  is rejected — fail-safe). Validated end-to-end on the live runtime: AccessControl vuln →
  `VERIFIED` (Critical) + human-gated package, the guarded variant → `SAFE`; reentrancy unchanged.

- EVM/Solidity auditing in the colony — M1 (agentis-core#858). `auditor.ag` now dispatches on
  `EVM_HARNESS_DIR` / a `.sol` target: the LLM writes a self-contained `revm` PoC, the target +
  a generic reentrancy attacker are solc-compiled host-side (`evm-harness/compile.js`, solc 0.8.26
  pinned via `package.json`), and the PoC runs the unchanged two-sided gate (`CONTROL OK:` +
  `INVARIANT VIOLATED:` + `exit 101`) through the real EVM (revm). `run-audit.sh` gains
  `--evm-harness` and accepts `.sol` targets; the submission package preserves the EVM PoC +
  attacker. Validated end-to-end on the live runtime: the reentrancy vault → `VERIFIED` +
  human-gated package; the secure variant → `SAFE` (no false-VERIFY). Scope is the reentrancy
  class with a `.sol` reconn bypass; Solidity reconn ingest (M2) and the broader EVM class set
  (M3) follow.

### Security

- Harden the supplied-`BOUNTY_POC` path so a target-agnostic forged PoC cannot mint a false
  `VERIFIED` (agentis-core#852). The `assess()` two-sided gate is byte-for-byte unchanged; the
  fix lives entirely in the `BOUNTY_POC` branch of `synth_via_prompt()`. A human-supplied PoC
  must now (1) structurally reference the in-scope target/harness for the active mode
  (`poc_exercises_target`) and (2) pass a per-run target-linkage challenge: a fresh nonce const
  is appended to the target the PoC compiles against, the PoC is wrapped to echo it before its
  own `main` runs, and the run output must surface the nonce — a PoC that never links this run's
  target cannot. The documented "simply prints both markers without exercising the target"
  forgery is now rejected (new negative-test fixture `fixtures/forged_marker_printer.rs`). The
  autonomous LLM/template path is untouched, and `calibrate-sealevel.sh` (3/3 true-positive,
  0 false-VERIFIED) still passes because the committed `sealevel/*/poc.rs` link the target and
  surface the nonce. Residual (documented): a sophisticated operator-supplied PoC that links the
  target but never invokes the vulnerable path cannot be distinguished from captured stdout — an
  operator-trust assumption on the explicit override, not an autonomous gap.

### Added

- Operator runbook (V8): `docs/RUNBOOK.md` — a one-page guide an operator follows to run a
  real audit from scratch: prerequisites + one-time offline-toolchain warm, pointing at a
  scope (target, native/anchor harness, optional frozen snapshot, backend), the exact
  `run-audit.sh` command, reading the verdict (VERIFIED / INCONCLUSIVE / SAFE), where the
  report + PoC land, the manual human-gated submission step, the calibration scorecard, and
  known limitations (vuln classes, chains/shapes, the snapshot owner-rebind, the
  operator-supplied-PoC trust boundary).

- Operator entrypoint + human-gated submission package (V7): `run-audit.sh` runs the auditor
  end-to-end against an operator-chosen scope (`--target` program, optional `--harness` /
  `--anchor-harness`, optional `--snapshot`, `--backend`, `--sandbox`) and, on a VERIFIED
  finding, assembles a submission package on disk (`submission/`: the Immunefi-format
  `report.md` embedding the PoC, the PoC source, the target, the snapshot, + a `MANIFEST.txt`
  marked `PENDING HUMAN REVIEW — NOT SUBMITTED`). It NEVER contacts a bounty platform, NEVER
  auto-submits, and NEVER auto-picks a scope — the operator supplies the target, and
  submission is a separate, explicit human action. The colony has zero platform-egress
  builtins (only host-side `prompt()` + sandboxed `exec`). Validated: a VERIFIED run stages a
  complete human-gated package; a non-VERIFIED run stages nothing.

- Real on-chain state snapshot (V4): `snapshot-rpc.sh` fetches accounts from a Solana RPC
  (`getAccountInfo`, base64) host-side and freezes them to a **content-addressed** snapshot
  (real `owner` / `lamports` / `data` — not a hand-written stub). The native vault harness
  gains a `poc_snapshot` bin that seeds the vault account from a frozen snapshot's real
  `lamports` + data bytes and replays the MissingSignerCheck invariant through the real SVM
  **fully offline** (zero network in-sandbox). The colony wires it in: `snapshot_state()`
  recognises the real account format, and when the native harness is active with
  `BOUNTY_SNAPSHOT` set the report's snapshot section is produced by a real offline SVM
  replay (`run_snapshot_replay` / `harness_snap_section`) instead of a std-only stub.
  Validated against a real mainnet account (the USDC mint): the frozen snapshot's real data
  drives a `CONTROL OK` + `INVARIANT VIOLATED` two-sided replay offline. A zero-value /
  foreign snapshot stays inconclusive (no false-VERIFIED).

- Calibration on real `coral-xyz/sealevel-attacks` lessons (V6): an offline,
  Anchor-capable PoC harness (`solana-harness-anchor/` — `anchor-lang` 0.31 +
  `solana-program-test` 2.x + `spl-token`, committed `Cargo.lock`, stable rustc, no SBF
  platform-tools) compiles a real Anchor program and drives it through the real
  `solana-runtime` SVM. The corpus (`sealevel/`) holds three lessons modernized verbatim
  to anchor 0.31 — signer-authorization (`MissingSignerCheck`), account-data-matching
  (`AccountDataMatching`), owner-checks (`MissingOwnerCheck`) — each with insecure + secure
  variants and a verified two-sided exploit PoC. The colony routes to the Anchor harness
  via `SOLANA_ANCHOR_HARNESS_DIR` (a `harness_dir()` helper + anchor branches in
  `poc_instruction` / `compile_run`); detection and the two-sided `assess()` gate are
  unchanged. `calibrate-sealevel.sh` runs the full detect → validate pipeline over the
  corpus and writes `sealevel-scorecard.md`. Demonstrated: the auditor runs end-to-end on a
  real lesson **fully offline inside the hardened sandbox** (host-side only the LLM call;
  the LLM-generated PoC compiles + runs offline through real `solana-program-test`, with a
  human-gated report), with ≥3 true-positive VERIFIED on the insecure lessons and **zero
  false-VERIFIED** on the secure variants — holding even when detection over-flags a secure
  variant, because the two-sided gate (the secure program rejects the exploit) is the source
  of truth, not the detector.

- Program-specific invariant library (V5): each detected vulnerability class now
  drives synthesis through a class-specific invariant (`invariant_for(class)`)
  instead of a single hardcoded signer-drain story. The PoC-generation prompt
  (`poc_instruction(class)`) embeds the right control/exploit invariant per class —
  ownership substitution for `MissingOwnerCheck`, identity mismatch for
  `AccountDataMatching`, program-id redirection for `ArbitraryCPI`, arithmetic wrap
  for `IntegerOverflow`, non-signer authority for `MissingSignerCheck` — and the
  standardized report's severity / summary / impact / remediation are class-aware
  (`severity_for` / `summary_for` / `impact_for` / `remediation_for`). Detection now
  routes every recognised class to synthesis (previously only `MissingSignerCheck`
  was synthesized and `IntegerOverflow` stopped at a "DETECTED" stub). The built-in
  deterministic template is signer-shaped, so a non-`MissingSignerCheck` class with
  no usable LLM-generated PoC resolves to `inconclusive` — never a false-VERIFIED.
  The two-sided gate (`CONTROL OK:` + `INVARIANT VIOLATED:`) is unchanged and still
  blocks rigged/always-fire harnesses for every class.

### Changed

- Detection verdict for `IntegerOverflow` in offline / `mock` mode is now
  `inconclusive` (routed through synthesis with the overflow invariant) rather than
  the previous non-committal `DETECTED`, since no deterministic overflow template
  exists; a real LLM backend generates the two-sided overflow PoC.

- Generalised detection (V3): an LLM-driven classifier (`classify_llm`) reads the
  program source and returns a vulnerability class (`MissingSignerCheck` /
  `MissingOwnerCheck` / `AccountDataMatching` / `ArbitraryCPI` / `IntegerOverflow`
  / `Safe`), generalising past the structural heuristic to real Anchor shapes it
  cannot see (e.g. an `authority: AccountInfo` field that should be a `Signer`).
  It is primary when a real LLM backend is configured; the structural heuristic
  remains the offline / `mock`-deterministic fallback (the mock backend yields no
  class token, so detection falls through unchanged). A mis-classification only
  routes to synthesis — the two-sided real-SVM gate stays the source of truth, so
  it can never cause a false-VERIFIED.

## [0.1.0] — 2026-06-09

**Requires:** agentis >= `1.18.0`

### Added

- Initial dark-factory federation: an autonomous Solana/Anchor bounty
  auditor. A single `auditor` colony runs an `agentis go`-driven audit
  pipeline (reconn → guard → tracker → synthesis) entirely on the agentis
  substrate, fully offline.
- Real LLM-driven two-sided PoC synthesis: the prompt-driven synthesis path
  generates a proof-of-concept that must exercise BOTH a control (an
  authorized caller is accepted → `CONTROL OK:`) and an exploit (an
  unauthorized caller breaks the safety invariant → `INVARIANT VIOLATED:`),
  so a rigged always-fire harness cannot pass the validation gate.
- Offline `solana-program-test` toolchain: a committed harness crate
  (`solana-harness/`) drives the ingested program through the real
  `solana-runtime` SVM (real account model, signer/owner checks, lamport
  conservation) compiled with stable rustc — no SBF platform-tools, no
  network at audit time. The one-time dependency-graph warm build is staged
  by `setup-solana-toolchain.sh`.
- Human-gated submission: a verified finding is written as a standardized
  Immunefi-shaped report and, at `review-gated` / `autonomous` tier, staged
  with a `pending_human_review` marker. The colony NEVER auto-posts to a
  bounty platform — submission is always an explicit human action.

[Unreleased]: https://github.com/Replikanti/agentis-colonies/compare/dark-factory-v0.1.0...HEAD
[0.1.0]: https://github.com/Replikanti/agentis-colonies/releases/tag/dark-factory-v0.1.0
