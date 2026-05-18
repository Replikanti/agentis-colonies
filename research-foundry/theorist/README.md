# Theorist Colony

> Part of the [Preprint Foundry](../) federation.

Produces LaTeX Section 2 (Preliminaries + Notation) and Section 3
(Main Result) of a math preprint. Reads the seeded claim context plus
the upstream explorer's code/output. For derivable claims, writes a
proof sketch inside `\begin{proof}...\end{proof}`; for purely
computational claims, sets `hedge_required=true` and describes the
experiment ("computational evidence suggests" framing).

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| theorist | `agents/theorist.ag` | when to hedge vs. assert based on upstream evidence | ~N observations (manual promotion) |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

3. Start the colony as part of the federation. Cross-colony handoff is
   now direct via the shared memo store; no `--source-*` flags. See
   `research-foundry/tools/run-research.sh --help` for the current
   invocation.
