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

### Fixed

- Real-repo compile robustness in `evm-harness/solc-resolve.js`: (1) handle caret/range pragmas
  (`^0.7.6`, `~0.8.4`, `>=0.7.0 <0.8.0`) by selecting the floor solc version when its minor differs
  from the local pinned build (real repos overwhelmingly use caret pragmas; an exact-pin-only match
  fell through to the local solc and failed with "requires different compiler version"); (2) resolve
  Foundry-default remappings written WITHOUT a trailing slash (`@openzeppelin/contracts=lib/…/contracts`)
  via `path.join` instead of `path.resolve` (the no-trailing-slash remainder starts with `/`, which
  `path.resolve` treated as absolute and discarded the project prefix → "import not found"). Surfaced
  by running the colony on a real OpenZeppelin-based Foundry target (compiles 0.7.6 + resolves OZ imports).

### Added

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
