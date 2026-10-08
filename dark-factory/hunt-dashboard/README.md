# hunt-dashboard — read-only live view of a zone-hunt

A localhost-only HTTP dashboard that renders a single dark-factory zone-hunt from its on-disk artifacts. It
regenerates the whole page on every request (the browser auto-refreshes), so it is always fresh with no stale
file. It is **read-only** — it only READS the hunt's output files and serves HTML — and binds `127.0.0.1`
only, never the network.

It runs in two modes on the same fixed port:

- **Single-hunt (#1913 M1)** — a verbatim behavioural port of the operator-approved per-hunt dashboard whose
  only functional change is **config-driven paths**: the hunt root / out dir / run log and the header chrome
  (label, reward line, program/repo/project links) come from a descriptor JSON or CLI flags instead of being
  hardcoded to one target.
- **Multi-hunt (#1913 M2)** — an **overview → detail** view of every hunt registered under a descriptor
  registry, so one server tracks a whole intake queue. See [Multi-hunt](#multi-hunt-overview--detail-m2).

## Run it — single hunt

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
  `DEPTH · deep-hunt`, `DELIVER`); each of the breadth and depth tracks ends in its own refute gate. Each
  phase shows `checked/total` over its row set (see [Completeness](#completeness-2298)) and a phase-weighted
  progress bar.
- **Zones** — execution state + a Result column (💰 marks value-custody zones); the Result agrees with the
  LEADS table (refuted leads, deep findings, triaged FPs).
- **LEADS** — one unified table `Type | Sev | Class | Location | Refute gate | Detail`. Breadth (discovery)
  rows carry a blue `BREADTH` pill and their per-lead refute-gate verdict (survived / refuted / pending);
  depth (STAGE 4.5 deep-hunt) rows carry a purple `DEPTH` pill and the fuzzer's verdict (FINDING / clean /
  harness-error, keeping the raw token — `TRANSIENT_ERROR`, `LOW_COVERAGE`, ...), plus every row of the
  runner's plan (`<out>/deep-hunt/plan.json`): running / queued / not run / `⏸️ capped`. The DEPTH rows come
  from that plan only — the dashboard never re-derives the lens selection. Severity is intrinsic to the target
  and shown on every row: for a not-yet-run row this is the zone's value-custody classification (High) where
  known; a row with no resolvable custody signal still shows an em-dash. A refuted lead, a triaged-FP deep
  finding, and a CLEAN deep row are struck through; an open FINDING and a HARNESS_ERROR (a coverage gap) are
  not.
- **Liveness** — a pulse that is green only while the hunt is genuinely live (a running hunt process / LLM
  child, detected from `/proc`), amber when quiet, red when the process is gone without an exit marker, and a
  static slate when finished. "Finished" requires BOTH the `__EXIT__` marker AND no live process.

## Completeness (#2298)

The operator reads `100%` / `DONE` as "the hunt is finished". So nothing on the page, in `--emit-model` or on
an overview card claims it while any row is open. One model (`hunt_model()`) feeds every indicator: the bar and
its `%`, the banner, the `DONE` sub-line, the phase ✅, the zone ✅, `FINISHED` / "finished — verdict in chat",
and the overview card.

- **Checked row** — a row is *checked* only when its rendered state is terminal. Everything else is
  *unchecked*: queued, running, re-running, not run, capped, harness / transient error, low coverage,
  abandoned, plan unknown, deep-hunt skipped, pending refute, awaiting an operator verdict, a failed or
  degraded zone, a failed deliver row.
- **Phase `done`** — only when the phase has started, all its rows are checked and its upstream phase is
  `done` (or `skip`).
- **Header complete** — `DONE`, `100%` and "finished — verdict in chat" only when the runner exited AND every
  phase is `done` or `skip`. Otherwise progress is clamped to `<= 99` and rendered with `int()`, so `99.6`
  can never print as `100%`.

| Phase | Rows | Checked when |
|---|---|---|
| M1 map | `map/zones.json` | it parses as a non-empty list (or a zone already left `not_reached`) |
| M2 briefs | one per mapped zone | `briefs/briefs/brief_<id>.md` exists (or discovery already reached the zone) |
| M3 discovery | the Zones table rows | status `hunted` / `hunted_empty` |
| M4 refute | every grouped breadth lead (sub-floor rows included) | the lead is no longer pending |
| 4.5 deep-hunt | plan rows ∪ observed `deep-hunt/*/` dirs ∪ one synthetic row for a skipped / legacy run | the report verdict is FINDING or CLEAN |
| 4.6 refute deep | DEPTH rows with a FINDING | an **operator** verdict, or the automated 4.6 gate `REFUTED` |
| deliver | rows of `.verified-findings.tsv` | a `staged` / `halted` row in `audit-pass/deliver-status.tsv` |

Upstream: M2 ← M1, M3 ← M2, M4 ← M3, 4.5 ← M1, 4.6 ← 4.5, deliver ← M4 + 4.6. A phase renders `➖ skip` only
on runner evidence: 4.5 / 4.6 when the run reached M5 with no deep-hunt plan, dir or log marker (run without
`--deep-hunt`); deliver when the plan says `deep_hunt_only` (M5 never runs in that mode).

- **Capped rows** — a lens `--deep-hunt-max-lenses` cut is a `⏸️ capped` row. It blocks `DONE` / `100%` of 4.5
  and of the header; re-run with a higher cap + `--deep-hunt-resume` to clear it. A `--deep-hunt-max-targets`
  cut is not a row of its own.
- **Operator verdict for deep findings** — a FINDING that **survived** the automated 4.6 gate (`REAL`) is not a
  verdict; it renders "survived refute gate (4.6) · needs forge PoC" and stays unchecked until the operator adds
  a row to `<root>/deep-hunt-adjudicated.tsv`:
  `<target-file>\t<class>\t<CONFIRMED|DUPLICATE|REFUTED>\t<reason>` (`FP` is accepted as an alias of
  `REFUTED`; class `*` applies to any lens class on that file). The automated gate's `REFUTED` checks the row
  too; its `ERROR` does not.
- **Legacy out dirs** — an out dir written before `deep-hunt/plan.json` existed cannot prove its DEPTH row set:
  it renders a "plan unknown" row and stays `STOPPED INCOMPLETE <= 99%`, and an out dir without
  `audit-pass/deliver-status.tsv` keeps its deliver rows open. This is intended.
- **Zones** — a zone reads ✅ only when its M3 row, its leads and its DEPTH rows are all checked; otherwise it
  shows `hunted · N open` (🔄 while the hunt is live, ⚠️ once it exited).
- `--emit-model` adds `phase_rows` (`{total, checked, unchecked: [labels]}` per phase), `open_rows`,
  `deep_mode` (`planned | skipped | legacy | off | pending`), a `checked` flag on every `deep_rows` entry and
  `deep_summary = {planned, checked, capped, findings}`. `dark-factory/demo-hunt-dashboard-completeness.sh`
  pins the invariant.

## Multi-hunt (overview → detail) [M2]

Invoked with **neither** a descriptor nor path flags (or with `--registry`), the dashboard serves a multi-hunt
view over a descriptor **registry**, so one server on the single fixed port tracks a whole intake queue:

```sh
# create the opt-in registry dir once, then launch the multi-hunt server:
mkdir -p "${DARK_FACTORY_DIR:-$HOME/.dark-factory}/hunts"
setsid dark-factory/hunt-dashboard/hunt-dashboard.sh >/tmp/hunt-dashboard.log 2>&1 &
# then open http://127.0.0.1:8420
```

- **Landing = an overview grid** — one clickable card per registered hunt: label, an optional bounty link, a
  mini progress bar + %, the live status dot (working / quiet / stalled / process-gone / done, re-derived
  live), and a compact `zones X/Y · N leads · K deep FINDING` summary (plus `· N open rows` while incomplete).
  A finished hunt's card is a static slate; a live one pulses. The card's `%` and `FINISHED` follow the same
  [completeness](#completeness-2298) model as the detail page.
- **Click a card → that hunt's full detail dashboard** (the single-hunt view above), routed via `?hunt=<id>`
  (bookmarkable). The detail view carries a `← overview` control and a compact hunt-switcher pill row.
- **Registry** — `${DARK_FACTORY_DIR:-$HOME/.dark-factory}/hunts/<id>.json`, each descriptor using the schema
  above. Discovery reads the dir best-effort (a malformed file is skipped); **liveness and every artifact are
  always re-derived live** — descriptors carry static metadata only. A missing/empty registry dir renders a
  graceful empty overview, never a crash. Override the dir with `--registry-dir`.
- **Automatic registration** — `run-zone-hunt.sh` registers each hunt's descriptor at launch **only when the
  registry dir exists** (create it to opt in). The write is atomic (`tmp` + `mv`); with the dir absent the
  launch writes nothing and is byte-identical to before.

## Offline / test surface

- `--render` emits the HTML once to stdout and exits (no server) — a smoke check. In registry mode it emits
  the overview page; add `--hunt <id>` for one hunt's detail page.
- `--emit-model` emits the computed facts as JSON (the deterministic assertion surface used by
  `dark-factory/demo-hunt-dashboard.sh`, `demo-hunt-dashboard-multi.sh` and `demo-hunt-dashboard-completeness.sh`). In registry mode it emits the
  overview model; add `--hunt <id>` for one hunt's detail model.
- `HUNT_DASHBOARD_FAKE_PROC_ALIVE` / `HUNT_DASHBOARD_FAKE_LLM_INFLIGHT` override the `/proc` liveness scan for
  fixtures only (unset in production → the real scan runs). A per-hunt suffix
  (`HUNT_DASHBOARD_FAKE_PROC_ALIVE_<ID>`) scopes the override to one registry hunt, so a fixture registry can
  render a finished card and a live card in the same overview.

## Portability

Live-process detection is Linux-only (`/proc`). On a non-Linux host the `/proc` scan is skipped and liveness
degrades to freshness-only (artifact mtimes); everything else renders unchanged.
