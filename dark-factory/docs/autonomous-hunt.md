# Autonomous stateful-invariant hunt — Integration M1 + M2 + M3 (#1037)

Two pieces shipped separately: the **self-orchestrating coordinator** ([`docs/coordinator.md`](./coordinator.md),
#1014) that DECIDES the next audit action from facts + an evolving policy, and the **stateful-invariant
fuzzer** ([`docs/invariant-hunt.md`](./invariant-hunt.md), #1035) that finds the multi-step bug. Until now an
operator had to call the fuzzer directly (`run-invariant-hunt.sh`). Integration M1 wires them together: the
operator hands the coordinator a target, and the **coordinator itself CHOOSES** to route it through the
fuzzer and LIVE-runs it — finding the bug end-to-end.

This mirrors EXACTLY how the symbolic engine got a live coordinator route: `symbolic-prove` was added as a
VERIFY-tier action (#1015 M3) and given a live route (#1032, [`demo-symbolic-orchestrate-live.sh`](../demo-symbolic-orchestrate-live.sh)).
`invariant-hunt` is its sibling — same tier, same live-route shape, same sound-verdict contract.

## The two sources of truth (never confused)

```
target ──(coordinator's evolving POLICY)──► CHOOSE invariant-hunt ──(forge-invariant.sh)──► FINDING/CLEAN verdict
            the CHOICE of engine                                          the VERDICT (forge's shrunk witness)
```

- **The CHOICE of engine is the coordinator's evolving policy** — a policy-weighted argmax over fact-criteria,
  never a fixed sequence and never an LLM judgement of the verdict. `invariant-hunt` sits in the VERIFY tier
  (a pending candidate is verified before more hunting). Its base score is **94**, below `refute`(100),
  `poc-screen`(98), and `symbolic-prove`(96) — routing a candidate through the STATEFUL fuzzer is the most
  expensive verify (a multi-call search, not a single-input proof), so by default the cheaper verifies go
  first. Its policy term is the steep ×4 multiplier (the same the symbolic tier uses), so the colony can
  **learn** to lift it above the others as the fuzzer's witnesses pay off:
  `94 + 4 × policy` beats `refute`(100) at policy > 1.5 (at exactly 1.5 the score ties 100 and the tie resolves to the higher-base `refute`).
- **The FINDING/CLEAN VERDICT is the fuzzer's**, the exit code of [`evm-harness/forge-invariant.sh`](../evm-harness/forge-invariant.sh),
  NEVER the LLM. The gate's exit code maps to the coordinator's gate-outcome enum exactly as the symbolic
  route does:

  | gate exit | gate verdict | coordinator outcome | meaning |
  |---|---|---|---|
  | `1` | FINDING | **confirmed** | an invariant broke under a concrete shrunk call-SEQUENCE — a real multi-step bug with a reproducible witness |
  | `0` | CLEAN | **refuted** | every invariant held across the fuzzed search — the lead is killed in this budget (not a proof of safety) |
  | `2` / else | HARNESS_ERROR | **dry** | the test did not compile / no invariant matched / forge absent — no verdict (the safe failure mode) |

  The mapping is IDENTICAL to the symbolic one (1→confirmed, 0→refuted, 2/else→dry), so `coordinator.ag`
  reuses `sym_rc_of`/`sym_outcome_of` to read the `__rc=$?` marker and map it.

## End-to-end flow

`run-autonomous-hunt.sh` drives ONE `agentis go coordinator.ag` in ORCHESTRATE mode:

1. **seed a candidate** — the target is seeded as a pending candidate (`cand-0`), the same shape the
   orchestrate loop's VERIFY tier expects.
2. **seed the policy** — `INV_POLICY_TT=20000` (= +2.0) seeds the loop's initial `invariant-hunt` policy so
   the coordinator chooses it from step 0. This stands in for the policy a PRIOR run would have evolved (the
   fuzzer's witnesses having paid off and the colony having learned to lean on the stateful engine), exactly
   as `--sym-policy` / `SYM_POLICY_TT` seeds `symbolic-prove`. agentis offers no float→int builtin, so the
   ten-thousandths integer is supplied directly.
3. **the coordinator DECIDES** — by its policy-weighted argmax, it emits
   `ACTION|invariant-hunt|cand-0|...` (the rationale cites the policy weight + the facts).
4. **the LIVE route runs the REAL fuzzer** — with `DISPATCH_FIXTURE` empty and the live env present
   (`FORGE_INVARIANT` gate + `INV_REPO` foundry dir + `INV_TARGET` invariant test), `coordinator.ag`'s
   `action_outcome` runs `forge-invariant.sh --repo … --target … --match … [--runs/--depth/--seed]` and maps
   its exit code (table above). It prints a `LIVE invariant-hunt … running the REAL stateful fuzzer …` line so
   the live route is observable. This branch is **purely additive** — absent any of the three env facts it
   falls through to the honest stub, so behaviour with no live env is byte-identical.
5. **the verdict crosses back** — `dispatch()` writes `coordinator:last_outcome` and prints
   `DISPATCH|invariant-hunt|cand-0|<verdict>`. The candidate is consumed from `PENDING`.
6. **the outcome evolves the policy** — the NEXT step's `decide_once()` attributes the previous
   `invariant-hunt`'s gate outcome with the same `learn()` mechanic the lens-fitness loop uses (confirmed →
   success / refuted → failure), so `coordinator:policy:invariant-hunt` reweights. The evolved policy lands in
   `coordinator:policy_after`.

## The human-gated submit boundary

A `FINDING` (→ confirmed) is a **CANDIDATE the fuzzer reproduced** — a LEAD a human triages, with the shrunk
exploit call-sequence as a reproducible witness. It is **never** auto-submitted. As everywhere in this colony,
submission to Immunefi / Code4rena / Sherlock is a separate, explicit human action; the coordinator decides
*which engine to spend*, the fuzzer decides *whether the bug reproduces*, and a human decides *whether to
submit*. This colony never posts to a bounty platform.

## Run it

```bash
# the integration: hand the coordinator a target; it CHOOSES + LIVE-runs the fuzzer
dark-factory/run-autonomous-hunt.sh --repo "$PWD/target" --target test/Invariant.t.sol --seed 1

# offline-deterministic proof (real fuzzer, the inflation-vault + hardened twin; SKIPs without forge/agentis)
dark-factory/demo-autonomous-hunt.sh
```

`demo-autonomous-hunt.sh` reuses the inflation-vault + hardened-twin scaffolding from
[`demo-invariant-hunt.sh`](../demo-invariant-hunt.sh): for the VULNERABLE vault the coordinator's chosen
`invariant-hunt` returns `DISPATCH|invariant-hunt|cand-0|confirmed` (the inflation attack — a real multi-step
bug), for the HARDENED twin `…|refuted` (no false positive). It asserts (A) the coordinator AUTONOMOUSLY chose
the engine, (B) the LIVE fuzzer's verdict crossed back, and (C) the outcome evolved the policy.

## Per-candidate context carrying (M2)

M1's live route reads the target from a SINGLE flat env (`INV_REPO`/`INV_TARGET`/`INV_MATCH`), so every
candidate the loop verifies hits the same operator-supplied target. **Integration M2** makes each pending lead
carry its **own** repo/target context, so when the loop verifies several candidates each `invariant-hunt`
(and `symbolic-prove`) runs on the **right** lead — closing the loop from discovery (many leads) to a sound
verdict on each *specific* lead.

### The `candidate:<id>:*` memo convention

A candidate id `cand-N` carries its context in `recall_latest`-readable memos (the durable cross-process
channel, dynamic-key) — NOT in env. The keys:

| memo key | env fallback | role |
|---|---|---|
| `candidate:<id>:repo` | `INV_REPO` | foundry project root the fuzzer runs in |
| `candidate:<id>:target` | `INV_TARGET` | the invariant `*.t.sol` the fuzzer scopes to |
| `candidate:<id>:match` | `INV_MATCH` | invariant function-name prefix (default `invariant`) |
| `candidate:<id>:sym_repo` | `SYM_REPO` | foundry project root Halmos runs in |
| `candidate:<id>:sym_spec` | `SYM_SPEC` | the symbolic spec target Halmos scopes to |
| `candidate:<id>:sym_function` | `SYM_FUNCTION` | symbolic check-function prefix (default `check`) |

Run-level forge budgets (`INV_RUNS`/`INV_DEPTH`/`INV_SEED`) stay env-only — they are knobs of the *run*, not
of a *candidate*.

### Per-candidate-first, env-fallback

`coordinator.ag`'s live routes (`run_invariant_live(candId)` / `run_symbolic_live(candId)`) resolve each fact
**per-candidate-first**: read `candidate:<id>:<field>`; if that memo is non-empty use it, else fall back to the
flat env. The live-route GATE keys on the **resolved** repo+target (per-candidate OR env), so a candidate
carrying ONLY its own memo (flat env empty) still routes live; with **neither** it falls through to the honest
stub. An empty per-candidate memo ⇒ the M1 env path ⇒ **byte-identical M1 behaviour** — M2 is purely additive.

### Driving it — `--candidate`

`run-autonomous-hunt.sh` takes a repeatable `--candidate '<id>|<repo>|<target>[|<match>]'`. For each candidate
it `agentis memo set candidate:<id>:repo/target/match` into the shared store (after `agentis init`, before
`agentis go`) and appends one `<id>|…` cell to `PENDING`. The single `--repo/--target` stays as the
one-candidate `cand-0` shorthand (full M1 back-compat). With candidates supplied, `BUDGET`/`STEPS` auto-scale
to `>= 2 × candidate-count` so every candidate is both routed (one step) and attributed (the next).

```bash
# multi-candidate: each lead carries its OWN target via its candidate:<id>:* memo
dark-factory/run-autonomous-hunt.sh \
  --candidate "cand-0|$PWD/A|test/Inv.t.sol" \
  --candidate "cand-1|$PWD/B|test/Inv.t.sol" --seed 1

# the rigorous proof: TWO candidates, flat INV_REPO/INV_TARGET EMPTY -> a SPLIT verdict
# (cand-0|confirmed on the vulnerable vault, cand-1|refuted on the hardened twin) that a shared env
# could not produce. SKIPs without forge/agentis.
dark-factory/demo-candidate-carry.sh
```

### The discovery producer

`run-discovery.sh` / `hunter.ag` (the discovery side) can populate these `candidate:<id>:*` memos as it
emits leads, so a discovered lead carries its contract + invariant test straight through `PENDING` to the live
verify — no operator re-typing the target per candidate. The memo convention is the contract between the
producer (discovery) and the consumer (the coordinator's live verify routes).

## Pattern memory (M3)

M1 made the coordinator live-drive the fuzzer; M2 let each lead carry its own context. **Integration M3**
closes the loop the user described — *the federation invents its own attack methods, stores them in a DAG, and
self-drives*: a winning invariant pattern (one that produced a FINDING) is **persisted to the pattern DAG** and
**recalled to seed future hunts**, and `invent-method` can propose a new invariant class the next hunt then
uses. It **reuses the existing `bugpat:*` DAG infrastructure** — the same `dag_put` / `recall_latest` /
`memo_write` primitives the fork-matcher seed/recall agents use (`seed-patterns.ag` / `recall-match.ag`) and
the same `knowledge_sell` cross-pollination channel (`share-patterns.ag`) — in a parallel `invpat:*` namespace.
No new store is built.

### The `invpat:*` namespace

| memo key | written by | read by | role |
|---|---|---|---|
| `invpat:exact:<hash>` | `invariant-prover.ag` on a FINDING | (the DAG index, mirrors `bugpat:exact:<hash>`) | `dag_put(<signature>)` → the content-hash key class membership |
| `invpat:latest:<class>` | `invariant-prover.ag` on a FINDING | `invariant-prover.ag` before GENERATE | the latest winning invariant pattern descriptor for a bug class |
| `invpat:invented:<class>` | `run-autonomous-hunt.sh --method-fixture` | `invariant-prover.ag` before GENERATE | a NEW invariant class proposed by `invent-method` (a generation hint) |

The signature persisted is a **deterministic, stable descriptor**: `<class>::<target-label>::<match-prefix>`
— the same class/shape produces the same `invpat:exact:<hash>` across runs, so a later FINDING on the same
class recalls it. `dag_put`'s content hash is the sha256 of the signature, so only the memo *values* travel
between stores — re-`dag_put`ting the same signature reproduces the same key locally.

### Persist-on-FINDING / recall-before-generate

`invariant-prover.ag` (the GENERATE-and-VERIFY agent) gains two additive hooks:

- **RECALL before GENERATE.** Before writing the test, it reads `recall_latest("invpat:latest:<class>")`
  (falling back to `invpat:invented:<class>` — the invent-method hint — when no FINDING pattern exists yet).
  When non-empty it prints `RECALL-INVPAT|<class>|<descriptor>` (so the transfer is observable) and folds the
  descriptor into the LLM generation seed ("a prior FINDING on this class used this invariant pattern: …;
  adapt it"). On the `HANDLER_FIXTURE` path the fixture is authoritative (recall does **not** change it) but
  the `RECALL-INVPAT|` line is still printed so the loop is observable. **Recall steers GENERATION only — it
  never changes the verdict** (which stays the fuzzer's exit code).
- **PERSIST on FINDING.** *After* the verdict is printed (so a persist failure can never alter the verdict),
  and only when `verdict == "FINDING"`, it computes the signature, `dag_put`s it, writes
  `invpat:exact:<hash>` + `invpat:latest:<class>`, emits `dark-factory:invariant_pattern_learned`, and prints
  `INVPAT-LEARNED|<class>|<descriptor>`. **Persistence only records what the fuzzer already confirmed.**

`prior` / the signature are derived from prior agent state (treated as untrusted): they flow only into the
prompt (a plain string) and the plain-stdout `RECALL-INVPAT|` line — never into `exec sh`.

### Durable cross-run store — `--pattern-store`

`run-invariant-hunt.sh` and `run-autonomous-hunt.sh` gain `--pattern-store <dir>`: a **persistent** agentis
store reused across runs where the `invpat:*` memos are kept. The per-run store stays ephemeral; a small
bridge (via the `agentis memo` CLI) moves `invpat:*` **in** before the run (so RECALL sees a prior run's
confirmed shapes) and **out** after (so this run's FINDING is kept for the next).

- `run-invariant-hunt.sh` bridges directly around its prover run.
- `run-autonomous-hunt.sh` keeps the coordinator **byte-identical** by handing it a thin **prover-gate
  wrapper** as `FORGE_INVARIANT`: the wrapper speaks the gate's exact CLI + exit contract
  (`1=FINDING / 0=CLEAN / 2=error`), so the coordinator's `run_invariant_live` + `sym_rc_of` / `sym_outcome_of`
  mapping is unchanged, but internally it routes through `invariant-prover.ag` in the persistent store (so
  persist/recall happen and the prover's `RECALL-INVPAT|` / `INVPAT-LEARNED|` lines land in the run log).

**Absent `--pattern-store` the behaviour is byte-identical to M1/M2** — the per-run store is ephemeral, no
`invpat:*` is persisted, and the coordinator calls the bare gate directly (no wrapper).

### The `invent-method` feed — `--method-fixture`

`run-autonomous-hunt.sh --method-fixture <file>` consults a deterministic method-inventor proposal (a
`METHOD|<name>|<bug-classes>|<technique>|<how-to-invoke>|<control-assert>` line — the same shape
`method-inventor.ag` emits, used offline so the wiring is provable without an LLM). It parses the proposed bug
class and seeds it as `invpat:invented:<class>` in the pattern store, so the next `invariant-hunt`
generation's recall consults it as a hint. The live `method-inventor.ag` path stays prompt-driven; the
fixture proves the wiring deterministically. Validation of an invented method stays the two-sided control
gate `run-method-discovery.sh` already enforces.

```bash
# Run 1 persists a winning pattern; Run 2 on a same-class target recalls + reuses it (a shared store S):
dark-factory/run-autonomous-hunt.sh --repo "$PWD/A" --target test/Inv.t.sol --pattern-store "$PWD/S" --seed 1
dark-factory/run-autonomous-hunt.sh --repo "$PWD/B" --target test/Inv.t.sol --pattern-store "$PWD/S" --seed 1

# the invent-method feed: a proposed NEW class steers the next hunt's generation
dark-factory/run-autonomous-hunt.sh --repo "$PWD/C" --target test/Inv.t.sol \
  --pattern-store "$PWD/S" --method-fixture method.txt --seed 1

# the end-to-end proof (persist on A, recall+reuse on B, invent-method leg; SKIPs without forge/agentis):
dark-factory/demo-pattern-memory.sh
```

`demo-pattern-memory.sh` proves the MEMORY LOOP works (persist → recall → reuse across a structurally-different
same-class target, plus the invent-method feed). **Honest scope:** the claim is the memory loop works, **not**
that recall is strictly necessary for the fuzzer to find B — both vaults are vulnerable, so each FINDs on its
own; what the demo proves is that the discovered pattern is stored in the DAG and recalled to seed the later
hunt, observably.

## Honest scope

M2 carries each lead's repo/target context through the durable memo channel; M3 adds the cross-run pattern
memory + the invent-method feed. A long-lived daemon-tick reflex (the loop running continuously without a
shell bootstrap), auto-GENERATION of the per-candidate invariant test from a discovered lead (here the test is
supplied alongside the contract), recall as a *requirement* (rather than a *seed*) for the fuzzer, and the
coordinator pruning a live cell manifest all remain follow-up on epics #1014 / #1035 / #1037.
