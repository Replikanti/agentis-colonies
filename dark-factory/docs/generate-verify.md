# Symbolic generate-and-verify (#1015 M2 / M3)

M1 shipped the **callable** Halmos gate ([`docs/halmos.md`](./halmos.md)): given a hand-written `*.t.sol`
spec, [`evm-harness/halmos-verify.sh`](../evm-harness/halmos-verify.sh) returns a SOUND verdict (PROVED /
COUNTEREXAMPLE / INCONCLUSIVE) over **all** inputs. M2 closes the loop from a *candidate* to that verdict:
it **generates** the spec the gate runs.

## The contract: the LLM hypothesizes, Halmos proves

```
candidate ──(LLM writes a property spec)──► *.t.sol ──(halmos-verify.sh)──► SOUND verdict
   the HYPOTHESIS GENERATOR                              the JUDGE
```

- The **LLM is the hypothesis generator.** It turns one candidate (a `file:fn` lens + the invariant to
  encode + the relevant in-scope code) into a Halmos `*.t.sol` property spec whose `check_*` function
  asserts the invariant over **symbolic** inputs. An LLM proposal is, on its own, unverified — it can
  hallucinate both the bug and the property.
- **Halmos is the judge.** It runs symbolic execution + the z3 SMT solver over the generated spec and either
  **PROVES** the invariant holds for every input or returns a **concrete counterexample** that breaks it.
  There is no fuzzing, no sampling, and no flakiness.

**The verdict is Halmos's exit code — never the LLM's opinion.** That is the whole point of M2: the LLM's
job shrinks to *writing the property to check*; the truth of the answer is the solver's. A `PROVED` is a
real proof over all inputs (the lead is refuted **by a proof**, i.e. safe); a `COUNTEREXAMPLE` is a
concrete witness a human can replay (the bug is **confirmed**).

**Safety — the spec content is untrusted.** The generated spec is an LLM completion (prompt-injectable by
the untrusted candidate code under audit) or an operator fixture, so `symbolic-prover.ag` writes it with
`printf '%s' <shell_escape(spec)>`, never a heredoc — a single-quoted `shell_escape`d literal cannot be
escaped by any spec content, so a malicious spec is written verbatim (and then merely fails to compile or
is judged by Halmos), never executed as shell. The spec only ever reaches `forge`/`halmos` inside the run
sandbox.

## Components

| File | Role |
|---|---|
| [`auditor/agents/symbolic-prover.ag`](../auditor/agents/symbolic-prover.ag) | Per-candidate substrate agent: GENERATE the spec (fixture or `prompt()`), VERIFY it with the M1 gate, `emit`/`learn` the verdict, print `SYMBOLIC\|<file:fn>\|<verdict>`. |
| [`run-symbolic.sh`](../run-symbolic.sh) | Operator entrypoint: drive `symbolic-prover.ag` once per candidate over the substrate from a manifest, collect the verdicts into a report. |
| [`demo-symbolic.sh`](../demo-symbolic.sh) | Offline-deterministic demo: the full candidate → fixture-spec → REAL Halmos → verdict loop, asserting PROVED-safe + COUNTEREXAMPLE-confirmed. |
| [`demo-symbolic-orchestrate-live.sh`](../demo-symbolic-orchestrate-live.sh) | LIVE demo (#1032): the **coordinator's** chosen `symbolic-prove` action runs REAL Halmos end-to-end on an operator-supplied vault — buggy → COUNTEREXAMPLE → confirmed, fixed → PROVED → refuted. `[SKIP]` + exit 0 without forge/halmos/agentis. |

It mirrors the per-candidate structure of [`run-refute.sh`](../run-refute.sh) +
[`auditor/agents/refuter.ag`](../auditor/agents/refuter.ag) — env-in the candidate, generate, `emit`/`learn`
the verdict, `memo_write` the `last_check`, print one observable marker — but where the refuter's verdict is
the LLM's hostile read, the symbolic prover's verdict is **Halmos's proof**.

## Verdict mapping

`symbolic-prover.ag` maps the M1 gate's exit code (the only source of the verdict) directly:

| Halmos exit | Verdict | Meaning | `learn()` outcome |
|---|---|---|---|
| `0` | **PROVED** | invariant holds for ALL inputs → candidate SAFE (refuted by a proof) | `failure` |
| `1` | **COUNTEREXAMPLE** | a concrete input violates the invariant → a real bug, CONFIRMED with a witness | `success` |
| `3` | **INCONCLUSIVE** | solver `unknown` / timeout / loop not fully explored / nothing matched → no verdict | `partial` |
| else (`2`, …) | **HARNESS_ERROR** | bad args / repo not a Foundry project / `halmos`/`forge` missing | `error` |

A COUNTEREXAMPLE is the highest-value outcome, so it is recorded as `success` (symbolic-prover fitness
rewards candidates that the solver confirms); a PROVED safely consumes the hypothesis without a finding, so
it is `failure` — the same polarity as a rigorous `SAFE` in `hunter.ag`.

## Generation: offline (fixture) vs live (LLM)

`symbolic-prover.ag` has two generation paths, gated on a `SPEC_FIXTURE` env fact:

- **Offline / deterministic** — when `SPEC_FIXTURE` is set, that spec is used **verbatim** and **no LLM is
  called**. This is the path [`demo-symbolic.sh`](../demo-symbolic.sh) and a `--backend mock` wiring smoke
  take, so the candidate → halmos → verdict loop is provable with zero LLM cost and a real solver.
- **Live** — otherwise the LLM `prompt()`s the spec from the candidate's invariant + the in-scope code. The
  verdict is **still** Halmos's; the LLM only writes the property to check.

## Compose with M1

```bash
# Offline-deterministic proof of the WHOLE loop (real Halmos, no LLM):
dark-factory/demo-symbolic.sh

# Drive a real candidate manifest (cheap wiring smoke: --backend mock + a spec-fixture column):
#   candidates.tsv: `file:fn | class | invariant | code-file | spec-fixture`  (one per line)
dark-factory/run-symbolic.sh \
  --candidates "$PWD/candidates.tsv" \
  --repo "$PWD/target" \
  --backend flat-cyborg \
  --out "$PWD/symbolic-out"
```

`run-symbolic.sh` stages a fresh copy of `--repo` into its rundir (so the sandboxed `exec sh` can write the
spec into `test/` and run Halmos there), drops any pre-existing `*.t.sol` so the gate scopes to exactly the
generated spec, and routes each candidate through the substrate (`prompt`/`emit`/`learn`). The verdict table
lands at `<out>/symbolic-report.md`.

## Orchestration: the coordinator routes a candidate to the sound engine (#1015 M3)

M2 ships the **callable** step (`run-symbolic.sh` over a candidate manifest). **M3 wires it into the
self-orchestrating coordinator** ([`docs/coordinator.md`](./coordinator.md)): a new `symbolic-prove`
coordinator ACTION lets the federation **DECIDE** to route a pending candidate through the SOUND symbolic
engine, and the engine's verdict feeds back into the coordinator's **evolving policy** — the same
`learn()` mechanic every other action uses.

```
coordinator decides ──▶ ACTION|symbolic-prove|<cand> ──▶ run-symbolic.sh / symbolic-prover.ag
                                                              GENERATE spec ──▶ halmos-verify.sh (z3)
                                                              SOUND verdict
   policy evolves  ◀──── outcome (confirmed / refuted / dry) ◀──── verdict→outcome mapping
```

`symbolic-prove` lives in the coordinator's **VERIFY tier** alongside `refute` and `poc-screen` (a pending
candidate present ⇒ verify it before more hunting). Base score **96**, below `refute` (100) and `poc-screen`
(98) — routing through the symbolic engine is the most expensive verify (generate a spec + run z3), so the
cheaper verifies are tried first by default; the **policy weight** (the steepest in the tier, ×4) lets the
colony **learn** the sound verdict pays off and lift `symbolic-prove` above either. The ordering is
fact-and-policy-driven and **policy-evolvable**, exactly like the other action types.

### The verdict→outcome mapping (the epic's thesis)

The whole point: the confirmed/refuted signal the coordinator evolves on now comes from a **sound engine**,
never an LLM opinion. The symbolic gate's verdict maps to the coordinator's three-value gate-outcome enum:

| Symbolic verdict | Coordinator outcome | Meaning | policy signal |
|---|---|---|---|
| **COUNTEREXAMPLE** | `confirmed` | a concrete input is a real bug, CONFIRMED with a replayable witness | success (+0.15) |
| **PROVED** | `refuted` | the invariant holds for ALL inputs — the lead is killed **by a proof** (safe) | failure (−0.15) |
| **INCONCLUSIVE** | `dry` | solver unknown / timeout / not fully explored — no verdict, a non-productive step | failure (−0.15) |
| HARNESS_ERROR / other | `dry` | the run produced no verdict | failure (−0.15) |

On the **offline / deterministic** path the `DISPATCH_FIXTURE` carries the already-mapped outcome directly —
a `symbolic-prove|cand*=confirmed` rule stands in for a COUNTEREXAMPLE, `=refuted` for a PROVED — so the
orchestration is provable with **no live solver** (every action's offline path works this way). On the
**live** path (#1032) the mapping is realized end-to-end inside `coordinator.ag` itself: when the coordinator
**chooses** `symbolic-prove` and an operator-supplied live symbolic context is present (`SYM_REPO` +
`SYM_SPEC` + the `HALMOS_VERIFY` gate path), `coordinator.ag::action_outcome` runs **REAL Halmos**
(`halmos-verify.sh --repo <SYM_REPO> --target <SYM_SPEC>`) through `exec sh`, captures its exit code via the
`__rc=$?` marker, and maps it (1→confirmed, 0→refuted, 3/2/other→dry) — the verdict is the solver's, never an
LLM judgement. The branch is **purely additive**: absent any of the three env facts it falls through to the
honest stub, so the offline orchestration is unchanged. `dispatcher.ag` carries the byte-identical live branch
(the `demo-dispatch.sh` sync-guard asserts the two copies do not drift).

### Reproduce

```bash
# Offline-deterministic proof of the ORCHESTRATION (no Halmos needed — the fixture maps the sound verdict):
#   a hunt confirms -> pushes a candidate -> the coordinator CHOOSES symbolic-prove -> the SOUND verdict
#   flows back (COUNTEREXAMPLE->confirmed / PROVED->refuted) -> the candidate is consumed -> the policy evolves.
dark-factory/demo-symbolic-orchestrate.sh      # exit 0 = proven; non-zero = an assertion failed

# LIVE proof (#1032): the coordinator's chosen symbolic-prove action runs REAL Halmos end-to-end inside the
# loop for an operator-supplied single candidate — a buggy vault's solvency spec -> COUNTEREXAMPLE -> confirmed,
# a fixed vault's -> PROVED -> refuted. [SKIP] + exit 0 when forge/halmos/agentis are absent (CI convention).
dark-factory/demo-symbolic-orchestrate-live.sh # needs forge + halmos on PATH; else SKIP

# Bootstrap the in-substrate loop with a symbolic-prove route yourself (stub executor = offline; --sym-policy
# seeds the symbolic-prove policy so the coordinator chooses it from step 0):
dark-factory/run-coordinator.sh --scope <scope.tsv> --executor stub --fixture <fixture.tsv> \
    --sym-policy 1.5 --budget 4
#   fixture rule: `symbolic-prove | cand* | confirmed`  (= a Halmos COUNTEREXAMPLE; `refuted` = a PROVED)

# LIVE single-candidate route: supply a Foundry repo + a ready Halmos spec so the chosen symbolic-prove action
# runs REAL Halmos (forge + halmos must be on PATH). The verdict is Halmos's exit code, mapped
# COUNTEREXAMPLE->confirmed / PROVED->refuted / INCONCLUSIVE->dry — never an LLM opinion.
dark-factory/run-coordinator.sh --scope <scope.tsv> --sym-policy 1.5 --budget 4 \
    --sym-repo <foundry-dir> --sym-spec <Spec.t.sol>
```

## Honest scope

M2 ships the **callable** generate-and-verify step: an operator (or a higher-level script) invokes
`run-symbolic.sh` over a candidate manifest. **M3 wires it into the self-orchestrating coordinator** (above):
the coordinator decides *when* to spend a symbolic verify and feeds the SOUND verdict back into its evolving
policy. The deterministic orchestration proof uses a fixture that maps the sound verdict (no live Halmos
needed for the routing proof — exactly like every other action's offline path). **#1032 closes the LIVE
slice for an operator-supplied single candidate:** when the coordinator chooses `symbolic-prove` and a live
symbolic context is present (`--sym-repo` + `--sym-spec`, threaded as `SYM_REPO` / `SYM_SPEC` / `HALMOS_VERIFY`),
`coordinator.ag::action_outcome` runs **REAL Halmos end-to-end inside the loop** and maps its exit code to the
gate outcome — `demo-symbolic-orchestrate-live.sh` proves it against a vault with a real rounding-direction
solvency bug (COUNTEREXAMPLE → confirmed) and its fix (PROVED → refuted). The offline fixture path remains the
**CI proof** (no toolchain on the runners). **Multi-candidate code-carrying** — a *discovered* lead
auto-carrying its contract + invariant through `PENDING` so the loop spins up the live context itself — stays
the remaining follow-up (epic #1015 / #1014); this slice wires the operator-supplied single candidate.

On the **live** (LLM-generated-spec) path, an honest expectation: a generated Halmos spec must both **compile**
(`forge build` via Halmos) and stay **decidable** (small symbolic widths, bounded loops) for a clean
PROVED / COUNTEREXAMPLE. When the LLM emits a spec that does not compile, imports a contract the project
does not ship, or writes an unbounded loop, the gate returns **INCONCLUSIVE** (or a harness error) rather
than a false verdict — which is the **safe** failure mode, never a false PROVED. So `INCONCLUSIVE` is the
honest common case for an un-reviewed live spec; the fixture path (and an operator who iterates the spec) is
how you reach a sound PROVED / COUNTEREXAMPLE today. The soundness guarantee is the same either way: the
verdict is Halmos's, and the gate never over-claims PROVED.

As everywhere in this colony, a CONFIRMED bug is still a **lead** a human reviews; submission stays an
explicit, human-gated action and these tools NEVER post to a bounty platform.
