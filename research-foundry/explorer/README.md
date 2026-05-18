# Explorer Colony

> Part of the [Math Foundry](../) federation.

The explorer colony is the **compute-first** entry point of the
discovery pipeline. On each tick the explorer reads a topic + cached
arxiv paper pair seeded by `tools/run-foundry.sh`, asks the LLM to
emit Python code that explores the topic computationally, executes
the code in the hermetic sandbox via `exec sh "python3 ..."`, and
publishes the (code, stdout) pair to memo for the downstream noticer
to inspect.

This is the architectural distinction codified in
[ADR-0008](../../doc/adr/ADR-0008-compute-first-novelty.md): agents
WRITE PYTHON CODE that runs in the sandbox; LLMs translate
computational discoveries into math problems rather than generating
novelty from priors.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| explorer | `agents/explorer.ag` | which exploration goals produce NOVEL outcomes vs NOT_NOVEL | ~10 ACCEPT-ed problems |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
