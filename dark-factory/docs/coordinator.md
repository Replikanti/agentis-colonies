# Self-orchestrating coordinator (v1)

The discovery colony used to take its workflow from a **fixed script** — `run-discovery.sh`'s
`(subsystem × class)` fan-out ran every cell in a hardcoded order, and an **external operator** chose the
target, the method, and when to stop. `coordinator.ag` (#1014) moves that **decision-making** into the
substrate: each step it reads the current FACTS and an evolving POLICY and chooses **one** next action —
there is no fixed sequence, and the policy that ranks the options **improves by outcome**.

This is v1 (MVP). It replaces the DECISIONS; **every action's DISPATCH also moved into the substrate in
#1014 M2** (M1 did `hunt`; M2 generalised it to refute / poc-screen / invent-method too — see
[`dispatch.md`](./dispatch.md) and [the v1 boundary](#the-v1-boundary) below). **In #1014 M3 the SHELL LOOP
is DISSOLVED** — the whole multi-step audit self-orchestrates inside the substrate in **one** `agentis go`;
the shell (`run-coordinator.sh`) is now a **bootstrap**, not a loop driver. See
[the v1 boundary](#the-v1-boundary).

## The loop: fact → decide → record → evolve

In #1014 M3 this whole loop runs INSIDE `coordinator.ag` (a `reduce` over a budget-bounded `STEPS` list); the
box below is now ONE `agentis go`, with `run-coordinator.sh` only bootstrapping it and reading the final
trace/policy memos back. The data flow is unchanged — only the driver moved into the substrate.

```
                 ┌──────────── coordinator.ag (#1014 M3: the loop runs IN-PROCESS; shell only bootstraps) ┐
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
   `poc-screen|<candidate>`, `symbolic-prove|<candidate>`, `invent-method`, `stop` — **scores** each from the
   facts and the policy, and picks the **argmax** (a policy-weighted ranking). The fact-criteria are explicit:
   - a pending unverified candidate ⇒ **verify** it (refute / poc-screen / symbolic-prove) before more hunting;
   - a fresh blackboard lead in a subsystem ⇒ prefer **hunting that subsystem**;
   - a higher-fitness lens ⇒ prefer it;
   - budget exhausted **or** *K* consecutive dry ⇒ **stop** (a hard fact gate).

   `symbolic-prove` (#1015 M3) routes the pending candidate through the **SOUND symbolic engine**
   (`run-symbolic.sh` / Halmos + z3 — see [`docs/generate-verify.md`](./generate-verify.md)); its verdict
   maps **COUNTEREXAMPLE → confirmed**, **PROVED → refuted**, **INCONCLUSIVE → dry**, so the confirmed/refuted
   policy signal comes from a sound proof, never an LLM opinion. It sits in the **VERIFY tier** with `refute`
   and `poc-screen`: default scores `refute`(100) > `poc-screen`(98) > `symbolic-prove`(96) — the symbolic
   route is the most expensive verify (generate a spec + run z3), so the cheaper ones go first by default —
   but its policy term (the steepest in the tier, ×4) lets the colony **learn** the sound verdict pays off and
   lift it above either. All three keep a pending candidate ahead of any fresh hunt.

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

What has **moved into the substrate since v1** (#1014 M1 → M2 → M3 — see [`dispatch.md`](./dispatch.md)):

- *dispatching EVERY action* (hunt / refute / poc-screen / invent-method) — **M2**. The decision **and** its
  dispatch happen in **one** `agentis go`: `coordinator.ag` decides the action, `emit`s it over the
  in-process bus (`dark-factory:dispatch`, payload `<type>|<args>`), and a sibling agent fn (`dispatch`,
  mirroring `auditor/agents/dispatcher.ag`) derives the gate verdict from the `DISPATCH_FIXTURE` fact and
  writes it to the durable `coordinator:last_outcome` memo. The `stub_outcome()` / `real_outcome()` shell
  functions are gone.

- *driving the WHOLE multi-step loop* — **M3**. Gated on `ORCHESTRATE_ENABLED`, `coordinator.ag`'s top level
  runs the entire audit as a `reduce` over a budget-bounded `STEPS` list: per step it decides, dispatches
  in-substrate, reads the verdict back (`recall_latest("coordinator:last_outcome")`), threads `PENDING`
  (push on a confirmed hunt, pop-first on refute/poc-screen), `DRY_STREAK`, `BUDGET`, and the **evolving
  policy** entirely in-process, and accumulates the `decisions.tsv` trace — then writes the final trace +
  evolved policy to the `coordinator:trace` / `coordinator:policy_after` memos. The in-process policy is
  carried in the loop state in ten-thousandths and rendered `%.4f`, so it is **byte-identical** to the
  shell's old experience-store `read_policy()` sum step for step (the loop also `learn()`s for the durable
  record). A `reduce` cannot `break`, so termination is modelled by a `stopped` flag that makes the step a
  no-op once `stop` / budget / dry-cap fires. With `ORCHESTRATE_ENABLED` **absent**, the top level does
  **exactly one** decision, **byte-identical** to before (the `demo-coordinator.sh` regression guard).

What the **shell still does** (`run-coordinator.sh`) — it is now a **bootstrap**, not a loop driver:

- builds the agentis store, seeds the FACTS + a `STEPS` budget list, and fires **one** `agentis go
  coordinator.ag` with `ORCHESTRATE_ENABLED`;
- reads the final `decisions.tsv` body + evolved policy back from the durable memos the in-substrate loop
  wrote, and cross-checks the in-loop policy against the experience-store `read_policy()` sum.

  It computes **no** action's outcome and carries **no** per-step loop state — both live in the substrate
  now. (Honest scope: the loop self-orchestrates per bootstrap invocation; a long-lived daemon-tick reflex —
  the loop running continuously without a shell bootstrap — is a separate refinement, below.)

**Follow-up (kept on epic #1014):**

- a long-lived **daemon-tick reflex** so the audit loop runs continuously in the substrate without a shell
  bootstrap re-seeding it each run;

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

# Proves the #1014 M3 in-substrate LOOP: ONE agentis go self-orchestrates a >=3-step audit, and the
# resulting decisions.tsv + evolved policy are byte-identical to the M2 shell-loop output for the same facts:
dark-factory/demo-orchestrate.sh        # exit 0 = proven; non-zero = an assertion failed

# Bootstrap the in-substrate loop yourself (stub executor = offline + deterministic; ONE agentis go drives
# the whole audit; the shell only seeds the facts + reads the trace/policy memos back):
dark-factory/run-coordinator.sh --scope <scope.tsv> --class-fitness <fit.tsv> \
    --executor stub --fixture <fixture.tsv> --budget 8
```

`coordinator.ag` parses with `agentis commit auditor/agents/coordinator.ag` and runs with
`agentis go coordinator.ag --enable-exec --enable-messaging` (it reads facts from env + the memo store
and writes experience, so it needs exec + messaging + `experience.enabled = true`).
