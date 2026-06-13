# Substrate primitives in the Dark Factory colony (#997)

The colony was already substrate-driven for `prompt`, `emit`/listen, `learn`, `memo`/`recall`,
`exec`, `dag_put`/`dag_get`, and `evolve_self`. Issue #997 asked which of the remaining substrate
primitives — confidence-tiers, `replicate`, `delegate`, `decide`, the Lean verifier — genuinely fit
the audit workflow, and to wire the ones that do into a real, working use.

This note records the decision honestly: which were adopted, where, and **why the rest do not currently
fit**. The bar is "does something real," not "appears on the list."

## Adopted: `eval_ag` — substrate-native lead pre-screen

**Where:** `auditor/agents/poc-screener.ag`, driven by `screen-leads.sh` (self-contained `--demo`).

**The gap it fills.** The discovery hunter (`run-discovery.sh` + `hunter.ag`) surfaces a CANDIDATE as a
*prose* PoC sketch — an UNVERIFIED lead. The only existing gate is `evm-harness/forge-verify.sh`: a full
Foundry deploy + attacker tx + invariant assertion, which needs the cloned repo + `foundryup` and runs
slowly. Between "prose lead" and "full Foundry repro" there was nothing — every lead, including the junk
ones, cost a human a forge-verify setup to triage.

`eval_ag` is the substrate's first-class primitive for *evaluating generated agent code under a metered
sub-interpreter*. The screener lowers a lead's machine-checkable invariant to a
self-contained `.ag` PoC harness and runs it through `eval_ag_with_outcome`, which returns
`{value, outcome, partial, cb_spent}`. This buys two things a raw `exec sh` + second `agentis go`
subprocess does not:

1. **CB-exhaustion containment.** The harness runs with its OWN CB budget inside the sub-interpreter. A
   runaway harness (deep recursion, a hot loop) trips the inner CB meter and surfaces as the stable
   outcome `inner_cb_exhausted` — the screener is NOT starved or crashed by a runaway harness; it
   survives cleanly. Verified in the demo: a `burn(100000000, 0)` harness returns
   `indeterminate | inner_cb_exhausted`, screener exit 0. This is the containment guarantee `eval_ag`
   buys here, and the ONLY one — see the caveat below.
2. **A stable verdict vocabulary.** `outcome` discriminates "the invariant HELD" (a clean run returning
   `0`) from "the harness was junk" (`parse_error` / `compile_error` / `runtime_error` / `cap_denied`).
   A subprocess exit code blurs those — both look like "non-101."

**`eval_ag` does NOT sandbox `exec` in this runtime.** Confirmed against agentis v1.18.27: a harness
that calls `exec sh "..."` from inside `eval_ag` reaches the host — the sub-interpreter meters CB but
does not strip the host-exec capability from the inner program. So the containment claim is bounded:
`eval_ag` bounds a *runaway/infinite* harness (CB exhaustion), it does NOT bound a *malicious* one.
Harnesses fed to the screener must be operator-trusted, exactly as the hunter's PoC sketches and the
forge-verify Exploit.t.sol already are.

**Harness contract** (mirrors the colony's existing exit-101 two-sided gate in `auditor.ag::assess`): a
self-contained `.ag` program whose final expression is an int — `101` = INVARIANT VIOLATED (lead
reproduced), `0` = invariant HELD (refuted), anything else = indeterminate. Two-sided is an **author
convention, not a mechanical check**: the harness SHOULD assert the CONTROL (legit path accepted) AND
the EXPLOIT (attacker path breaks the invariant), returning `101` only when control held AND exploit
fired. But the screener only maps the harness's final int — it cannot detect a missing control
assertion, so a rigged always-`101` harness is NOT mechanically rejected here. That two-sidedness is
enforced downstream by the Rust/revm forge-verify gate (real deploy + control tx + exploit tx); the
screen is the cheap filter, not the arbiter. Every screen is recorded via `learn()` (a reproduced lead = `success`, a clean
held = `failure`, junk = `error`) and `emit("dark-factory:poc_screened", ...)`, so screen fitness accrues
as substrate experience alongside the hunter's per-class fitness.

**It is a pre-screen, not a verifier.** A reproduced screen decides a lead is WORTH the forge-verify
cost; it is a finding only after the full `forge-verify.sh` Foundry repro passes. Submission stays
human-gated. Run it: `./screen-leads.sh --demo` (3 leads → 1 reproduced, 1 held, 1 indeterminate, zero
external prerequisites).

## Not adopted (and the honest reason)

### `replicate` — conceptual fit, not runnable, and would add a fatal failure mode

The discovery fan-out (`run-discovery.sh` runs one `hunter.ag` per `subsystem × class` cell) *looks* like
the textbook `replicate` use: a coordinator spawning N copies of an audit worker. But `replicate(target)`
requires a valid peer **host:port** address AND an active **colony pool** — and when neither is present
it raises a runtime error that **aborts the whole agent run** (confirmed against agentis v1.18.27:
`replicate("audit-worker-2")` → `replication failed: invalid target address`, fatal). The canonical
`examples/replicate.ag` guards the call behind `if false` for exactly this reason. Wiring it into the
fan-out would either be fake (`if false`) or fragile (a single unreachable peer kills the discovery
pass). The current bash fan-out is already process-parallel and crash-isolated per cell. `replicate`
belongs to a genuine multi-node colony deployment, which the Dark Factory operator workflow (a single
host, hardened sandbox, human-gated output) is not. Adopting it would violate "do something real" and
"don't break other agents."

### `delegate` — no second cooperating agent to hand a typed sub-task to

`delegate(agent, args, {contract})` hands a typed sub-task to **another agent in the same program** and
waits for a typed return (the `|>` pipeline composes them). It fits a workflow decomposed into several
cooperating in-process agents — like dev-apprenticeship's reviewer fan-in. The discovery track's unit of
work is one deep adversarial `prompt()` over one slice; there is no second agent whose typed output the
hunter consumes mid-tick. The cross-agent coordination that DOES exist here is already the right tool for
it — the `emit`/listen bus (`auditor.ag`'s reconn → guard → tracker → synthesis) and the bash manifest
fan-out — both crash-isolated in a way an in-process `delegate` is not. Forcing `delegate` would mean
inventing a sub-agent boundary that the audit logic does not actually have.

### `decide` — a soft choice where the colony deliberately wants a hard gate

`decide(options, criteria)` is a choice primitive with a deterministic offline fallback — it does NOT
strictly require a Prompt round-trip (an unconfigured backend resolves the choice deterministically). The
distinction here is not "LLM vs not": the colony's verdicts are deliberately NOT judgement calls at all,
LLM-backed or otherwise. Detection routes to synthesis, and the SOURCE OF TRUTH is the two-sided real-EVM/SVM gate
(`CONTROL OK:` + `INVARIANT VIOLATED:` + exit 101) and now the `eval_ag` screen — mechanical, reproducible
gates whose whole point (see the CHANGELOG security entries) is that an LLM's optimism cannot mint a false
VERIFIED. Replacing a hard gate with `decide` would regress that. The colony already uses `prompt()` for
the one thing an LLM is the right tool for — reading code adversarially — and keeps the verdict mechanical.

### Lean verifier (`compute_lean`) — wrong proof object for runtime exploit reproduction

`compute_lean(script, mathlib, timeout_ms)` machine-checks a **Lean** proof script. It is the right tool
when the property is a mathematical theorem you can state in Lean (the `research-foundry` federation's
number-theory work is the natural home). A Dark Factory finding is not a theorem about pure math — it is
"this deployed bytecode, given this attacker transaction sequence, moves funds / breaks an invariant."
That property is established by RUNNING the exploit against the real VM (revm / solana-program-test), which
is precisely what the two-sided gate and the `eval_ag` screen do. There is no faithful Lean encoding of
"the EVM executed this trace and the pool drained" short of formalizing the VM itself — out of scope, and
`lean`/`lake` is not part of the audit toolchain. A machine-checked *runtime reproduction* is the right
proof object here, and the colony already has it.

### Confidence-tiers — the colony is intentionally one-shot + human-gated, not autonomous

The four-tier confidence gradient (shadow → propose → review-gated → autonomous) gates how AUTONOMOUS an
agent's external writes are. Dark Factory has exactly one external action — staging a submission package —
and it is **hard-gated to a human** by design: the colony has zero platform-egress builtins and never
auto-submits, at any confidence. The agents are one-shot `agentis go` invocations driven by operator
scripts, not long-lived daemons climbing a confidence ladder. A tier gate here would be decorative — there
is no autonomous write for it to throttle. (This is a deliberate divergence from dev-apprenticeship, whose
whole premise is graduated autonomy; ADR-0001's tier contract is normative for daemon colonies that act on
a bus, which this discovery track is not.)
