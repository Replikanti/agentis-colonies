# Security

This repo ships agent federations that can — at their highest confidence tier — write to
external systems (open PRs, post review notes, merge, tag, publish releases). This document
describes the safety model, what agents can do autonomously, how secrets are handled, and how
to report a vulnerability.

## Safety model: the confidence-tier ladder

The primary containment mechanism is the four-tier confidence ladder, normative in
[ADR-0001](./doc/adr/ADR-0001-confidence-tiers.md). Every agent starts in `shadow`
(observe-only) and must **earn** each step up through measured experience
([auto-promote](./doc/auto-promote.md) defaults to dry-run; promotion is an explicit
operator-visible decision):

| Tier | External write capability |
|------|---------------------------|
| `dormant` / `shadow` | None. LLM calls + local memo only. |
| `propose` | None direct — emits suggestions on the internal bus, drafts external writes. |
| `review-gated` | Non-terminal external writes (e.g. posting a review note). |
| `autonomous` | Terminal writes (merge, tag, publish) — subject to the additional gates below. |

`colony-lint` enforces that `.ag` code branches on named tiers (never raw confidence
numbers), so the ladder cannot be silently bypassed by a threshold typo.

## Gates on top of the ladder

Terminal actions carry additional, independent gates:

- **Auto-merge is opt-in and self-refusing.** The `merge` verb (the single chokepoint of the
  auto-merge loop) is reachable only at the `autonomous` tier, only when the operator sets
  `auto_merge = true` (default `false`), and refuses unless the PR is cleanly mergeable
  **and** CI is entirely green — an empty or in-progress check list also refuses. See the
  contract in [`CLAUDE.md`](./CLAUDE.md#script-conventions).
- **Planning → implementation promotion is opt-in** (`auto_promote`, default `false`) and
  skips epic-class issues, which stay with the operator.
- **External submissions stay human-gated permanently.** `dark-factory` never auto-posts
  bounty reports; `research-foundry` never auto-submits preprints — its arXiv dispatch
  requires an explicit human approval step.
- **Autonomous issue filing** (the dev-apprenticeship self-observation driver) is behind
  fingerprint dedup and a per-run rate limit, and is off by default.
- **Runtime kill-switches.** The agentis daemon watchdog can degrade an agent to
  `--deny-exec` (which overrides `--enable-exec`), and `kill-federation.sh` provides an
  OS-signal shutdown path that does not depend on the runtime cooperating.

## Command execution and input handling

Agents reach the outside world through `exec sh` calls into thin, reviewed shell verbs
(`forge-api.sh` dispatchers). Conventions enforced by lint:

- every dynamic value interpolated into `exec sh` must pass through `shell_escape()`
  (`tools/check-exec-sh.sh` greps for violations);
- forge API scripts build POST/PUT bodies via `python3 json.dumps`, never string concat;
- repository/token resolution keeps tokens off `argv` so they do not leak into process
  listings.

Issue titles, bodies, and MR descriptions fetched from the forge are untrusted input: they
flow into LLM prompts, so a hostile issue can try to steer an agent's reasoning (prompt
injection). The tier ladder and the terminal-action gates above are the blast-radius bound:
even a fully steered sub-`autonomous` agent cannot write externally, and an `autonomous` one
still cannot merge red CI, bypass the opt-in flags, or submit anywhere a human gate stands.
Run federations against repos whose issue traffic you trust, or keep write-capable agents
below `autonomous`.

## Secrets handling

- Credentials (forge tokens, LLM keys) live in each colony's local `colony.toml` (copied
  from `colony.example.toml` by `install.sh`) and in the git-ignored `.agentis/` state
  directory (e.g. `.agentis/secrets/`). Neither is committed; only `*.example.toml`
  templates are tracked.
- Tokens reach agents via environment variables exported by `start-colony.sh`, not via
  command-line arguments.
- Verify-gate output in the code-edit pipeline is token-scrubbed before it is fed back into
  an LLM prompt.
- Scope tokens minimally: the dev-apprenticeship federation needs API access to the target
  project only. Prefer project-scoped tokens over account-wide ones.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting ("Report a vulnerability" under this
repository's **Security** tab) rather than a public issue, especially for anything that
could let an agent escape its tier gates, leak credentials, or write externally without the
documented opt-ins. Reports that affect the proprietary Agentis runtime will be routed to
the runtime maintainers through the same channel.
