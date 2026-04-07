# Apprenticeship Colony — Software Development Workflow

A federation of six autonomous agents that learn a developer's software development workflow by observing their interactions with GitLab.

## Agents

| Agent | File | Observes | Autonomy starts on |
|-------|------|----------|-------------------|
| QA Reviewer | `agents/qa_reviewer.ag` | MR review findings, approve/dismiss decisions | ~10 observations |
| Plan Reviewer | `agents/plan_reviewer.ag` | Plan feedback, revision patterns | ~15 observations |
| Planner | `agents/planner.ag` | Plan approvals/rejections, scope preferences | ~20 observations |
| Ship Decider | `agents/ship_decider.ag` | Merge/reject decisions, blocker patterns | ~15 observations |
| Issue Creator | `agents/issue_creator.ag` | Issue formulation, routing, labeling | ~10 observations |
| Implementer | `agents/implementer.ag` | Code patterns, commit style, test patterns | ~30 observations |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Configure your GitLab connection:
   ```toml
   [gitlab]
   url = "https://gitlab.example.com"
   token = "glpat-..."
   project = "your-org/your-project"
   ```

3. Configure the LLM backend:
   ```toml
   [llm]
   backend = "cli"
   command = "claude"
   ```

4. Start the colony:
   ```bash
   ./scripts/start-colony.sh
   ```

## Providing Feedback

The colony learns from your feedback. Two mechanisms:

### File drop (recommended)
```bash
# Approve a QA finding
echo '{"action": "approve", "finding": "missing-nil-check", "outcome": "real"}' \
  > .agentis/inbox/qa_reviewer/$(date +%s).json

# Dismiss a QA finding
echo '{"action": "dismiss", "finding": "sql-injection-ar-scope", "outcome": "false_positive"}' \
  > .agentis/inbox/qa_reviewer/$(date +%s).json
```

### CLI
```bash
agentis colony send qa_reviewer human_verdict '{"action": "approve", "finding": "missing-nil-check"}'
```

## Monitoring

```bash
# Colony status
agentis colony status

# Watch a specific agent's log
tail -f .agentis/logs/qa_reviewer.log
```

## Knowledge

After running for a while, inspect what the colony has learned:

```bash
# List all knowledge entries
agentis knowledge list

# Export personal knowledge (portable to other projects)
agentis knowledge export --tags personal > my-preferences.json

# Import on a new project
agentis knowledge import my-preferences.json --merge
```
