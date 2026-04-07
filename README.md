# Agentis Colonies

Agent colonies that learn by watching you work. Built on [Agentis](https://github.com/Replikanti/agentis).

Each colony is a federation of autonomous daemon agents that observe a human operator, learn from their decisions, and gradually take over routine work — starting from passive observation, progressing through suggestion and drafting, to full autonomy on tasks where confidence is high.

## Colonies

### [apprenticeship/](./apprenticeship/) — Software Development Workflow

Six agents that learn a developer's workflow by observing their interactions with GitLab issues, merge requests, and code reviews.

| Agent | Learns |
|-------|--------|
| **QA Reviewer** | Which findings are real vs noise, severity calibration |
| **Plan Reviewer** | Review criteria, common objections, implicit standards |
| **Planner** | Scope preferences, phase count, what gets rejected |
| **Ship Decider** | Ship/no-ship threshold per issue type |
| **Issue Creator** | Formulation style, routing rules, label selection |
| **Implementer** | Code patterns, commit conventions, test patterns |

Each agent starts in **observe** mode and graduates through **suggest → draft → act → autonomous** as its confidence grows from accumulated experience.

## How It Works

```
                    ┌─────────────┐
                    │   Human     │
                    │  (operator) │
                    └──────┬──────┘
                           │ feedback (approve/dismiss/veto)
                    ┌──────▼──────┐
                    │  Colony Bus  │  (emit/listen over TCP)
                    └──────┬──────┘
          ┌────────┬───────┼───────┬────────┐
          ▼        ▼       ▼       ▼        ▼
      ┌───────┐┌───────┐┌─────┐┌──────┐┌────────┐
      │Planner││QA Rev ││Ship ││Issue ││Implmtr │  ...
      │daemon ││daemon ││Dec  ││Creatr││daemon  │
      └───────┘└───────┘└─────┘└──────┘└────────┘
          │        │       │       │        │
          └────────┴───────┴───────┴────────┘
                           │
                    ┌──────▼──────┐
                    │  GitLab API  │  (observed via use_tool)
                    └─────────────┘
```

**Autonomy gradient** — each agent independently decides how to act based on its experience:
- **Confidence < 0.6**: Observe and suggest (human decides)
- **Confidence < 0.85**: Draft and present for approval (human reviews)
- **Confidence ≥ 0.85**: Act autonomously (human can veto)

Confidence grows with correct predictions, decays on stale knowledge.

## Prerequisites

- [Agentis](https://github.com/Replikanti/agentis) runtime (binary)
- GitLab instance with API access
- Claude CLI (used as LLM backend via Agentis CliBackend)

## Quick Start

```bash
# Clone
git clone https://github.com/Replikanti/agentis-colonies.git
cd agentis-colonies/apprenticeship

# Configure
cp config/colony.example.toml config/colony.toml
# Edit colony.toml: set GitLab URL, token, project

# Start the colony
./scripts/start-colony.sh
```

## Knowledge Portability

Knowledge entries are tagged by scope:

- `personal` — developer preferences, quality bar, review criteria. Portable across projects.
- `project:<name>` — codebase-specific patterns, file coupling, false positive patterns. Stays with the project.
- `team:<name>` — shared across team members via federation. (Future)

When onboarding a new project, colonies carry over `personal` knowledge and start fresh on `project:*` — so they already know how you work, they just need to learn the codebase.

## License

Apache 2.0 — see [LICENSE](./LICENSE).

Agentis runtime is proprietary software by [Replikanti](https://github.com/Replikanti).
