# Autonomous stateful-invariant hunt — Integration M1 (#1037)

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
  `94 + 4 × policy` beats `refute`(100) at policy ≥ 1.5.
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

## Honest scope

This integration drives a SINGLE operator-supplied candidate through the live route — the minimum live slice,
exactly the boundary `symbolic-prove`'s live route (#1032) set. Multi-candidate code-carrying (a discovered
lead auto-carrying its contract + invariant test through `PENDING`), a long-lived daemon-tick reflex (the loop
running continuously without a shell bootstrap), and the coordinator pruning a live cell manifest all remain
follow-up on epics #1014 / #1035 / #1037.
