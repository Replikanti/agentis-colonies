# hunt-dashboard — read-only live view of a zone-hunt

A localhost-only HTTP dashboard that renders a single dark-factory zone-hunt from its on-disk artifacts. It
regenerates the whole page on every request (the browser auto-refreshes), so it is always fresh with no stale
file. It is **read-only** — it only READS the hunt's output files and serves HTML — and binds `127.0.0.1`
only, never the network.

This is the #1913 **M1** productization of the operator-approved per-hunt dashboard: a verbatim behavioural
port whose only functional change is **config-driven paths** — the hunt root / out dir / run log and the
header chrome (label, reward line, program/repo/project links) come from a descriptor JSON or CLI flags
instead of being hardcoded to one target. Multi-hunt tabs / an overview grid / a registry are **M2** (a
follow-on), not here.

## Run it

```sh
# from a descriptor (recommended):
setsid dark-factory/hunt-dashboard/hunt-dashboard.sh --descriptor my-hunt.json \
    >/tmp/hunt-dashboard.log 2>&1 &
# then open http://127.0.0.1:8420

# or with explicit flags (no descriptor):
dark-factory/hunt-dashboard/hunt-dashboard.sh \
    --root /path/to/hunt --out /path/to/hunt/zone-hunt-out --log /path/to/hunt/hunt.log \
    --label "My target" --bounty-url https://... --repo-url https://...
```

Start it under `setsid` for a long hunt so it outlives the launching shell.

- **Port:** default `8420` (the reference's port). Override with `--port` or `$HUNT_DASHBOARD_PORT`.
- **Host:** pinned to `127.0.0.1`; `--host` exists but loopback is the intended (and safe) binding.

## Descriptor schema

```json
{
  "id": "<slug>",
  "label": "<display name>",
  "root": "<hunt root>",
  "out": "<zone-hunt-out dir>",
  "log": "<top-level run log>",
  "bounty_url": "<optional program URL>",
  "repo_url":   "<optional in-scope repo URL>",
  "project_url":"<optional project URL>",
  "reward_line":"<optional chrome line, e.g. 'Bounty · $1M Crit / $75K High'>"
}
```

`id` / `label` / `root` / `out` / `log` are load-bearing; the rest are optional (an absent link is simply
not rendered — no broken `href`). Relative `root`/`out`/`log` are resolved against the descriptor's own
directory, so a descriptor can ship alongside a hunt tree without host-absolute paths. If only `root` is
given, `out` defaults to `<root>/zone-hunt-out` and `log` to `<root>/hunt.log`.

## What it renders

- **Phases** — the seven pipeline stages grouped into four tracks (`MAP`, `BREADTH · discovery`,
  `DEPTH · deep-hunt`, `DELIVER`); each of the breadth and depth tracks ends in its own refute gate. A
  phase-weighted progress bar.
- **Zones** — execution state + a Result column (💰 marks value-custody zones); the Result agrees with the
  LEADS table (refuted leads, deep findings, triaged FPs).
- **LEADS** — one unified table `Type | Sev | Class | Location | Refute gate | Detail`. Breadth (discovery)
  rows carry a blue `BREADTH` pill and their per-lead refute-gate verdict (survived / refuted / pending);
  depth (STAGE 4.5 deep-hunt) rows carry a purple `DEPTH` pill and the fuzzer's verdict (FINDING / clean /
  harness-error), plus every planned lens row (done / running / queued). Severity is intrinsic to the target
  and shown on every row. A refuted lead, a triaged-FP deep finding, and a CLEAN deep row are struck through;
  an open FINDING and a HARNESS_ERROR (a coverage gap) are not.
- **Liveness** — a pulse that is green only while the hunt is genuinely live (a running hunt process / LLM
  child, detected from `/proc`), amber when quiet, red when the process is gone without an exit marker, and a
  static slate when finished. "Finished" requires BOTH the `__EXIT__` marker AND no live process.
- **Honest completion** — the process-exit marker alone never renders 100%; `HARNESS_ERROR` / `failed` zones
  are excluded from the hunted count, and an incomplete exit renders distinctly from full coverage.

## Offline / test surface

- `--render` emits the HTML once to stdout and exits (no server) — a smoke check.
- `--emit-model` emits the computed facts as JSON (the deterministic assertion surface used by
  `dark-factory/demo-hunt-dashboard.sh`).
- `HUNT_DASHBOARD_FAKE_PROC_ALIVE` / `HUNT_DASHBOARD_FAKE_LLM_INFLIGHT` override the `/proc` liveness scan for
  fixtures only (unset in production → the real scan runs).

## Portability

Live-process detection is Linux-only (`/proc`). On a non-Linux host the `/proc` scan is skipped and liveness
degrades to freshness-only (artifact mtimes); everything else renders unchanged.
