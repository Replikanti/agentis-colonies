# Cached arxiv paper corpus

The foundry orchestrator (`tools/run-foundry.sh`) reads one JSON file
per topic from this directory and rotates topic + paper-pair selections
across ticks. Live arxiv calls are rate-limited and would add latency
to every tick, so the orchestrator never hits arxiv at runtime — the
corpus is populated **once** via the bootstrap helper
[`../../tools/fetch-papers.py`](../../tools/fetch-papers.py) and then
served from disk.

## File layout

```
data/papers/
  number_theory.json
  combinatorics.json
  abstract_algebra.json
  graph_theory.json
```

## JSON schema (per topic file)

```jsonc
{
  "topic": "number_theory",
  "description": "Distribution of primes, additive combinatorics, ...",
  "compute_hints": "sympy, numpy, fractions; isprime, factorint, ...",
  "papers": [
    {
      "id": "2401.12345",
      "title": "...",
      "abstract": "..."
    },
    {
      "id": "2402.67890",
      "title": "...",
      "abstract": "..."
    }
    // ... at least 2 papers required per topic
  ]
}
```

The orchestrator round-robins over the topic list (FOUNDRY_TOPICS env)
and samples two distinct papers per tick via a seeded RNG so a re-run
with the same corpus is deterministic.

## Populating the corpus

Once, from a host that can reach arxiv:

```bash
python3 math-foundry/tools/fetch-papers.py \
    --output math-foundry/data/papers \
    --topics number_theory combinatorics abstract_algebra graph_theory \
    --per-topic 25
```

`fetch-papers.py` uses the `arxiv` Python package and respects
arxiv's recommended 3-second delay between requests. It does NOT run
during foundry execution.

## Why cached?

Three reasons:

1. **Determinism** — a foundry rerun with the same corpus produces the
   same topic / paper-pair sequence given the same FOUNDRY_TOPICS list
   and total-tick count.
2. **Cost / rate-limit** — live arxiv calls slow every tick by 3-5s
   and risk getting the operator IP rate-limited mid-run.
3. **Hermeticity** — the orchestrator's container does not need
   network access to arxiv. Only the LLM endpoint is reached from
   inside the sandbox.
