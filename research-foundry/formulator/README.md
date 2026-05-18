# Formulator Colony

> Part of the [Math Foundry](../) federation.

The formulator colony listens for `math-foundry:notice_done` and
crafts a self-contained, competition-style problem whose answer IS
the specific value the noticer flagged as surprising. The output
seeds the verifier chain: the verifier solves the problem
independently and the novelty referee checks whether the result is
classical or genuinely new.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| formulator | `agents/formulator.ag` | how to phrase problems so an independent solver agrees | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
