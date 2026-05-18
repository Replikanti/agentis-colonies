# Computer Colony

> Part of the [Preprint Foundry](../) federation.

Generates a standalone reproducibility script (Python/SymPy or GAP)
that re-derives the central claim from scratch -- no import of the
upstream explorer's code -- and executes it inside the container to
capture canonical stdout. The editor and submitter colonies bundle
the script and the captured output into the final submission tarball.
On script-execution mismatch (the LLM-declared `expected_substring`
not present in stdout), the agent persists the artefacts but marks
`runs_ok=false` so downstream stages can flag the row.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| computer | `agents/computer.ag` | which compute stack (Python vs GAP) suits which claim shape | ~N observations (manual promotion) |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

3. The container image (`tools/Containerfile.preprint`) bundles `python3`
   with sympy/numpy/networkx plus `gap-core` for group-theory scripts.
   Host-side `gap` is optional but lets `tools/review-cli.sh --show`
   re-run the reproducibility script during human review.

4. Start the colony as part of the federation. Cross-colony handoff is
   now direct via the shared memo store; no `--source-*` flags. See
   `research-foundry/tools/run-research.sh --help` for the current
   invocation.
