# Substrate dispatch (#1014 M2 — all action types)

The self-orchestrating coordinator (see [`coordinator.md`](./coordinator.md)) moved the **decision** into the
substrate: each step `coordinator.ag` reads FACTS + an evolving policy and chooses one action. But a thin
shell loop (`run-coordinator.sh`) still **dispatched** that action — it ran a shell `case`
(`stub_outcome` / `real_outcome`) to derive each action's gate verdict, then fed it back. M1 moved the
`hunt` slice onto the substrate.

**M2 moves the dispatch onto the substrate for EVERY action type.** The decision *and* its dispatch now
happen in **one** `agentis go` for any real action (`hunt` / `refute` / `poc-screen` / `invent-method`):
the coordinator decides the action, emits it over the in-process bus, a sibling agent fn derives the gate
verdict and writes it to a durable memo, and the shell loop **reads the verdict from the memo** instead of
computing it in a `case`. **The shell computes no action's outcome.** Only `stop` is never dispatched — it
is terminal and ends the loop.

## The two substrate channels (and why each)

agentis exposes exactly two relevant primitives, with different scopes:

| Channel | Scope | Used for |
|---------|-------|----------|
| `emit(topic, payload)` / `listen(topic)` | **in-process only** — two separate `agentis go` invocations cannot exchange a bus event | the coordinator handing the chosen action to the dispatch fn **within the same program** |
| `memo_write(key, value)` / `recall_latest(key)` / `agentis memo get <key>` | **durable, cross-process** (last-write-wins) | the gate **verdict** crossing back to the shell loop (a separate process) |

So the dispatch is wired as an **in-process** `emit → listen → call` DAG (mirroring `auditor.ag`'s
`reconn → guard → tracker → synthesis`), and the **outcome** is published to the **durable memo** because
that is the only substrate-native way to reach the next process.

## The event / fact contract

| Name | Kind | Value |
|------|------|-------|
| `dark-factory:dispatch` | in-process bus topic | payload `<type>\|<args>` (a hunt's args are `subsystem\|class`; refute/poc-screen carry a candidate id; invent-method has empty args) |
| `coordinator:last_outcome` | durable memo key | `<type>\|<args>\|<confirmed\|dry\|refuted>` |
| `DISPATCH_FIXTURE` | env fact (whitelisted in `exec.env_passthrough`) | offline verdict rules `type\|glob=verdict;type2\|glob2=verdict2` |
| `HUNT_FIXTURE` | env fact (backward-compat alias) | M1 `glob=verdict;…` hunt-only rules, consulted only when `DISPATCH_FIXTURE` is empty |

`DISPATCH_FIXTURE` is the **offline-determinism** fact: the dispatch fn derives an action's verdict from it
with **no `prompt()` / LLM**. Each rule is `<type>|<glob>=<verdict>`; it applies when `<type>` equals the
chosen action type **and** `<glob>` (a **prefix** glob, trailing `*` optional) matches the action **args**
(for a hunt that is `subsystem|class`; for refute/poc-screen the candidate id; invent-method has empty
args, matched by a bare `*` or empty glob). First match wins, default `dry` — the same semantics
`run-coordinator.sh`'s old `stub_outcome()` used, projected to one env string. `run-coordinator.sh` builds
it from **all** rows of `--fixture` in stub mode. With `DISPATCH_FIXTURE` empty (and no `HUNT_FIXTURE`
alias for a hunt), the dispatch fn takes an **honest per-type live stub** that prints what real wiring each
action still needs (`hunt`: `TARGET_DIR` / `IN_SCOPE` / …; `refute` → `run-refute.sh`; `poc-screen` →
`screen-leads.sh`; `invent-method` → `run-method-discovery.sh`, mirroring the old `real_outcome()` honesty)
and returns a benign `dry` — it does **not** attempt a real action.

## The flow

```
  coordinator.ag (ONE agentis go, DISPATCH_ENABLED set)
    decide  ──▶ print ACTION|<type>|<args>|<rationale>
            ──▶ emit("dark-factory:dispatch", "<type>|<args>")            (in-process bus)
            ──▶ dispatch():
                   listen("dark-factory:dispatch")
                   verdict = DISPATCH_FIXTURE rule for <type>,<args>  (offline; no LLM)
                   memo_write("coordinator:last_outcome", "<type>|<args>|<verdict>")   (durable)
                   print DISPATCH|<type>|<args>|<verdict>

  run-coordinator.sh (a SEPARATE process, next)
    OUTCOME = agentis memo get coordinator:last_outcome  →  trailing verdict field
```

`DISPATCH_ENABLED` gates the whole emit + call block. When it is **absent** (e.g. `demo-coordinator.sh`,
which runs `coordinator.ag` standalone and neither sets nor whitelists the flag), the block is **dark** —
no emit, no call, no extra output — so the standalone decision path is **byte-identical** to before M1/M2.

## What moved vs what is still shell

| Concern | Before #1014 | After M2 | After M3 |
|---------|--------------|----------|---------|
| **decide** the next action | substrate (`coordinator.ag`) | substrate (unchanged) | substrate (unchanged) |
| **dispatch** any action + derive its verdict | shell `case` (`stub_outcome` / `real_outcome`) | **substrate** (`coordinator.ag` emit → `dispatch` → memo) for **every** action type | substrate (unchanged) |
| carry the verdict back to the loop | shell variable | **durable memo** read by the shell loop (every non-`stop` action) | **in-process** `recall_latest` inside the loop |
| carry state between steps (PENDING / DRY_STREAK / BUDGET / policy) | shell | shell | **substrate** — the loop threads it all in the carried `reduce` state (#1014 M3) |
| **drive** the multi-step loop | shell while-loop | shell while-loop | **substrate** (`coordinator.ag` `reduce` over a budget-bounded `STEPS` list) |

The `stub_outcome()` / `real_outcome()` shell functions and their `case` dispatch were **removed in M2** —
the shell derives no outcome. **In M3 the shell while-loop itself is removed**: `run-coordinator.sh` is a
**bootstrap** that fires **one** `agentis go` and reads the final `decisions.tsv` + evolved policy back from
the `coordinator:trace` / `coordinator:policy_after` memos — see [`coordinator.md`](./coordinator.md).

`auditor/agents/dispatcher.ag` is the standalone, separately-committable copy of the dispatch agent fn
(`dispatch` + its helpers + a `DISPATCH_ARGS` top-level entry). Because agentis `go` has no file includes,
`coordinator.ag` inlines the same fns (gated on `DISPATCH_ENABLED`) so the combined decision+dispatch runs
in one program; `dispatcher.ag` documents and lint-validates the dispatch on its own, and is the
**sync-guard** target the demo asserts against.

## Reproduce

```sh
# Proves the in-substrate dispatch for EVERY action type, offline + deterministically (mock backend):
#   (A) HUNT          — one agentis go prints both ACTION|hunt|... and DISPATCH|hunt|...; verdict via memo
#   (B) REFUTE        — a pending candidate -> verify via refute; verdict via memo
#   (C) POC-SCREEN    — pending candidate + lifted poc policy -> screen; verdict via memo
#   (D) INVENT-METHOD — no huntable cell + no candidate -> invent; verdict via memo
#   each with a STANDALONE-dispatcher SYNC-GUARD (dispatcher.ag's DISPATCH| + memo == the inlined path)
#   (E) determinism (re-run byte-identical) + the verdict follows the fixture (flip it, the verdict flips)
dark-factory/demo-dispatch.sh        # exit 0 = all proven; non-zero = an assertion failed

# Drive the full loop with the substrate dispatch (stub executor = offline + deterministic):
dark-factory/run-coordinator.sh --scope <scope.tsv> --executor stub --fixture <fixture.tsv> --budget 8
```

## Boundaries kept

- **No new shell authority.** The dispatch uses real substrate `emit` / `listen` / `memo_write`; the shell
  only reads the memo and carries loop state. The colony still has zero platform-egress builtins.
- **Safety gates stay FACTS.** The verdict is a gate outcome (a fixture offline; `forge-verify` / the
  refuter / the `eval_ag` screen in a live run), never an LLM judgement and never bypassed.
- **The human-gated submission boundary stays.** Nothing here auto-submits at any confidence.
