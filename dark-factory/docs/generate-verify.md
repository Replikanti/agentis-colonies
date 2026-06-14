# Symbolic generate-and-verify (#1015 M2)

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

## Honest scope

M2 ships the **callable** generate-and-verify step: an operator (or a higher-level script) invokes
`run-symbolic.sh` over a candidate manifest. **Auto-routing** discovery candidates from `run-discovery.sh`
into the symbolic gate inside the self-orchestrating coordinator ([`docs/coordinator.md`](./coordinator.md))
— so the coordinator decides *when* to spend a symbolic verify and feeds the verdict back into its evolving
policy — is a **later milestone** on epic #1015.

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
