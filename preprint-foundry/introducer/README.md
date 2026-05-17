# Introducer Colony

> Part of the [Preprint Foundry](../) federation.

Drafts the abstract (~150 words) and the LaTeX Section 1 Introduction
(~400-800 words) of a math preprint. Reads the seeded claim context
(problem / answer / novelty / auditor reasoning) plus the four search
reports from the upstream claim-auditor run, and produces a single
LLM-drafted block that the downstream editor colony stitches into
`main.tex`.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| introducer | `agents/introducer.ag` | when to cite vs. flag CITATION-NEEDED based on the search reports | ~N observations (manual promotion) |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

3. Start the colony as part of the federation:
   ```bash
   bash ../tools/run-preprint.sh \
       --source-audit-run /path/to/claim-auditor/runs/<id> \
       --source-foundry-run /path/to/math-foundry/runs/<id>
   ```
