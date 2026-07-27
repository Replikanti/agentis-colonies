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
- `report.md` — Immunefi-format finding (severity + **impact category** + **severity rationale**
  mapped to the Immunefi bands, affected function, summary, an **Impact quantification** section
  stating the funds-at-risk the two-sided PoC demonstrated, plus remediation), embedding the
  standalone PoC (#1456).
- `poc.rs` — the two-sided PoC source.
- `target.rs` — the audited program.
- `snapshot.txt` — the frozen on-chain account snapshot (if `--snapshot` was used).
- `REPRODUCTION.md` — the reproduction manifest: target sha256, harness kind, toolchain versions
  (`rustc`/`cargo`/`agentis`), backend/sandbox, and a deterministic **rerun command**. On a
  snapshot-based run it discloses the account-owner rebind so you can re-verify against real
  program-derived ownership on mainnet before submitting (#1457).
- `MANIFEST.txt` — marked **PENDING HUMAN REVIEW — NOT SUBMITTED**.

Triage a pile of staged packages into a review queue with `submit-triage.sh` (never posts):

```
./submit-triage.sh --root audit-out --known-issues known.txt   # scan (IMPACT + NOVELTY columns)
./submit-triage.sh --checklist audit-out/submission            # per-candidate human checklist
```

The scan scores each candidate `READY` / `INCOMPLETE` / `DUP-RISK`, an **IMPACT** column
(`quant` = funds-at-risk stated, `qual?` = quantify before submitting), and — when you pass a
`--known-issues` list of public disclosures (one signature per line) — a **NOVELTY** column that
flags a finding whose affected function or report body collides with a known issue as `DUP-RISK`
(Immunefi pays only the FIRST reporter; private queues are invisible, so this raises confidence, it
does not guarantee primacy).

## 6. Submit (manual, human-gated)

The colony **never** contacts a platform. A human reviews `audit-out/submission/report.md`,
reproduces it with `REPRODUCTION.md`, confirms the finding is in-scope, novel, and impact-credible
(the `submit-triage.sh` checklist walks these), and submits it manually to Immunefi / Code4rena /
Sherlock. This is deliberate: autonomous posting risks anti-bot bans and duplicate-submission
penalties.

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

## Severity-first deep-hunt (`run-zone-hunt.sh --deep-hunt`, #1713)

The breadth pass (`run-discovery.sh` → `hunter.ag`) reads each (subsystem × bug-class) cell once, deeply,
but a **money-tier** bug on a high-value zone is often a *stateful* one — it only emerges from a multi-step
call sequence a single-function read cannot see (first-depositor inflation, a donate-then-deposit share
spike, a liquidate/seize/redeem accounting break). `--deep-hunt` adds a **second, severity-first lens** that
runs the shipped stateful-invariant engine (`run-invariant-hunt.sh`) on exactly the zones that hold user
funds, and folds any fuzzer-reproduced FINDING back into the same verified-findings stream.

- **Value-custody gate.** `zone-mapper.ag` flags a zone `value_custody: true` in `zones.json` when it OWNS
  value-moving accounting (`contains_accounting_signal`, the #1698 C6 net) or is a lending/CDP/stability-pool
  system (`contains_lending_signal`, the #1681 C10/C11 net) — pure reuse of the shipped nets, no new
  detection logic. **#1717:** interface-only and test zones are excluded up front (a path-level guard,
  ahead of the content nets) — an interface has no implementation to stateful-fuzz (a guaranteed
  HARNESS_ERROR) and a test file is not the custody logic under audit. `map-zones.sh` scrapes the flag
  off the agent's `CUSTODY|<id>|<true|false>` line
  (additive to `zones.json` only — `scope.tsv`'s schema is untouched).
- **The stage.** With `--deep-hunt`, a new stage runs BETWEEN verify (M4) and deliver (M5), active only when
  the target is a Foundry project (`foundry.toml` present — EVM invariant-fuzzing is Foundry-specific; a
  non-Foundry target is logged and skipped). For each value-custody zone it picks ONE primary target (the
  largest `.sol` in the zone, `--deep-hunt-max-targets` default 1) and runs `run-invariant-hunt.sh`
  (`--deep-hunt-repair-rounds` compile-repair attempts, default 4 — #1717, deeper than the prover's own
  default of 2 so a real custody contract's harness reliably compiles instead of degrading to
  HARNESS_ERROR on the first non-compiling draft). Each
  FINDING is merged into `verify/verified_findings.json` as a `source=invariant-hunt` entry with a
  bench-parseable `location = <file>:<function>`, so M5 halts it at the same human gate and corpus-bench
  scores it alongside the breadth findings.
- **Default OFF.** Without `--deep-hunt` every run is byte-identical to before (no new stage, no new egress —
  `run-invariant-hunt.sh` never submits and the merge is a local file read/write).

```
# breadth + severity-first depth, offline-deterministic (fixture-driven, no LLM/forge):
./run-zone-hunt.sh --repo <repo> --out zone-hunt-out --deep-hunt \
    --invariant-fixture <handler.t.sol> --map-fixture <zones.txt> --brief-fixture <briefs.txt> \
    --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --backend mock --agentis <stub>

# live (real backend + forge): omit the fixtures; --deep-hunt gates on the mapped value_custody zones.
./run-zone-hunt.sh --repo <repo> --out zone-hunt-out --deep-hunt --backend flat-cyborg
```

**Measuring it is a bench PROXY, not a jackpot claim.** `bench/corpus-bench/deep-hunt-ab.sh` runs the
pipeline ON vs OFF over the same target and reports the **High-severity recall delta** the deep lens buys.
`--self-test` (CI-safe, offline) proves the mechanism end to end: deep-hunt ON adds a `source=invariant-hunt`
High finding that `score-match.py` scores a HIT and the breadth pass missed. `--live --id <id> --code-dir
<dir> --truth <truth.tsv>` measures a real contest — but on a **SCRATCH COPY** in an isolated `--work` dir,
restricted to a single value-custody zone via `--scope-hint`, and only AFTER any live corpus-bench run frees
CPU/subscription capacity (it owns a claude subscription slot). This is a capability-frontier attempt
measured by a proxy — the real test is fresh live targets the bench cannot measure.

## Zone coverage: did this run actually hunt everything? (`coverage/zone-coverage.json`, #1830)

Every `run-zone-hunt.sh` run writes `<out>/coverage/zone-coverage.json` — **always**, with no flag, and
**before** the first zone is hunted, with every zone in `zones.json` present as `not_reached`. Read it before
you trust a result set: a run that was cut short (an external kill, a failing zone, an exhausted budget) is
otherwise indistinguishable from a run that genuinely found less.

```bash
python3 -c 'import json;d=json.load(open("zone-hunt-out/coverage/zone-coverage.json"));\
print(d["complete"], d["gap_zones"]); print(d["totals"]["by_status"])'
```

- `complete: true`, `gap_zones: []` → a clean sweep; the merged findings are the whole picture.
- `complete: false` → STAGE 3 also printed a `COVERAGE GAP:` banner to stderr, and
  `discovery-results.merged.json` carries the same verdict under its `coverage` key.

Per-zone `status` tells you what to do next:

| `status` | what it means | what to do |
|---|---|---|
| `hunted` / `hunted_empty` | complete coverage of the classes hunted (`hunted_empty` = a rigorous negative) | nothing — unless `budget_truncated: true`, which means the class list was shortened and the negative is not rigorous |
| `hunted_degraded` | a cell produced no verdict after retries (#1707) | re-hunt with `--rehunt-gaps --rehunt-include-partial` |
| `budget_exhausted` | the run declined to pay for it — **not** a negative | raise the budget, or `--rehunt-gaps` |
| `failed` | `run-discovery.sh` exited non-zero (see `exit_code`, `detail`) | `--rehunt-gaps`; a second failure is a defect to escalate |
| `in_flight` | the process died mid-zone (external kill / OOM) | `--rehunt-gaps` |
| `not_reached` | never attempted — zero evidence | `--rehunt-gaps` |
| `no_brief` | STAGE 2 produced no brief — an upstream defect | re-run the FULL pass; `--rehunt-gaps` deliberately never selects it |

### Bounding a run and closing the gap

```bash
# bound it: cells are the unit (the number of hunter calls). Both default 0 = OFF = unbounded.
./run-zone-hunt.sh --repo <repo> --out zone-hunt-out --run-cell-budget 40 --zone-cell-budget 8

# refuse to publish a degraded run: exit 4 BEFORE verify/deliver when coverage is under 80 %.
./run-zone-hunt.sh --repo <repo> --out zone-hunt-out --run-cell-budget 40 --require-coverage 80

# close the gap later: STAGE 1/2 are skipped, ONLY the gap zones are re-entered, and the merge is the UNION.
./run-zone-hunt.sh --repo <repo> --out zone-hunt-out --rehunt-gaps
```

A cell budget bounds the number of hunter substrate calls and **nothing else** — not wall-clock, not tokens,
not memory. It is a coverage-shaping knob, not a cost cap. It never reorders anything: the cut always falls on
the tail of the #1826 value-custody-first order, and the first denial stops the loop.

Two things to know before you re-hunt:

- **A re-hunt re-runs STAGE 4 over the union**, which **overwrites** `verify/verified_findings.json` — and
  that discards any `source=invariant-hunt` findings a prior `--deep-hunt` merged into it. Re-apply the lens
  afterwards with `--deep-hunt --deep-hunt-only` (that path exists for exactly this). The two reuse modes
  cannot be combined in one invocation (`--rehunt-gaps` + `--deep-hunt-only` is exit 2).
- **A re-hunt re-runs STAGE 5 over already-delivered findings.** `deliver-submission.sh` stages into
  `<drop>/<repo>@<commit>:<slug>/`, so a repeat rewrites that finding's own dir rather than accumulating
  duplicates — but on a live run it does pay for the audit pass again.

A re-entered `failed`/`in_flight` zone's prior artifacts are moved to `discovery/<zid>.attempt-<n>` (and the
prior state pushed into the record's `attempts[]`) before the new attempt, so the failure evidence survives.
One `--rehunt-gaps` pass is exactly one pass over the gap set; `--rehunt-max-attempts` (default 2) stops a zone
from being retried forever.

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
  on-chain). For a live target the operator dumps that program's own accounts. Since #1457 the
  snapshot-replay harness **reads the account's real on-chain owner from the dump** and emits an
  explicit, machine-checkable `OWNER REBIND: <real owner> rebound to <program>` line (surfaced in
  `report.md` + the submission package's `REPRODUCTION.md`), so the rebind is disclosed up-front
  instead of a silent mismatch — the human re-verifies against real program-derived ownership on
  the live deployment before submitting. For a **load-at-real-address** run, pass
  `--expect-owner <base58>` (the program's real owner): the harness **hard-asserts** owner-match
  and **refuses a mismatch as `INCONCLUSIVE` (exit 3), before the exploit runs**, so a re-owned
  copy is never reported VERIFIED.
- **Operator-supplied PoC (`BOUNTY_POC`/`--poc`)** is gated, not blindly trusted (#852): a
  supplied PoC must (1) **structurally reference** the in-scope target/harness and (2) pass a
  **per-run target-linkage challenge** — a nonce const appended to this run's target that the
  wrapped PoC must echo back, so a target-agnostic marker-printer that merely prints
  `CONTROL OK:` / `INVARIANT VIOLATED:` is **REJECTED (INCONCLUSIVE)**, never VERIFIED. Only
  then does the two-sided `assess()` decide. Residual: a sophisticated *link-but-never-invoke*
  PoC (one that compiles against the target but captures stdout instead of exercising it) is
  indistinguishable from captured output and remains an operator-trust item — the autonomous
  LLM/template paths are unaffected (they always run the real two-sided harness).
