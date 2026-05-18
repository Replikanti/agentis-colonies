# Novelty Colony

> Part of the [Math Foundry](../) federation.

The novelty colony listens for `math-foundry:verified` and runs the
strictest stage of the pipeline. It DEFAULTS to NOT_NOVEL and only
emits NOVEL when the specific answer requires genuine computation
and is not a famous constant — Basel, Gauss sums, Galois of x^n - 2,
Milnor fiber formula, complete intersection Euler characteristic via
Chern classes, classical Fourier / Mellin transforms all collapse to
NOT_NOVEL. The verdict is written to memo as the final settlement
signal back to the explorer's fitness path.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| novelty | `agents/novelty.ag` | which answer shapes correspond to classical results | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
