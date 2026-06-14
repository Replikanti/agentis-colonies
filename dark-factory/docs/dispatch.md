# Substrate dispatch (#1014 M1 — hunt)

The self-orchestrating coordinator (see [`coordinator.md`](./coordinator.md)) moved the **decision** into the
substrate: each step `coordinator.ag` reads FACTS + an evolving policy and chooses one action. But a thin
shell loop (`run-coordinator.sh`) still **dispatched** that action — for `hunt` it ran a shell `case`
(`stub_outcome` / `real_outcome`) to derive the gate verdict, then fed it back.

**M1 moves the `hunt` dispatch onto the substrate.** The decision *and* its dispatch now happen in **one**
`agentis go`: the coordinator decides the hunt, emits it over the in-process bus, a sibling agent fn
derives the gate verdict and writes it to a durable memo, and the shell loop **reads the verdict from the
memo** instead of computing it in a `case`. Other action types (`refute` / `poc-screen` /
`invent-method` / `stop`) keep their shell dispatch — M1 is the `hunt` slice only.

## The two substrate channels (and why each)

agentis exposes exactly two relevant primitives, with different scopes:

| Channel | Scope | Used for |
|---------|-------|----------|
| `emit(topic, payload)` / `listen(topic)` | **in-process only** — two separate `agentis go` invocations cannot exchange a bus event | the coordinator handing the chosen hunt to the dispatch fn **within the same program** |
| `memo_write(key, value)` / `recall_latest(key)` / `agentis memo get <key>` | **durable, cross-process** (last-write-wins) | the gate **verdict** crossing back to the shell loop (a separate process) |

So the dispatch is wired as an **in-process** `emit → listen → call` DAG (mirroring `auditor.ag`'s
`reconn → guard → tracker → synthesis`), and the **outcome** is published to the **durable memo** because
that is the only substrate-native way to reach the next process.

## The event / fact contract

| Name | Kind | Value |
|------|------|-------|
| `dark-factory:dispatch` | in-process bus topic | payload `hunt\|<subsystem>\|<class>` |
| `coordinator:last_outcome` | durable memo key | `hunt\|<subsystem>\|<class>\|<confirmed\|dry\|refuted>` |
| `HUNT_FIXTURE` | env fact (whitelisted in `exec.env_passthrough`) | offline verdict rules `glob=verdict;glob2=verdict2` |

`HUNT_FIXTURE` is the **offline-determinism** fact: the dispatch fn derives a hunt's verdict from it with
**no `prompt()` / LLM**. Each rule is `<subsystem-glob>=<verdict>`; the glob is a subsystem **prefix**
(trailing `*` optional), first match wins, default `dry` — the same semantics
`run-coordinator.sh::stub_outcome()` uses, projected to an env string. `run-coordinator.sh` builds it from
the `hunt` rows of `--fixture` in stub mode. With `HUNT_FIXTURE` empty, the dispatch fn takes an **honest
live stub** that prints what real wiring it still needs (`TARGET_DIR` / `IN_SCOPE` / …, mirroring the old
`real_outcome()` honesty) and returns a benign `dry` — it does **not** attempt a real hunt.

## The flow

```
  coordinator.ag (ONE agentis go, DISPATCH_ENABLED set)
    decide  ──▶ print ACTION|hunt|<sub>|<cls>|<rationale>
            ──▶ emit("dark-factory:dispatch", "hunt|<sub>|<cls>")        (in-process bus)
            ──▶ hunt_dispatch():
                   listen("dark-factory:dispatch")
                   verdict = HUNT_FIXTURE rule for <sub>  (offline; no LLM)
                   memo_write("coordinator:last_outcome", "hunt|<sub>|<cls>|<verdict>")   (durable)
                   print DISPATCH|hunt|<sub>|<cls>|<verdict>

  run-coordinator.sh (a SEPARATE process, next)
    OUTCOME = agentis memo get coordinator:last_outcome  →  trailing verdict field
```

`DISPATCH_ENABLED` gates the whole emit + call block. When it is **absent** (e.g. `demo-coordinator.sh`,
which runs `coordinator.ag` standalone and neither sets nor whitelists the flag), the block is **dark** —
no emit, no call, no extra output — so the standalone decision path is **byte-identical** to before M1.

## What moved vs what is still shell

| Concern | Before M1 | After M1 |
|---------|-----------|----------|
| **decide** the next action | substrate (`coordinator.ag`) | substrate (unchanged) |
| **dispatch a `hunt`** + derive its verdict | shell `case` (`stub_outcome` / `real_outcome`) | **substrate** (`coordinator.ag` emit → `hunt_dispatch` → memo) |
| **dispatch** refute / poc-screen / invent-method | shell `case` | shell `case` (unchanged) |
| carry the verdict back to the loop | shell variable | **durable memo** read by the shell loop |
| carry state between steps (PENDING / DRY_STREAK / BUDGET / policy read) | shell | shell (unchanged) |

`auditor/agents/dispatcher.ag` is the standalone, separately-committable copy of the dispatch agent fn
(`hunt_dispatch` + its helpers + a `DISPATCH_ARGS` top-level entry). Because agentis `go` has no file
includes, `coordinator.ag` inlines the same fns (gated on `DISPATCH_ENABLED`) so the combined
decision+dispatch runs in one program; `dispatcher.ag` documents and lint-validates the dispatch on its own.

## Reproduce

```sh
# Proves all four offline + deterministically (no network, no LLM, mock backend):
#   (1) one agentis go prints BOTH ACTION|hunt|... and DISPATCH|hunt|...
#   (2) a separate agentis memo get reads hunt|<sub>|<cls>|<verdict>
#   (3) a re-run is byte-identical
#   (4) the verdict matches the HUNT_FIXTURE rule (flip the fixture, the verdict flips)
dark-factory/demo-dispatch.sh        # exit 0 = all four proven; non-zero = an assertion failed

# Drive the full loop with the substrate hunt dispatch (stub executor = offline + deterministic):
dark-factory/run-coordinator.sh --scope <scope.tsv> --executor stub --fixture <fixture.tsv> --budget 8
```

## Boundaries kept

- **No new shell authority.** The dispatch uses real substrate `emit` / `listen` / `memo_write`; the shell
  only reads the memo and carries loop state. The colony still has zero platform-egress builtins.
- **Safety gates stay FACTS.** The verdict is a gate outcome (a fixture offline; `forge-verify` / the
  refuter / the `eval_ag` screen in a live run), never an LLM judgement and never bypassed.
- **The human-gated submission boundary stays.** Nothing here auto-submits at any confidence.
