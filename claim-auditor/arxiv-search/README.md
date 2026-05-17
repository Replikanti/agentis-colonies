# Arxiv Search Colony

> Part of the [Claim Auditor](../) federation.

<!-- TODO: Describe what this colony does and what agents it contains. -->

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| <!-- agent name --> | `agents/example_agent.ag` | <!-- what it learns --> | ~N observations |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Configure your forge or data-source connection in `colony.toml`.

3. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
