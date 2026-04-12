# CLAUDE.md

## Project overview

Pre-built agent colonies for the [Agentis](https://github.com/Replikanti/agentis) runtime. The `dev-apprenticeship/` federation contains 5 colonies (21 agents) that learn a developer's workflow by observing how they work on GitLab.

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

## Tools

| Tool | Purpose |
|------|---------|
| `colony-lint.sh` | Full federation lint (structure, config, .ag syntax, exec-sh safety, daemon flag allowlist, markdown links) |
| `new-colony.sh` | Scaffold a new colony (creates dirs, example config, starter scripts) |
| `check-exec-sh.sh` | Grep-based check for unsafe string concat into `exec sh`. See `check-exec-sh.md` for known limitations. |
| `parse-toml.sh` | Shared TOML parser sourced by all start-colony.sh scripts |
