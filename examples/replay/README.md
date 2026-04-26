# Replay-mode example

This directory ships a tiny synthetic experience pack and a stub
candidate `.ag` so operators can sanity-check the replay flow without
exporting anything from a live federation.

For the full conceptual reference, see [`doc/replay-mode.md`](../../doc/replay-mode.md).

## Files

| File | Contents |
|------|----------|
| `candidate_labeler.ag` | A minimal stub that follows the canonical four-tier branch shape (autonomous / review-gated / propose / shadow). Stands in for what an `agentis evolve`-d or hand-edited candidate would look like. |
| `sample-pack.jsonl` | 15 synthetic experience rows keyed by `agent_name: "candidate_labeler"`. Mix of `observed`, `emitted`, `review-gated`, and `acted` rows; one row deliberately drifts to `outcome: "fail"` so the replay diff bucket has something to report. |

## Walk-through

```bash
# From the repo root, replay the candidate against the synthetic pack.
agentis replay examples/replay/candidate_labeler.ag \
  --experience examples/replay/sample-pack.jsonl
```

The exact stdout format is defined by the upstream `agentis` runtime;
expect a summary line plus a per-row diff table for any rows where
the predicted action did not match the captured row.

To exercise the export wrapper end-to-end against a live federation
instead, run:

```bash
# Capture experience from an installed federation.
./tools/replay-export-experience.sh dev-apprenticeship \
  /tmp/dev-apprenticeship-replay.jsonl

# Edit a candidate copy of one agent (do NOT edit the live tree).
cp dev-apprenticeship/triage/agents/labeler.ag /tmp/labeler-candidate.ag
# ... your edits or `agentis evolve` output ...

# Score the candidate against the captured pack.
agentis replay /tmp/labeler-candidate.ag \
  --experience /tmp/dev-apprenticeship-replay.jsonl \
  --agent labeler
```

## Caveats

- The bundled `sample-pack.jsonl` is intentionally tiny. Real
  federations accumulate hundreds of acting rows per agent before
  replay produces a statistically meaningful verdict — the
  upstream replay engine's recommendation threshold (defaulting to
  ~90% match) is calibrated for that scale, not for 15-row demos.
- The `ctx` hash in every row is a placeholder (`a1b2…aaaa`). On a
  real pack, `ctx` is the SHA-256 of the prompt context; the
  replay engine uses it to decide whether to replay a cached
  `prompt()` call or tag the row as `prompt_unmatched`.
- The candidate `.ag` here intentionally has no `prompt()` call —
  the LLM-mocking path of replay is exercised by real agents, not
  this stub. Use a real agent file when you want to see the
  `prompt_unmatched` bucket in action.

## Related

- [`doc/replay-mode.md`](../../doc/replay-mode.md) — full
  operator reference.
- [`tools/replay-export-experience.sh`](../../tools/replay-export-experience.sh) —
  the wrapper used in the second walk-through above.
- [#320](https://github.com/Replikanti/agentis-colonies/issues/320) —
  test-mode replay design.
