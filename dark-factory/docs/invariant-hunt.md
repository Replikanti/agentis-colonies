# Stateful-invariant-fuzzing bounty hunter (#1035)

The symbolic gate ([`docs/generate-verify.md`](./generate-verify.md), #1015) PROVES a property over **all
inputs of one function**. The adversarial refuter ([`run-refute.sh`](../run-refute.sh), #999) is a hostile
LLM read of a single claim. Both leave the same gap: the **multi-step, stateful** bug — the one that only
emerges from a SEQUENCE of calls, across callers, in a particular order. That is precisely the class an
auditor reading one function at a time misses, and the class that survives into production: the ERC4626
**inflation/donation attack**, an accounting drift that compounds over many deposits, a re-entrancy that
only breaks on the third interleave, a fee that rounds in the protocol's favour until it doesn't.

This engine targets that class. Foundry ships a **stateful invariant fuzzer** built for it: it searches over
SEQUENCES of calls, not single inputs, and on a break it **shrinks** the offending sequence to a minimal
reproducer — a concrete exploit transaction order.

## The contract: the LLM writes the invariants, the fuzzer finds the exploit

```
target contract ──(LLM writes a Handler + deep invariants)──► *.t.sol ──(forge-invariant.sh)──► verdict + shrunk sequence
   the HYPOTHESIS GENERATOR                                              the JUDGE (Foundry's stateful fuzzer)
```

- The **LLM is the hypothesis generator.** It turns a target contract into a self-contained Foundry
  stateful-invariant test: a `Handler` that exposes the protocol's actions as **bounded actor functions** (an
  attacker / a victim calling `deposit`, `withdraw`, `donate`, `borrow`, …), plus a set of **deep
  `invariant_*` properties**. An LLM proposal is, on its own, unverified — it can hallucinate both the bug and
  the property.
- **The fuzzer is the judge.** Foundry drives randomized multi-call sequences through the `Handler`,
  re-checks every invariant after each call, and on a break shrinks the sequence to a minimal reproducer.

**The verdict is the fuzzer's exit code — never the LLM's opinion.** That is the whole point: the LLM's job
shrinks to *writing the handler + the properties to check*; the truth of the answer is the fuzzer's concrete
pass/fail plus the shrunk witness. A `FINDING` is a reproducible exploit transaction order a human can
replay; a `CLEAN` is the fuzzer failing to break any invariant in the given search budget.

**Safety — the test content is untrusted.** The generated test is an LLM completion (prompt-injectable by the
untrusted target code under audit) or an operator fixture, so
[`auditor/agents/invariant-prover.ag`](../auditor/agents/invariant-prover.ag) writes it with
`printf '%s' <shell_escape(test)>`, never a heredoc — a single-quoted `shell_escape`d literal cannot be
escaped by any test content, so a malicious test is written verbatim (and then merely fails to compile or is
judged by the fuzzer), never executed as shell. The test only ever reaches `forge` inside the run sandbox.

## Components

| File | Role |
|---|---|
| [`auditor/agents/invariant-prover.ag`](../auditor/agents/invariant-prover.ag) | Per-target substrate agent: GENERATE the test (fixture or `prompt()`), VERIFY it with the fuzzing gate, `emit`/`learn` the verdict, print `INVARIANT\|<target>\|<verdict>` + the shrunk sequence on a FINDING. |
| [`evm-harness/forge-invariant.sh`](../evm-harness/forge-invariant.sh) | The callable gate: runs Foundry's stateful invariant fuzzer over a `*.t.sol`, parses the JSON, returns FINDING (+ the shrunk sequence) / CLEAN / HARNESS_ERROR. |
| [`run-invariant-hunt.sh`](../run-invariant-hunt.sh) | Operator entrypoint: drive `invariant-prover.ag` once over the substrate on one target, collect the verdict + any exploit sequence into a report. |
| [`demo-invariant-hunt.sh`](../demo-invariant-hunt.sh) | Offline-deterministic demo: the full target → fixture-handler → REAL Foundry fuzzer → verdict loop, asserting a vulnerable vault → FINDING (with a non-empty shrunk sequence) and a hardened twin → CLEAN. |

It mirrors the per-candidate structure of [`run-symbolic.sh`](../run-symbolic.sh) +
[`auditor/agents/symbolic-prover.ag`](../auditor/agents/symbolic-prover.ag) — env-in the target, generate,
`emit`/`learn` the verdict, `memo_write` the `last_check`, print one observable marker — but where the
symbolic prover's verdict is Halmos's proof over one function, the invariant prover's verdict is **the
fuzzer's concrete failing call-sequence** over the whole protocol.

## Verdict mapping

`invariant-prover.ag` maps the gate's exit code (the only source of the verdict) directly:

| forge-invariant exit | Verdict | Meaning | `learn()` outcome |
|---|---|---|---|
| `1` | **FINDING** | ≥1 invariant broke under a concrete SHRUNK multi-call sequence → a CANDIDATE with a reproducible witness | `success` |
| `0` | **CLEAN** | every invariant held across the whole fuzzed search → no finding **in this budget** (NOT a proof of safety) | `failure` |
| else (`2`, …) | **HARNESS_ERROR** | the test did not compile / no `invariant_*` matched / repo not a Foundry project / `forge` missing | `error` |

A FINDING is the highest-value outcome (a reproduced multi-step exploit witness), so it is recorded as
`success` (invariant-prover fitness rewards targets the fuzzer breaks); a CLEAN consumes the hypothesis
without a finding, so it is `failure` — the same polarity as a rigorous `SAFE` in `hunter.ag`. **CLEAN is not
a proof**: the fuzzer searched `runs × depth` sequences and found nothing, which bounds confidence but does
not establish safety the way the symbolic gate's PROVED does.

## The deep-invariant taxonomy (what the LLM is asked to assert)

A shallow invariant (one that holds trivially, or only checks a single call) finds nothing. The generator
prompt asks specifically for invariants that can only be broken by a SEQUENCE:

- **value-conservation** — total assets in == total claimable out (no value appears or vanishes over a run).
- **no-depositor-loss** — an honest depositor's claim (`shares × vaultBalance / totalShares`) is always worth
  at least what they deposited, minus dust. (The inflation attack breaks exactly this: a victim deposit mints
  0 shares after the price is inflated, so their claim collapses.)
- **solvency-under-any-sequence** — the protocol can always honour every outstanding claim.
- **no-free-value-extraction** — no actor ends a sequence with more than they put in (minus legitimate yield).
- **share-price-monotonicity** — the price per share never moves in a direction that a depositor can be
  sandwiched by.

## Generation: offline (fixture) vs live (LLM)

`invariant-prover.ag` has two generation paths, gated on a `HANDLER_FIXTURE` env fact:

- **Offline / deterministic** — when `HANDLER_FIXTURE` is set, that test is used **verbatim** and **no LLM is
  called**. This is the path [`demo-invariant-hunt.sh`](../demo-invariant-hunt.sh) and a `--backend mock`
  wiring smoke take, so the target → fuzzer → verdict loop is provable with zero LLM cost and a real fuzzer.
- **Live** — otherwise the LLM `prompt()`s the handler + invariants from the target contract source. The
  verdict is **still** the fuzzer's; the LLM only writes the handler and the properties to check.

The harness is **forge-std-free by design** (like [`evm-harness/halmos-specs`](../evm-harness/halmos-specs)):
the test registers its fuzz targets via a `targetContracts() returns (address[])` view — the `StdInvariant`
ABI Foundry auto-discovers — and asserts with plain `require(...)`, with a private `_bound(x, lo, hi)` helper
instead of forge-std's `bound`. So it compiles in **any** Foundry project with zero library remappings, which
is what makes generation tractable across arbitrary targets.

## Run it

```bash
# Offline-deterministic proof of the WHOLE loop (real fuzzer, no LLM): vulnerable -> FINDING, hardened -> CLEAN
dark-factory/demo-invariant-hunt.sh

# Cheap wiring smoke (no real LLM): supply a ready handler + the mock backend
dark-factory/run-invariant-hunt.sh \
  --repo "$PWD/target" --target Vault.sol:Vault --class C-erc4626 \
  --handler-fixture "$PWD/handler.t.sol" --backend mock --seed 1

# Live: the LLM writes the handler + deep invariants from the target source, the fuzzer judges
dark-factory/run-invariant-hunt.sh \
  --repo "$PWD/target" --target Vault.sol:Vault --class C-erc4626 \
  --backend flat-cyborg --runs 256 --depth 64 --seed 1 --out "$PWD/invariant-out"
```

`run-invariant-hunt.sh` stages a fresh copy of `--repo` into its rundir (so the sandboxed `exec sh` can write
the test into `test/` and run forge there), drops any pre-existing `*.t.sol` so the gate scopes to exactly the
generated test, and routes the target through the substrate (`prompt`/`emit`/`learn`). The verdict + any
shrunk exploit sequence land at `<out>/invariant-report.md`. `--seed` pins forge's fuzz seed so the search is
reproducible.

## Honest scope, and how it relates to the rest of the epic

This ships the **engine**: one target → a handler + deep invariants → the fuzzer's verdict (FINDING with a
shrunk witness, or CLEAN). What it does **not** yet do:

- **Generating a compiling Foundry handler for an arbitrary protocol is the hard part.** The offline path is
  deterministic and proven; the live path's quality is bounded by whether the LLM emits a handler that both
  compiles AND exercises the protocol deeply enough to surface the bug. The fixture path exists precisely so
  the loop's verdict mechanic is provable independent of live-generation quality.
- **CLEAN is budget-bounded, not a proof.** For an over-all-inputs guarantee on a single function, the
  symbolic gate (#1015) is the right tool; this gate is the right tool for the multi-step class symbolic
  execution cannot reach at scale.
- **Coordinator-routing + fan-out are follow-up.** This is the callable per-target step, in the shape the
  coordinator's `symbolic-prove` / `refute` / `poc-screen` actions take — wiring an `invariant-hunt` action
  into the self-orchestrating loop, and fanning it over many targets, is the next increment.

It complements the discovery method-gap doc ([`auditor/methods/gap-stateful.md`](../auditor/methods/gap-stateful.md),
the #998/#1033 "stateful" gap the taxonomy-class lens misses) by making that gap **runnable as a verifier**:
where `auditor/agents/stateful-invariant-fuzz.ag` is an LLM *lens* that proposes a candidate, this engine
*reproduces* a multi-step exploit with the fuzzer and returns the concrete witness. As everywhere in this
colony, a FINDING is a **LEAD a human triages** — submission stays an explicit, human-gated action and this
colony **never auto-submits**.
