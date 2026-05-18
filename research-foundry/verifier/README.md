# Verifier Colony

> Part of the [Math Foundry](../) federation.

The verifier colony listens for `math-foundry:problem_ready` and
independently solves the formulator's problem from scratch (without
seeing the original Python code or the stated answer). A second
prompt — the strict referee — compares the independent solution to
the stated answer and emits ACCEPT / REJECT / NEEDS_REVISION. Only
ACCEPT propagates to the novelty referee.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| verifier | `agents/verifier.ag` | which problem phrasings reproduce the stated answer | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
