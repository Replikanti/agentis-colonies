# federation-dashboard

![Version: 0.9.1](https://img.shields.io/badge/version-0.9.1-blue) ![Standalone component](https://img.shields.io/badge/component-standalone-green) ![Status: Beta](https://img.shields.io/badge/status-beta-yellow)

**Version:** `0.9.1` · [Changelog](./CHANGELOG.md) · **Recommended for:** dev-apprenticeship >= `2.0.0` + `--restart-agent` mode in `start-colony.sh`

Generic web dashboard for any [Agentis](https://github.com/Replikanti/agentis)
federation. Auto-discovers colonies and agents from the federation directory,
collects per-agent data from the `agentis` CLI, regenerates a static HTML
page every 60 seconds, and serves it with operator controls (promote, demote,
evolve, restart, kill).

This component is **separately versioned** from the federations it serves
([#252](https://github.com/Replikanti/agentis-colonies/issues/252)). Federations
declare a soft minimum (e.g. `dev-apprenticeship` requires
`federation-dashboard >= 0.8.0`) and the dashboard ships its own release
tarball, install script, and changelog.

## Install

```bash
curl -fsSL -o federation-dashboard.tar.gz \
  https://github.com/Replikanti/agentis-colonies/releases/download/federation-dashboard-v<X.Y.Z>/federation-dashboard-v<X.Y.Z>.tar.gz
tar -xzf federation-dashboard.tar.gz
cd federation-dashboard-v<X.Y.Z>
./install.sh
```

Default install location follows the [XDG Base Directory Specification](https://specifications.freedesktop.org/basedir-spec/basedir-spec-latest.html):

- Files: `${XDG_DATA_HOME:-$HOME/.local/share}/federation-dashboard/`
- Symlink: `${XDG_BIN_HOME:-$HOME/.local/bin}/federation-dashboard` →
  `<data>/bin/federation-dashboard`

If `~/.local/bin` is not on `$PATH`, `install.sh` prints a one-line warning.

## Usage

```bash
federation-dashboard <federation-dir> [port]
federation-dashboard /path/to/dev-apprenticeship
federation-dashboard /path/to/dev-apprenticeship 9000
```

Default port is 8420. The federation directory must contain colony
subdirectories with `agents/*.ag` files.

## Architecture

| File | Purpose |
|------|---------|
| `bin/federation-dashboard` | Entry point — auto-discovers colonies/agents, orchestrates the four Python helpers and the HTTP server. **Never inline heredocs here** (macOS bash 3.2 parser bug). |
| `lib/federation-dashboard-collector.py` | Per-agent data collector (experience stats, `.ag` descriptions, log lines, PID liveness, timeline, confidence history). Also invokes `auto-promote-decisions.py --preview` so the dashboard's Promote Candidates list uses the same math the scheduler uses. |
| `lib/federation-dashboard-history.py` | Snapshot appender (per-colony avg confidence + experience totals) to `history.json`; prunes entries older than 7 days. |
| `lib/federation-dashboard-renderer.py` | Template renderer — substitutes 10 named sentinels into `federation-dashboard.html.template`, atomically writes `index.html`. |
| `lib/federation-dashboard-server.py` | HTTP server + REST endpoints (`/refresh`, `/confidence`, `/restart`, `/quarantine`, `/evolve`, `/cleanup`, `/start`, `/kill`). |
| `lib/federation-dashboard.html.template` | Static HTML/CSS/JS page with `{{SENTINEL}}` placeholders. Edit this file (not the shell or Python) to change markup, styling, or client-side JS. |

State (regenerated `index.html`, `history.json`, `confidence-log.jsonl`,
local sockets) is written into `<fed-dir>/.dashboard/`, never under `$HOME`.

## Federation shared-tools resolution

Some endpoints depend on helpers that ship with the **federation**, not with
the dashboard:

| Helper | Used by | Endpoint / panel |
|--------|---------|------------------|
| `auto-promote-decisions.py` | collector | Promote Candidates panel |
| `auto-promote-config.yaml` | collector | Promote Candidates panel |
| `kill-federation.sh` | server | `POST /kill` |

Restart is handled entirely by the federation side: `POST /restart` (and
the auto-restart after a confidence change) invokes the target colony's
own `scripts/start-colony.sh --restart-agent <name>`, which owns the
forge-specific env wiring (`GITLAB_*`, etc). The dashboard does not
parse `colony.toml` itself and does not need `resolve-tick-interval.py`
— `start-colony.sh` resolves the tick interval for its own respawn.

Resolution order (entry script):

1. `<fed-dir>/tools/<helper>` (federation ships them inside)
2. `<fed-dir>/../tools/<helper>` (sibling layout — `dev-apprenticeship`)

When a helper is not found, the dependent feature degrades gracefully:
- Promote Candidates renders empty.
- `/kill` returns `503` with a clear error.
- Tick interval falls back to `60000` (60s).

The dashboard itself does not crash.

## Compatibility

| federation-dashboard | dev-apprenticeship |
|----------------------|--------------------|
| `>= 0.8.0`           | `>= 2.0.0`         |

Earlier `dev-apprenticeship` versions (`<= 0.3.2`) shipped a vendored copy of
the dashboard inside their own bundle; do not mix that with this standalone
install.

## License

Same as the parent repository (see top-level `LICENSE`).
