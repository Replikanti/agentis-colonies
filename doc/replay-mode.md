# Test-mode replay reference

`agentis replay` (an upstream CLI mode shipped by the `agentis` runtime)
re-runs a candidate `.ag` rewrite against a captured experience pack
**without touching the live federation**. Operators use it as a
staging gate: before promoting a hand-edited or `agentis evolve`-d
agent into the running federation, they score it against the same
inputs the previous version saw and decide on the diff alone.

Replay is upstream's responsibility (binary lives in `agentis`, not
this repo). This document is the colonies-side operator reference:
when to reach for replay, how to stage an experience pack from a
running federation, how to read the verdict, and how it composes with
[`auto-promote`](./auto-promote.md) and the
[`feedback-loop`](./feedback-loop.md) reality-check pattern.

## Scope

- **Included:** when replay is the right tool, exporting an experience
  pack from a federation directory, invoking `agentis replay`,
  reading the score / diff output, integrating verdicts with
  auto-promote.
- **Excluded:** the replay engine itself (stubbed builtins,
  `prompt()` cache semantics, side-effect gates — all upstream
  `agentis` runtime concerns), the `.ag` language reference, the
  experience-store on-disk schema (in the agentis runtime docs).

## When to use replay

Replay is the right tool when **all** of these hold:

- The agent has a live experience-store history with at least a few
  dozen acting rows (you need representative inputs to score against).
- You are about to swap the agent's `.ag` source — either a hand-edit
  or the output of `agentis evolve` — and want to know whether the
  new source agrees with the old one's decisions before letting it
  run on real GitLab/GitHub state.
- You can tolerate the verdict being a **conditional recommendation**,
  not a guarantee: replay scores against history, which only proves
  the new agent reproduces past judgement; it does not prove the new
  agent will generalise to inputs the old one never saw.

Replay is **not** the right tool when:

- The agent has no acting rows yet (shadow tier, or fresh after
  `agentis evolve`). Use the
  [`auto-promote`](./auto-promote.md) ladder's bootstrap step
  (`shadow → propose`, see ADR-0001) instead — it's structured to
  promote on observation alone.
- You want to validate end-to-end behaviour against a live forge.
  Replay mocks `exec sh`, `prompt()`, `emit`, `learn()`, and
  external writes — only the `.ag` decision tree runs against real
  data. For end-to-end validation, run the new agent in `shadow`
  tier in a sibling federation with its own experience store.

## Workflow

The five-step operator flow:

1. **Export experience.** From the running federation directory, run
   `tools/replay-export-experience.sh <fed-dir> <out.jsonl>`. The
   wrapper walks `<fed-dir>/.agentis/experience/<agent_id>.jsonl`,
   keys each row by agent **name** (read from the daemon registry,
   not by opaque `<agent_id>` hash), and concatenates everything
   into a single replay-friendly pack. See
   [Exporting an experience pack](#exporting-an-experience-pack) for
   the rationale on the name vs id remap.
2. **Modify the `.ag` source.** Hand-edit the `.ag` file in a
   working tree, or run `agentis evolve <agent.ag> --out <new.ag>`
   to produce the candidate. Keep it outside the live federation
   directory so the running daemon doesn't pick it up.
3. **Replay.** Invoke the upstream CLI:
   ```
   agentis replay <new.ag> --experience <out.jsonl>
   ```
   Optional flags supported by the upstream binary include `--limit
   N` (replay against the N most-recent rows), `--score-out
   <out.json>` (write the per-row diff to JSON for CI), and `--json`
   (emit the summary as JSON instead of human-readable text). Refer
   to `agentis replay --help` from the runtime release for the
   authoritative flag list.
4. **Read the verdict.** The replay engine compares each predicted
   action against the captured `action` + `outcome` and emits a
   summary like:
   ```
   replay summary: 92/100 matched, 8 diff
     - 4 prompt_unmatched (context_hash differs from cached row)
     - 3 action_diff (predicted=skip, expected=emit)
     - 1 outcome_diff (predicted=success, expected=fail)
   verdict: recommend (>= 90% match)
   ```
   Bucket meanings: `prompt_unmatched` is when the new agent's
   `prompt()` arguments hashed differently from any cached row, so
   the engine couldn't replay the LLM call (this is usually fine
   for prompt-text refactors but worth eyeballing). `action_diff`
   is a meaningful behavioural change. `outcome_diff` is when the
   action matches but the predicted outcome differs from history.
5. **Decide.** If `verdict: recommend`, swap the new `.ag` into
   the federation and restart the agent (e.g. via the dashboard's
   `/restart` endpoint or `start-colony.sh --restart-agent`). If
   `verdict: skip`, treat the diff log as a code-review checklist:
   either fix the new source until the diff is intentional, or
   abandon the rewrite.

## Exporting an experience pack

The agentis runtime stores experience under
`<fed-dir>/.agentis/experience/<agent_id>.jsonl`, keyed by an opaque
12-hex-character `agent_id` derived from the daemon's binding.
`agent_id` is stable across restarts of the same agent in the same
federation directory but **not** portable across:

- A federation rebuild (e.g. moving `dev-apprenticeship/` to a new
  host or recreating `.agentis/`).
- A `.ag` rewrite that triggers a fresh agent registration.
- Sibling federations using the same upstream `.ag` source.

The replay engine reads the pack by agent **name** (a stable label
declared in the agent's `.ag` file and registry) so the candidate
`.ag` can be matched even when its eventual `agent_id` differs from
the historical one. `tools/replay-export-experience.sh` does the
remap walk: it reads `<fed-dir>/.agentis/daemon/<colony>/<agent>.json`
(or the equivalent registry layout) to map each `<agent_id>.jsonl`
file to its agent name, then emits a single pack where every row
carries an explicit `agent_name` field.

The wrapper is a thin convenience around what is conceptually a
shared experience-pack export contract. If
[#323](https://github.com/Replikanti/agentis-colonies/issues/323)
(`tools/experience-transfer.sh`) lands, the replay export will
delegate to it via `experience-transfer.sh export --replay-pack`
rather than duplicating the walk.

## Integration with auto-promote

Replay is **complementary** to [`auto-promote`](./auto-promote.md),
not a replacement:

- Auto-promote moves an agent up the confidence ladder based on
  on-the-fly fitness signal (`reject_rate_acting`,
  `delta_slope_acting`).
- Replay scores a candidate `.ag` source change against frozen
  history.

A typical evolve cycle uses both: the auto-promote sidecar fires
`agentis evolve` when an agent's fitness signal degrades; an operator
runs `agentis replay` against the evolved candidate before swapping
it in; the new source then re-enters the auto-promote ladder from
its seed confidence. The two tools score different artefacts
(the source vs the running daemon) on different inputs (frozen vs
live) and the verdicts compose: a `replay: recommend` + a healthy
`auto-promote` slope is the strongest possible "this rewrite is
safe" signal short of a sibling-federation shadow run.

## Examples

[`examples/replay/`](../examples/replay/) ships a tiny synthetic
experience pack and a stub candidate `.ag` so operators can
sanity-check the replay flow before exporting from a real
federation. See
[`examples/replay/README.md`](../examples/replay/README.md) for the
walk-through.

## Prerequisites

- `agentis >= TBD` — the runtime release that ships `agentis
  replay`. This minimum will be pinned in a follow-up release PR
  once the upstream `agentis` MINOR lands; see #320 for the
  two-PR split rationale.
- `python3` for the export wrapper's registry-to-name lookup.

## Related

- [`auto-promote`](./auto-promote.md) — the live-federation
  promotion ladder; replay is the staging gate that runs **before**
  you let auto-promote act on a rewritten agent.
- [`feedback-loop`](./feedback-loop.md) — the reality-check pattern
  that produces the experience-store rows replay scores against.
- [ADR-0001](./adr/ADR-0001-confidence-tiers.md) — tier contract;
  governs which agents have meaningful acting rows for replay to
  score.
- [`tools/replay-export-experience.sh`](../tools/replay-export-experience.sh) —
  the export wrapper.
- [`examples/replay/`](../examples/replay/) — sample pack and
  candidate `.ag` for a dry run.
- [#320](https://github.com/Replikanti/agentis-colonies/issues/320) —
  test-mode replay design and two-PR split.
