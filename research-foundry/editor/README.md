# Editor Colony

> Part of the [Preprint Foundry](../) federation.

Synthesises the introducer + theorist + computer outputs into a single
LaTeX document (`main.tex`, `amsart` class), generates a minimal
`refs.bib` from the upstream search reports, runs
`latexmk -pdf -interaction=nonstopmode` inside the container, and on
first-pass compile failure makes one LLM-driven repair pass before
giving up. Also enforces style (no "obviously", abstract is
third-person) and cross-checks every numeric / symbolic claim in the
main result against the reproducibility output, marking
`hallucinations_found=true` when any claim is removed or hedged.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| editor | `agents/editor.ag` | which LaTeX-compile failure modes are auto-repairable vs. need human intervention | ~N observations (manual promotion) |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

3. The container image bundles `texlive-latex-extra`,
   `texlive-fonts-recommended`, `texlive-science`, and `latexmk`. The
   editor's `latexmk` invocations happen inside the container.

4. Start the colony as part of the federation. Cross-colony handoff is
   now direct via the shared memo store; no `--source-*` flags. See
   `research-foundry/tools/run-research.sh --help` for the current
   invocation.
