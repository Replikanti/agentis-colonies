# dev-apprenticeship: first real task — completion criterion & post-run triage

This document is the **pre-commitment contract** for the dev-apprenticeship
federation's first real end-to-end run (the run tracked by
[#1117](https://github.com/Replikanti/agentis-colonies/issues/1117)). It is
written *before* the run, on purpose: an open-ended task is trivially
abandonable, and after a setback frustration will argue against every rule
below. Committing now, while it is cheap, is the point.

It answers two questions that were never pinned down before:

1. **What does "the federation finished it" mean?** ([#1116](https://github.com/Replikanti/agentis-colonies/issues/1116))
2. **What happens after the run — success *or* failure?** ([#1118](https://github.com/Replikanti/agentis-colonies/issues/1118))

---

## 1. Completion criterion

### The task

Nominate **one** real, bounded task that:

- a human could do in roughly **one hour**,
- lives on a **repository the operator already knows**,
- has **no external review gate** standing between "work done" and "work
  verifiable" (so the criterion below is the only gate).

The task is named in the run's tracking issue (#1117) as a single
`dev-apprenticeship`-labelled issue on the target repo. The operator may
substitute their own task; the *shape* of the criterion does not change.

### The single binary condition

The federation has **completed** the task if and only if it has, with no
forbidden human help (see the boundary below):

> **Opened a pull request that (a) is mergeable — applies cleanly, no
> conflicts — and (b) passes the target repo's existing gate green: for
> this repo that is `tools/colony-lint.sh` with `0 failed` plus every
> required CI check.**

This is a single yes/no a **non-author can check without judgement**:

```sh
tools/completion-gate.sh <fed-dir> <target-issue> --pr <PR-number>
```

The gate prints `[PASS]`/`[FAIL]` per sub-condition and an overall verdict,
and exits non-zero unless all pass. No partial credit, no "almost".

### Explicitly out of scope

These are **not** part of the criterion and must not be substituted for it:

- ❌ Emergence / autonomy-narrative claims of any kind.
- ❌ An "Agentis-utilization-%" target — irrelevant to whether the task is done.
- ❌ "It produced something useful" — only the binary condition above counts.
- ❌ Partial completion ("the PR is 80% there") — that is **not done**.

### Human-intervention boundary

The run is only valid if the human stayed on the allowed side of this line.
**Crossing the forbidden column invalidates the run** — the result must then
be recorded as a failure, not a completion.

| Allowed (operator may do this) | Forbidden (invalidates the run) |
|--------------------------------|---------------------------------|
| Fix infra: install a toolchain, set credentials, free a port | Hand-write any part of the solution diff |
| Edit **prompt text** / agent instructions | Edit the target repo's code or tests by hand to make the gate pass |
| Fix **I/O plumbing**: snapshot wiring, forge config, rate-limit settings | Lower the bar mid-run (relax the criterion once it looks hard) |
| Restart a stuck daemon; raise/lower an agent's confidence tier | Open or fix the PR yourself when the federation cannot |
| Re-run after fixing one of the above | Pre-stage the answer in a memo / branch |

The principle: the operator may fix **the environment the federation runs
in**; the operator may **not** produce **the work the federation is being
measured on**. The moment "I'll just finish it myself" happens, the run is a
failure with a recorded reason — which is exactly the data #1117 is for.

---

## 2. Post-run triage protocol

The recurring failure mode on this project is **human, not technical**: when
a run frustrates, the federation gets cut and the issue gets closed as if the
cut were a conclusion (see #119 — closed at cut-time, not fix-time). This is
the single biggest blocker, larger than any line of code. The standing rule
below removes the option.

### If the run **fails**

1. **Do not cut the federation as the conclusion.** A stop is fine for the
   night; a *silent shutdown recorded as "done"* is not.
2. **Write a new `dev-apprenticeship` issue** naming the **exact** failure
   mode, with evidence from the instrumentation — the per-tick log and
   baseline from `tools/cost-rate-report.sh`
   ([#1114](https://github.com/Replikanti/agentis-colonies/issues/1114)) and
   the relevant agent logs. "It wasn't working" is not a failure mode;
   "the router throttled at N prompts/h and never recovered" is.
3. **Fix that.** The next action is the new issue, not the end of the project.

### If the run **succeeds**

1. **Record the first completion**: the `completion-gate.sh` verdict and the
   PR link, in the #1117 tracking issue.
2. **Nominate the next bounded task** and repeat. Only after a recorded
   completion is "Agentis as a worker" a claim worth testing externally
   (e.g. a paid bounty).

### Forbidden, always

> **No `dev-apprenticeship` issue may be closed with a *cut-reason*** — e.g.
> "wasn't using Agentis enough", "lost patience", "not worth it" — **instead
> of a *fix-reason* or a recorded data point.** An issue closes because it
> was fixed, or it stays open with a diagnosis. A setback produces a
> diagnosis, never a shutdown dressed up as a decision.

This protocol is the contract that stops the "I'll just finish it myself"
false positive and the "cut and close" false negative — the two ways this
project has previously fooled itself.
