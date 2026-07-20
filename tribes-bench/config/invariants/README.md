# tribes-bench environmental invariants (#1735)

This directory holds `.inv` predicate modules that formalize tribes-bench's
ad-hoc reputation penalties as **environmental invariants** — operator-declared
negative predicates that participate in daemon selection (agentis-core RFC #929,
platform ADR-0009). They are an **optional** surface: `run-stage2.sh` wires them
in only when `STAGE2_INVARIANTS=1` (the default); `STAGE2_INVARIANTS=0` leaves
the `evolution.invariants_dir` / `daemon.invariant_*` config keys unset, which is
byte-identical to the feature being off.

## The two modules

Both express the same fitness signal — a tribe's externally scored reputation —
at two severities:

| Module | Class | Floor | Behaviour |
|--------|-------|-------|-----------|
| `reputation-floor-costly.inv` | `costly` | `reputation < 0.3` | Advisory-only on both daemon surfaces: logs `evolution.invariant_penalized`, never debits CB, never culls. The warm-up band. |
| `reputation-floor-inviolable.inv` | `inviolable` | `reputation < 0.1` | Real enforcement: HARD refuse at the `replicate()` admission gate + graceful self-cull on the in-tick sweep. |

There is only **one** signal binding —
`signal reputation = memo("reputation:tribes-bench-<colony>")` — expressed twice.
This maps directly onto the issue's own proposal: "violation → CB/fitness
penalty (costly class); an extreme threshold could be an inviolable cull."

## Why `<colony>`, not `<self>` (the load-bearing design fact)

The signal is scoped with the `<colony>` substitution token (agentis-core #953,
v1.28.0). `read_fitness_signal` resolves `<colony>` from the daemon's own
`--colony` value (`Evaluator::colony_name`, set at startup), so
`reputation:tribes-bench-<colony>` reads **each daemon's own tribe reputation**:
a hunter launched `--colony tribe-alpha` reads
`reputation:tribes-bench-tribe-alpha`, tribe-beta reads its own, etc. Two
daemons sharing one `.agentis` memo dir each read their own colony's memo
(agentis-core's `two_colonies_read_own` test). This is why **one shared module
set** correctly covers all five tribes with no cross-tribe contamination.

`<self>` would be wrong here: every tribe launches its hunter from a source file
literally named `hunter.ag`, so `role_name_from_source_path` resolves `<self>`
to the identical string `"hunter"` for all five tribes — it cannot discriminate
tribes. `test-invariants.sh` Layer 1 asserts the string `<self>` is **absent**
from both modules, and Layer 3 pins that every `tribe-*/scripts/start-colony.sh`
still launches its daemon with the matching `--colony tribe-<name>` flag — the
fact the whole `<colony>`-scoping design depends on.

## Version floor

`<colony>` resolution requires **agentis >= 1.28.0** (#953); the `signal`/`memo()`
grammar requires >= 1.27.0 (#950). On an older binary the `<colony>` token is
not recognised and stays as literal text, so `reputation:tribes-bench-<colony>`
becomes the **same** literal memo key for all five tribes — reintroducing exactly
the cross-tribe contamination this design avoids, under an `inviolable` class
that would then wrongly cull a healthy tribe for another tribe's bad reputation.
Because silently degrading here is actively unsafe, `run-stage2.sh` **hard-aborts**
(exit 1, pointing at `STAGE2_INVARIANTS=0`) when `STAGE2_INVARIANTS=1` and the
installed `agentis --version` is below 1.28.0 — it never silently skips.

## Floor derivation

Reputation is seeded at `0.5` (each `start-colony.sh` runs
`agentis memo set "reputation:tribes-bench-<tribe>" "0.5"` before the daemon
launch loop) and walks `+0.05` (clamp 1.0) on a verified finding / `-0.10`
(clamp 0.0) on a false positive (`tribe-alpha/agents/hunter.ag:1312-1402`,
identical across all five tribes):

- **`0.3` (costly)** — `>= 2` net false positives beyond the seed. A single
  unlucky tick (`0.5 → 0.4`) does not fire, so this is signal, not noise.
- **`0.1` (inviolable)** — `>= 4` net false positives beyond the seed with no
  offsetting verified finding. Reserved for a lineage that has demonstrated
  sustained, not incidental, unreliability before it is actually refused
  replication / self-culled.

These floors are content-addressed (`.inv` content is static — not
`calibration.toml`-tunable). A future recalibration PR revises them here; the
derivation above is the reasoning to revise against. `STAGE2_INVARIANTS=0` is the
immediate kill switch if the inviolable floor proves too aggressive in a live run.

## Additive, not a second write path

The inline `+0.05`/`-0.10` reputation arithmetic in `hunter.ag` is what **writes**
the reputation these invariants **read** — it is intentionally kept. The invariant
modules are a formalized, content-addressed enforcement/audit layer on top of the
existing write path, not a second write path, so there is nothing to
double-charge. Provenance (`daemon.invariant_culled` / `evolution.invariant_penalized`
lifecycle events carrying the set hash + module hash + reason) is emitted by
agentis-core for free; `run-stage2.sh` additionally writes a forensic
`invariant-set-hash.txt` sidecar into each run dir.

## Cold start

An `inviolable` signal fail-closes to a self-cull on a `Missing` read (memo
absent/empty/unparseable, or an unresolved/empty `<colony>`). This is covered by
construction: every `start-colony.sh` seeds the reputation memo at `"0.5"`
**before** its daemon launch loop, so the memo exists from the first sweep tick.

## Not wired here

- **Stages 0/1/baseline and Stage-3 docker/multi-node.** The
  reputation/knowledge-market mechanic starts at Stage 2; the same idempotent
  append + version guard can be replicated into the other harnesses once Stage-2
  adoption is validated live. The Stage-3 docker/multi-node orchestrator splits
  tribes across containers — a different shared-vs-isolated-`.agentis`-root
  topology that needs its own re-verification before copying this wiring in.
- **A live-daemon self-cull integration test.** `test-invariants.sh`'s fixture
  layer pins everything provable without spinning a real `agentis daemon` (the
  memo-format contract + fail-closed clean load + the module-set hash).
