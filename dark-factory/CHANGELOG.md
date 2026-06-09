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
