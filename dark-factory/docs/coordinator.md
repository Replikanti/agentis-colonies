# Self-orchestrating coordinator (v1)

The discovery colony used to take its workflow from a **fixed script** — `run-discovery.sh`'s
`(subsystem × class)` fan-out ran every cell in a hardcoded order, and an **external operator** chose the
target, the method, and when to stop. `coordinator.ag` (#1014) moves that **decision-making** into the
substrate: each step it reads the current FACTS and an evolving POLICY and chooses **one** next action —
there is no fixed sequence, and the policy that ranks the options **improves by outcome**.

This is v1 (MVP). It replaces the DECISIONS; **every action's DISPATCH also moved into the substrate in
#1014 M2** (M1 did `hunt`; M2 generalised it to refute / poc-screen / invent-method too — see
[`dispatch.md`](./dispatch.md) and [the v1 boundary](#the-v1-boundary) below). The shell loop still drives
the loop and carries state between steps, but it computes **no** action's outcome.

## The loop: fact → decide → record → evolve

```
                 ┌──────────────────── run-coordinator.sh (loop driver; reads the verdict memo) ─────────┐
                 │                                                                                       │
  FACTS  ───────▶│  coordinator.ag  ──▶  ACTION|<type>|<args>  ──▶  DISPATCH in-substrate  ──▶ OUTCOME (a gate verdict)
 (scope, per-    │   one decision +         (decide from facts +     emit → dispatch() →        confirmed / dry / refuted
  class fitness, │   in-process dispatch     policy; #1014 M2)        coordinator:last_outcome      │
  blackboard,    │   per `agentis go`                                memo (durable)                │
  pending cands, │                                  live-path executor targets (follow-up):        │
  budget, prev   │                                  hunt→hunter.ag refute→refuter.ag               │
  outcome)       │                                  poc-screen→poc-screener invent→method-inventor │
                 │◀──────────────────────── feed the OUTCOME back next step ─────────────────────────────┘
                 │  EVOLVE: learn("coordinator", <type>, …, confirmed→success / dry|refuted→failure)
                 │          → coordinator:policy:<type> cumulative fitness reweights
                 └───────────────────────────────────────────────────────────────────────────────────────┘
```

1. **Fact.** `coordinator.ag` reads only FACTS — every input is evidence, none is an LLM judgement:
   - `SCOPE` — the huntable `subsystem|class` cells still open.
   - `CLASS_FITNESS` — per-lens fitness (which bug classes have paid off), `class=delta;…`.
   - `POLICY` — per-action-type fitness, `type=delta;…` (the evolving decision policy; see step 4).
   - the shared **blackboard** (`dark-factory:blackboard:leads`, #1001) — fresh leads a sibling posted.
   - `PENDING` — unverified candidate leads waiting on a gate.
   - `BUDGET` / `DRY_STREAK` / `DRY_CAP` — remaining steps and the consecutive-dry stop condition.
   - `PREV_ACTION` / `LAST_OUTCOME` — the previous action and **its gate verdict** (a FACT from
     forge-verify / the refuter / the screen, *not* an LLM call).

2. **Decide.** It enumerates the ACTION OPTIONS — `hunt|<subsystem>|<class>`, `refute|<candidate>`,
   `poc-screen|<candidate>`, `invent-method`, `stop` — **scores** each from the facts and the policy, and
   picks the **argmax** (a policy-weighted ranking). The fact-criteria are explicit:
   - a pending unverified candidate ⇒ **verify** it (refute / poc-screen) before more hunting;
   - a fresh blackboard lead in a subsystem ⇒ prefer **hunting that subsystem**;
   - a higher-fitness lens ⇒ prefer it;
   - budget exhausted **or** *K* consecutive dry ⇒ **stop** (a hard fact gate).

   It then calls the substrate **`decide(options, criteria)`** builtin on the already-fact-ranked list as
   the selection step. See [`decide` vs argmax](#decide-vs-policy-weighted-argmax).

3. **Record.** It emits exactly one `ACTION|<type>|<args>|<rationale>` line (the rationale **cites the
   facts** that drove it), `emit`s `dark-factory:decision`, and `memo_write`s `coordinator:last_decision`.
   The shell dispatches the action and captures the **outcome**.

4. **Evolve.** On the next call the coordinator attributes the previous action's outcome to its
   action-type with the **same** `learn()` mechanic the lens-fitness loop uses (#996,
   `evolve-fitness.sh` / `fitness-driver.ag`):
   ```
   learn("coordinator", "<action-type>", …, confirmed→success | dry|refuted→failure, […])
   ```
   The runtime writes one experience row per call carrying a `±0.15` `delta`. The **cumulative delta per
   action-type key IS** `coordinator:policy:<action-type>` — read back from `.agentis/experience/*.jsonl`
   (exactly `evolve-fitness.sh::read_fitness`) and passed in as the `POLICY` fact next step. So the policy
   that ranks the options is **data that improves**: an action-type that keeps confirming findings gains
   weight; one that keeps coming back dry/refuted loses it.

## `decide` vs policy-weighted argmax

`decide(options, criteria)` **is** a real substrate builtin in agentis v1.18.27. But its
offline / unconfigured-backend resolution is **deterministic-first-option** — it does **not** read the
`criteria` text (verified: the same options in a different order return whichever option is listed first).
So a fact-and-policy choice cannot come from `decide`'s criteria alone offline.

The coordinator therefore does the choosing itself: it **scores every option from the facts + the learned
policy weight, orders the options by that score** (a policy-weighted argmax), and then calls `decide()` on
the **already-fact-ranked** list as the substrate-native selection step (offline it returns the
top-ranked option, which *is* the argmax). The ordering — the actual decision — is the coordinator's,
derived from facts + policy, **never** a fixed order and **never** an LLM judgement of the verdict. With a
real LLM backend `decide` could additionally arbitrate a near-tie from the criteria; the gate-grade
priority (verify a pending lead before hunting; stop on budget/dry) stays a hard fact rule either way.

## The v1 boundary

What the **coordinator DECIDES** (in the substrate, from facts + an evolving policy):

- which action to take next — hunt / refute / poc-screen / invent-method / stop;
- which lens to hunt (the highest fact+policy-scored `subsystem|class`), and which candidate to verify;
- when to stop (budget exhausted or *K* consecutive dry);
- how to reweight its own decision policy by outcome.

What has **moved into the substrate since v1** (#1014 M1 → M2 — see [`dispatch.md`](./dispatch.md)):

- *dispatching EVERY action* (hunt / refute / poc-screen / invent-method). The decision **and** its
  dispatch now happen in **one** `agentis go`: `coordinator.ag` decides the action, `emit`s it over the
  in-process bus (`dark-factory:dispatch`, payload `<type>|<args>`), and a sibling agent fn (`dispatch`,
  mirroring `auditor/agents/dispatcher.ag`) derives the gate verdict from the `DISPATCH_FIXTURE` fact and
  writes it to the durable `coordinator:last_outcome` memo. The shell loop **reads the verdict from that
  memo** for every non-`stop` action instead of a shell `case` — the `stub_outcome()` / `real_outcome()`
  shell functions are gone.

What the **shell still does** (`run-coordinator.sh`):

- driving the loop and carrying state between steps (pending list, dry streak, budget) and feeding each
  outcome back;
- reading the cumulative policy from the experience store between calls.

  It no longer **computes** any action's outcome — that is the substrate dispatch's job; the shell reads one
  `coordinator:last_outcome` memo per non-`stop` step.

**Follow-up (kept on epic #1014):**

- wire each action type to its real executor agent on the LIVE path (`refute`→`refuter.ag`,
  `poc-screen`→`poc-screener.ag`, `invent-method`→`method-inventor.ag`, hunt→`hunter.ag`), so the
  in-substrate dispatch reasons against the real candidate code/env instead of the honest live stub;
- the coordinator pruning / reprioritising the live cell manifest from the blackboard;
- multi-target portfolio decisions across more than one in-scope codebase;
- the generate-and-verify routing from #1015.

**Boundaries kept (unchanged by this work):**

- **No external/authority input drives the workflow.** The operator sets the goal (the scope) and the
  human-gated submit boundary; the *workflow* is the coordinator's.
- **The human-gated submission boundary stays.** The colony has zero platform-egress builtins and never
  auto-submits, at any confidence.
- **Safety gates are FACTS the decision consumes, never bypassed.** `forge-verify`, the refuter, and the
  `eval_ag` screen remain the source of truth for whether a lead is real; the coordinator routes work
  toward them, it does not replace or short-circuit them.

## Reproduce

```sh
# Proves BOTH acceptance criteria offline + deterministically (no network, no LLM, mock backend):
#   (a) distinct fact-states -> distinct chosen actions (not a fixed order)
#   (b) the decision policy measurably evolves (rewarded type's weight rises, wasteful one's falls)
dark-factory/demo-coordinator.sh        # exit 0 = both proven; non-zero = a criterion failed

# Proves the #1014 M2 substrate DISPATCH for every action type (decision + dispatch in one agentis go;
# verdict via memo; per-type standalone-dispatcher sync-guard):
dark-factory/demo-dispatch.sh           # exit 0 = all proven; non-zero = an assertion failed

# Drive the loop yourself (stub executor = offline + deterministic; every action is dispatched in-substrate):
dark-factory/run-coordinator.sh --scope <scope.tsv> --class-fitness <fit.tsv> \
    --executor stub --fixture <fixture.tsv> --budget 8
```

`coordinator.ag` parses with `agentis commit auditor/agents/coordinator.ag` and runs with
`agentis go coordinator.ag --enable-exec --enable-messaging` (it reads facts from env + the memo store
and writes experience, so it needs exec + messaging + `experience.enabled = true`).
