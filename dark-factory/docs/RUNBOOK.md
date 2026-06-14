# Operator runbook — Dark Factory auditor

A one-page guide to running the auditor against a real in-scope Solana/Anchor program,
reading the verdict, and submitting a finding. The colony does **detection + synthesis +
two-sided validation** of an access-control exploit and writes a human-gated submission
package; it **never** posts to a bounty platform.

## 1. Prerequisites (one-time)

- **Rust (stable)** + the `agentis` binary on `PATH`.
- **LLM backend** for detection + PoC synthesis: the `claude` CLI on `PATH` (works with
  `ANTHROPIC_API_KEY` unset), or any backend `agentis` supports. Use `--backend mock` for an
  offline-deterministic dry run (structural heuristic only; no real LLM).
- **Warm the offline Solana toolchain** for the harness you'll use (fetches the crate graph
  + warms `target/`, host-side, network on, ~once):
  - Native programs: `bash setup-solana-toolchain.sh`.
  - Anchor programs: `cd solana-harness-anchor && cargo fetch && cargo build --offline --bin poc`.
  After warming, every audit run compiles **offline** inside the hardened sandbox.

## 2. Point at a scope

The **operator** chooses the in-scope program (this tool never auto-picks a scope):

- `--target <program.rs>` — the in-scope program source.
- `--anchor-harness <dir>` — for **Anchor** programs (e.g. `solana-harness-anchor`).
- `--harness <dir>` — for **native** `solana-program` processors (e.g. `solana-harness`).
- `--snapshot <file>` — optional frozen on-chain state to replay against. Produce one with:
  `./snapshot-rpc.sh --rpc <RPC_URL> --out snap.txt <ACCOUNT_PUBKEY> [...]`
  (host-side; for a live target the operator dumps that program's own accounts).
- `--backend flat-cyborg|claude|mock` — flat-rate PTY wrapper driving claude (default), metered claude `-p` API, or offline-deterministic mock.

## 3. Run

```
./run-audit.sh --target <program.rs> --anchor-harness ./solana-harness-anchor \
               --out audit-out
```

The run is sandboxed with the hardened profile by default (`--unshare-all`, network closed;
only the host-side LLM call reaches out). The compile + the PoC execution happen **offline**
through the real `solana-program-test` SVM.

## 4. Read the verdict

- **VERIFIED** — a two-sided PoC ran through the real SVM: the legitimate caller is accepted
  (`CONTROL OK:`) **and** an unauthorized caller breaks the safety invariant
  (`INVARIANT VIOLATED:`). This is a real, reproducible finding.
- **INCONCLUSIVE** — no confirmed exploit (the program rejected the exploit, or no usable PoC
  was produced). A secure program lands here. Never treated as a finding.
- **SAFE** — detection found no in-scope vulnerability; no synthesis attempted.

A false-VERIFIED on a secure target is impossible from the autonomous path: the two-sided
gate is the source of truth, so even if detection over-flags, a secure program rejecting the
exploit yields INCONCLUSIVE.

## 5. Where the report + PoC land

On **VERIFIED**, `run-audit.sh` stages `audit-out/submission/`:
- `report.md` — Immunefi-format finding (severity, affected function, summary, impact,
  remediation), embedding the standalone PoC.
- `poc.rs` — the two-sided PoC source.
- `target.rs` — the audited program.
- `snapshot.txt` — the frozen on-chain account snapshot (if `--snapshot` was used).
- `MANIFEST.txt` — marked **PENDING HUMAN REVIEW — NOT SUBMITTED**.

## 6. Submit (manual, human-gated)

The colony **never** contacts a platform. A human reviews `audit-out/submission/report.md`,
confirms the finding, and submits it manually to Immunefi / Code4rena / Sherlock. This is
deliberate: autonomous posting risks anti-bot bans and duplicate-submission penalties.

## EVM custom-code discovery (`run-discovery.sh`)

The flow above is the DAG fork-**matcher**: it only fires where in-scope code recurs a seeded pattern,
so on a bespoke, never-forked protocol it finds nothing. For **custom** contest code (a fresh
stablecoin, a new vault), use the discovery track — `run-discovery.sh` fans the substrate discovery
agent (`auditor/agents/hunter.ag`) out over (subsystem × bug-class).

1. **Clone the target** (`fetch-target.sh`, or any git clone). Note the repo root (the dir holding
   `contracts/` or `src/`).
2. **Write a scope manifest** — one subsystem per line, `subsystem | classid,… | file,…` (files
   relative to the repo root); `#` comments allowed. Pick classes per subsystem from
   `auditor/bug-taxonomy.md`. A file may be written `file@fn1+fn2` to feed **only those functions**
   (plus the contract header) instead of the whole file — use it for big/complex contracts (a 1000+
   line CDP, money-market, or credit vault) whose whole-file read would overflow the LLM budget and
   time out on a deep liquidation/redemption cell. Example:
   ```
   rewards + savings  | C1,C6,C11 | contracts/SavingsVault.sol,contracts/RewardsDistributor.sol
   oracle             | C2,C9,C10 | contracts/PriceOracle.sol,contracts/LendingAdapter.sol
   vault liquidation  | C10       | contracts/Vault.sol@liquidate+seize+_redeem
   ```
3. **Write a brief** — the protocol's invariants whose violation is a valid finding, the **known
   issues to exclude** (from prior audits — the hunter must not re-report them), and the trust model
   (which roles are in/out of scope). This is what stops the hunt from surfacing already-audited noise.
4. **Run** (each cell is a deep adversarial LLM read — ~3 min typical, up to ~8 min for a deep
   liquidation/redemption cell, within the 600s per-call budget; a full sweep is serial):
   ```
   ./run-discovery.sh --repo <repo> --scope scope.tsv --brief brief.md --out discovery-out
   # cheap wiring smoke first (no real LLM):  --backend mock --only "<subsystem>" --classes C1
   ```
5. **Read the leads** — `discovery-out/discovery-report.md`. Each `CANDIDATE` row is an **unverified
   lead** (file:fn:line / severity / exploit / PoC sketch). No candidate = **rigorous negative**, the
   valid outcome on audited code; nothing is submitted.
6. **Verify each lead** through the multi-contract Foundry gate — write the `Exploit.t.sol` the PoC
   sketch describes (deploy the protocol, run the attacker tx, assert the broken invariant), then:
   ```
   ./evm-harness/forge-verify.sh --repo <repo> --poc Exploit.t.sol --lz-symlink
   # exit 0 = VERIFIED (the PoC passed = exploit reproduced). A lead that does not reproduce is NOT a finding.
   ```
7. **Submit (manual, human-gated)** — only a forge-VERIFIED lead is worth submitting, and only a human
   submits it. As everywhere in this colony, nothing is auto-posted.

## Calibration

`sealevel-scorecard.md` records the auditor against real `coral-xyz/sealevel-attacks`
lessons: **3/3 true-positive VERIFIED** on the insecure variants, **0 false-VERIFIED** on the
secure variants. Regenerate with `./calibrate-sealevel.sh`.

## Known limitations

- **Vulnerability classes:** MissingSignerCheck, MissingOwnerCheck, AccountDataMatching,
  ArbitraryCPI, IntegerOverflow (access-control + arithmetic). Other classes route to a
  generic invariant or `SAFE`.
- **Chains / shapes:** Solana — native `solana-program` processors and Anchor programs.
  Verbatim pre-2.x Anchor (e.g. anchor 0.20) must be modernized to compile against the
  solana 2.x harness (same vuln + structure); detection runs on the source either way.
- **Snapshot replay** supplies a frozen account's real `lamports` + data; the account owner
  is rebound to the in-scope program for replay (the harness program is not deployed
  on-chain). For a live target the operator dumps that program's own accounts.
- **Operator-supplied PoC (`BOUNTY_POC`/`--poc`)** is trusted: a hand-supplied PoC that
  prints the markers without exercising the target will pass the gate. The autonomous and
  template paths always run the real two-sided harness; only the explicit human override
  bypasses it. (Hardening the control side to demonstrably exercise the target is tracked as
  a follow-up.)
