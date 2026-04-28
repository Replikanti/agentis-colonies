# Tribe Gamma Colony

> Part of the [Tribes Bench](../) federation.

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

2. (Optional) Override the synthetic-target paths via env vars before launching:
   `TARGET_DIR` (default: `<fed>/targets/stage0`),
   `BUGS_MANIFEST` (default: `$TARGET_DIR/bugs.json`),
   `VERIFIER_PATH` (default: `<fed>/tools/verify-finding.sh`).
   tribes-bench is a non-forge federation (`forge.type = "none"`); no forge
   credentials are required.

3. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
