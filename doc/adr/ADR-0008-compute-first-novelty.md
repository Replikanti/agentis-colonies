---
id: ADR-0008
title: Compute-first novelty discovery as the canonical pattern for novelty-requiring Agentis federations
status: Proposed
date: 2026-05-17
accepted-date:
authors: [ylohnitram]
supersedes: (none)
superseded-by: (none)
tags: [novelty, exec-sh, federation-pattern, math-foundry]
---

# ADR-0008: Compute-first novelty discovery as the canonical pattern for novelty-requiring Agentis federations

## Context

Several Agentis federations need to surface results that are
**novel** — not merely "plausible given the training distribution"
but verifiably absent from the priors an LLM ships with. The first
federation in this space, `math-foundry/` (#592), wants the pipeline
to surface competition-style math problems whose answers required
real computation to discover; the same shape recurs in chemistry,
materials science, biology, and any other domain where "the LLM
already knew this" is a failure mode.

Three architectural patterns were considered:

1. **Pure LLM**. Ask the LLM to generate novel problems directly.
   Empirically fails — the model regresses to the prior. The
   generated problems are well-formed and self-consistent but
   reduce to named classical results (Basel, Gauss sums, classical
   Fourier transforms, Galois of x^n - 2). The "is this novel?"
   check inside the same conversation is bypassed by the same prior.
2. **RAG-enhanced LLM**. Retrieve recent arxiv papers and ask the
   model to generate problems "inspired by" them. Empirically fails
   for the same reason — the model uses the retrieved context to
   produce a problem that **looks** novel (it cites the right paper
   ids) but the actual answer is still a named classical result.
   Retrieval moves the surface area, not the prior.
3. **Agentis evolution on pure LLM**. Run the M98 v3 prompt-evolution
   loop against the pure-LLM generator with a NOT_NOVEL penalty.
   Empirically fails — the loop converges on prompts that produce
   **different-looking** classical results, not different results.
   The novelty referee can flag them but the population dynamics do
   not have anywhere to flow because the search space is the LLM's
   prior, which the prompt rewriter cannot leave.

All three failures share one root cause: **the novelty signal lives
outside the LLM's prior, so a system whose only access to the world
is the prior cannot find it**.

## Decision

Adopt **compute-first novelty discovery** as the canonical pattern
for novelty-requiring Agentis federations.

The pipeline shape:

1. The **explorer** agent reads a domain topic + a context pair
   (cached arxiv abstracts for math, cached protein sequences for
   biology, …) and asks the LLM to emit a domain-specific
   **computation** — a Python script for math, an RDKit script for
   chemistry, a structural-bioinformatics script for biology — that
   *explores* the topic and prints intermediate values.
2. The agent then **executes** the produced code in the hermetic
   sandbox via the existing `exec sh` capability, capturing stdout.
3. A **noticer** agent reads the (code, stdout) pair and asks the
   LLM whether anything in the output is surprising — a small
   specific number that does not match a closed form, a pattern
   break, a numerical coincidence.
4. A **formulator** agent crafts a domain-appropriate problem whose
   answer **is** the discovered value.
5. A **verifier** agent solves the problem independently (without
   seeing the original code) and a **novelty** referee defaults to
   NOT_NOVEL unless the value cannot be reduced to a named classical
   result.

The architectural distinction is the `exec sh` step in (2). The LLM
is a **translator** between computational discoveries and natural-
language problems; it is no longer the **source** of novelty. The
novelty source becomes the computational sweep itself.

## Behavioural contract

A federation that claims compatibility with this ADR MUST:

- Run a per-tick computation in a sandbox the agent does not
  control (the hermetic agentis sandbox today; could be a remote
  worker in future).
- Provide a noticer / verifier / novelty chain that consumes the
  computation's stdout, NOT the producer agent's claims about it.
- Default the novelty verdict to NOT_NOVEL and require explicit
  positive evidence (the answer cannot be reduced to a named
  classical result).
- Surface the failure mode where the explorer regresses to "compute
  a thing that confirms Basel". The novelty referee is the right
  surface; per-explorer fitness must penalise NOT_NOVEL more than it
  rewards NOVEL so the M98 v3 prompt-evolution loop has somewhere
  to flow.

A federation MAY:

- Add additional verification stages (a second independent solver,
  a human-in-the-loop reviewer).
- Replace the computational backend (Python in the first
  federation; RDKit, BioPython, lean4, SAT solvers all qualify).
- Run multiple competing explorer lineages with M2-Malthusian
  replication.

## Consequences

**Positive**:

- Novelty becomes a property of the world, not of the prior.
- The LLM's training-cutoff stops being a soft ceiling on what the
  federation can find.
- Failure modes become observable: the discovery ledger lists every
  (code, stdout, problem, verdict) tuple so an operator can spot
  classical-result regressions before they dominate the
  population.

**Negative**:

- The sandbox must support arbitrary code output. The agentis
  `exec sh` capability already does this; future runtime
  hardening (capability subsets per-agent) must keep this surface
  available to compute-first explorers.
- LLM-as-translator is more brittle than LLM-as-generator. The
  formulator can phrase a problem badly enough that the verifier's
  independent solver gets a different answer; the verifier
  correctly REJECTs but the underlying discovery is real. The
  pipeline must accept some real-but-rejected discoveries as a
  cost of independent verification.
- Settlement drift (#591). The explorer's settlement path keys the
  novelty verdict on `tick - HOLD_PERIOD` which assumes the
  per-tick chain advances in lockstep. In practice, daemon ticks
  drift relative to the orchestrator's tick stream, so the explorer
  occasionally reads a verdict for the wrong tick. This is a known
  Phase 1 limitation; Phase 2 will key settlement on an explicit
  tick-id pointer the novelty agent writes alongside the verdict.

## Alternatives considered (and rejected)

- **Pure LLM novelty generator**. Rejected: regresses to prior.
  Mitigation attempts (chain-of-thought, self-criticism, ensemble)
  fail in the same way because they all happen inside the prior.
- **RAG-enhanced LLM**. Rejected: moves surface area, not prior.
  The retrieved papers shape the **language** of the output but
  not the **answer**.
- **Agentis evolution on pure LLM**. Rejected: search space is the
  prior. The fitness signal can shape *which* classical results
  the system favours but cannot push it past them.
- **Symbolic-only computation** (no LLM). Considered: would work
  for math but does not generalise (chemistry / biology pipelines
  need the LLM to interpret the computational output and produce
  human-readable problem statements).

## Status

**Proposed**. Phase 1 implementation lands in #592 with the
`math-foundry/` federation: five colonies (explorer / noticer /
formulator / verifier / novelty), one daemon per colony, a 30-tick
demo run, and the settlement drift bug from #591 accepted as a
known limitation.

Phase 2 (co-evolution, population dynamics scaling, settlement-by-
tick-id fix) deferred until the Phase 1 discovery ledger gives us
enough evidence to know whether compute-first actually surfaces
novel results at the rate we expect.
