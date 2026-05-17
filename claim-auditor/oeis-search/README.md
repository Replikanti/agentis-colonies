# Oeis Search Colony

> Part of the [Claim Auditor](../) federation.

<!-- TODO: Describe what this colony does and what agents it contains. -->

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| <!-- agent name --> | `agents/example.ag` | <!-- what it learns --> | ~N observations |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Configure your forge (GitLab or GitHub) connection in `colony.toml` under `[forge]` and the matching `[forge.<type>]` block (see [ADR-0002](../../doc/adr/ADR-0002-forge-abstraction.md)).

3. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
