# CLAUDE.md

## Project overview

Pre-built agent colonies for the [Agentis](https://github.com/Replikanti/agentis) runtime. The `dev-apprenticeship/` federation contains 5 colonies (21 agents) that learn a developer's workflow by observing how they work on GitLab. All 21 agents implement the full confidence gradient (observe / suggest / act).

## Git workflow

- **Never push directly to main.** Always create a feature branch and open a PR.
- Branch protection is enforced via GitHub rulesets (require PR, no deletion, no force-push).
- Branches are auto-deleted after merge.

## Validation

```bash
./tools/colony-lint.sh          # Full lint (structure, config, syntax, exec-sh safety, daemon flags)
bash -n scripts/gitlab-api.sh   # Bash syntax check on any script
```

Colony lint must pass with 0 failures before merge. Current baseline: 45 passed, 5 skipped (shellcheck not installed).

## Colony structure

Every colony follows this layout:

```
colony-name/
  agents/          # .ag agent files (one per agent)
  config/          # colony.example.toml (copy to colony.toml for local use)
  scripts/         # start-colony.sh, gitlab-api.sh
  README.md        # Agent table, mermaid diagram, setup instructions
```

## Agent conventions (.ag files)

- `cb <N>;` at the top must match the `cb_budget` in colony.example.toml.
- `get_confidence()` reads from `recall_latest("<agent_name>:confidence")`.
- Confidence gradient: < 0.6 observe only, >= 0.6 emit suggestions, >= 0.85 act autonomously.
- `learn()` topic must match the topic in `recommend()` within the same agent.
- `memo_write("<agent_name>:last_check", now)` at the end of every tick.
- All dynamic values in `exec sh` calls must be wrapped in `shell_escape()`.
- If the grep-based linter cannot see through nested `shell_escape()`, add `// colony-lint: safe-exec-concat` on the line above.
- Emit events use `"<colony_name>:<event_name>"` format.

## Script conventions

- `start-colony.sh`: symlink-safe `$0` resolution via python3, sources `tools/parse-toml.sh`, exports `GITLAB_URL`/`GITLAB_TOKEN`/`GITLAB_PROJECT`, launches daemons with `--colony <name> --tick-interval 60000`.
- `gitlab-api.sh`: `emit_error()` for all error messages, `exit 2` for unknown flags, `python3 json.dumps` for all POST/PUT body construction. Read endpoints use `gl_get`/`gl_get_q`, write endpoints use `gl_post`/`gl_put`.

## Federation event wiring

22 colony bus events total: 16 internally wired, 6 extension points (terminal events for external consumption).

Cross-colony events:
- `triage:route_suggestion` -> implementation/code_writer
- `implementation:mr_ready` -> release/release_checker, code-review/approval_decider

Full event-to-consumer mapping:

```
triage:new_issue             -> router, prioritizer, labeler
triage:route_suggestion      -> code_writer (cross-colony)
implementation:code_draft    -> test_writer, refactorer, commit_composer
implementation:test_draft    -> commit_composer
implementation:refactor_suggestions -> commit_composer
implementation:mr_ready      -> release_checker, approval_decider (cross-colony)
review:style_findings        -> approval_decider
review:logic_findings        -> approval_decider
review:security_findings     -> approval_decider
review:test_findings         -> approval_decider
planning:scope_estimate      -> plan_reviewer
planning:risks               -> plan_reviewer
planning:breakdown           -> plan_reviewer
release:check_result         -> ship_decider
release:ship_decision        -> changelog_writer, version_bumper
release:changelog_draft      -> version_bumper
```

6 extension points (no internal listener): `triage:label_suggestion`, `triage:priority_suggestion`, `review:decision_suggestion`, `review:escalation`, `planning:draft_plan`, `release:version_bumped`.

## Confidence keys

| Colony | Keys |
|--------|------|
| triage | `router:confidence`, `prioritizer:confidence`, `labeler:confidence`, `issue_creator:confidence` |
| code-review | `logic_reviewer:confidence`, `style_reviewer:confidence`, `security_reviewer:confidence`, `test_reviewer:confidence`, `approval_decider:confidence` |
| planning | `scope_estimator:confidence`, `risk_assessor:confidence`, `task_decomposer:confidence`, `plan_reviewer:confidence` |
| implementation | `code_writer:confidence`, `test_writer:confidence`, `refactorer:confidence`, `commit_composer:confidence` |
| release | `ship_decider:confidence`, `changelog_writer:confidence`, `version_bumper:confidence`, `release_checker:confidence` |

## Tools

| Tool | Purpose |
|------|---------|
| `colony-lint.sh` | Full federation lint (structure, config, .ag syntax, exec-sh safety, daemon flag allowlist, markdown links) |
| `new-colony.sh` | Scaffold a new colony (creates dirs, example config, starter scripts) |
| `check-exec-sh.sh` | Grep-based check for unsafe string concat into `exec sh`. See `check-exec-sh.md` for known limitations. |
| `parse-toml.sh` | Shared TOML parser sourced by all start-colony.sh scripts |

## End-user scripts (in dev-apprenticeship/)

| Script | Purpose |
|--------|---------|
| `install.sh` | Interactive setup: checks prerequisites, copies configs, writes GitLab credentials, seeds confidence |
| `start-federation.sh` | Starts all 5 colonies (launches 21 daemon processes) |
