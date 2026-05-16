# Noticer Colony

> Part of the [Math Foundry](../) federation.

The noticer colony listens for `math-foundry:exploration_done` and
inspects the explorer's (code, stdout) pair. It asks the LLM whether
anything in the output is **surprising** or **non-obvious** — a
specific small number that does not match a closed form, a pattern
break, a numerical coincidence — and emits a structured surprise
record for the formulator.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| noticer | `agents/noticer.ag` | when output is interesting vs confirming a known formula | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
