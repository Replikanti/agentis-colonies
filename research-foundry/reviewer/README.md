# Reviewer Colony

> Part of the [Preprint Foundry](../) research-foundry federation.

The reviewer colony reads the editor's final `main.tex` and the
computer's reproducibility stdout, extracts every numerical / symbolic
claim from the .tex, and flags every claim that lacks direct support
in the reproducibility output. The structured Verdict
(`approved` / `rejected`) is persisted to memo and -- on `approved`
verdicts only -- the per-claim gate `reviewer:<claim>:approved` is set
to `"true"`. The submitter colony reads that gate before writing the
DRAFTED row to `preprint-ledger.jsonl`: an empty / missing reviewer
memo blocks the submission (block-by-default, since the reviewer is
the highest-stakes critic in the Phase 4 pipeline). Operators can
override the gate manually via
`agentis memo set reviewer:<claim>:approved true` (Phase 4 PR-C of
#625).

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| reviewer | `agents/reviewer.ag` | which kinds of claim look supported by reproducibility stdout vs hallucinated | ~10 acted ticks |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```
