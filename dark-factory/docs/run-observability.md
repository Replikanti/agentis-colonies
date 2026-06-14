# Observing a one-shot dark-factory run (`run-summary.sh`)

dark-factory runs **one-shot** via `agentis go` (`run-discovery.sh`, `run-audit.sh`): there are no
long-lived daemons and no per-agent `*:confidence` memos. The standalone `federation-dashboard`
component, by contrast, assumes **daemon-tick agents with confidence-tier memos** (the
dev-apprenticeship model), so it has nothing to poll on a one-shot run (issue #995).

`run-summary.sh` closes that gap **on the dark-factory side**, without touching the
`federation-dashboard` component. After a run it distills the run's on-disk artifacts — the agentis
**experience log** (`learn()` outcomes, the ground truth for per-class fitness) and the run **report**
— into one stable JSON file at `<out>/run-summary.json` that any monitor or dashboard can poll. It
only **reads** what the run already wrote: it never mutates the run store and never contacts a bounty
platform.

## Produce a summary

Run it after a discovery / audit run, pointed at the **same `--out` dir**:

```bash
# 1. a one-shot discovery run
dark-factory/run-discovery.sh --repo "$PWD/target" --scope scope.tsv --brief brief.md \
    --out "$PWD/discovery-out"   # default backend = flat-cyborg (flat-rate); add --backend claude for metered -p

# 2. distill it into a monitor-consumable summary
dark-factory/run-summary.sh --out "$PWD/discovery-out"
#   -> writes discovery-out/run-summary.json   (kind auto-detected: discovery | audit)

# optional: also print the JSON to stdout (stdout is pure JSON — pipe it to jq)
dark-factory/run-summary.sh --out "$PWD/discovery-out" --json | jq .verdict

# optional: append one NDJSON line per run to discovery-out/events.jsonl for a tailing monitor
dark-factory/run-summary.sh --out "$PWD/discovery-out" --emit-event
```

`--kind discovery|audit|auto` overrides the shape; `auto` (default) picks `discovery` when the dir
has a `discovery-report.md`, else `audit` when `run/audit.log` exists.

## JSON schema (`dark-factory/run-summary@1`)

```jsonc
{
  "schema": "dark-factory/run-summary@1",
  "kind": "discovery",                       // discovery | audit
  "out": "/abs/path/to/discovery-out",       // the run dir this summary describes
  "generated_at": "2026-06-13T17:59:15Z",    // when this summary was built (UTC)
  "last_run_at":  "2026-06-13T17:53:44Z",    // freshest experience-row ts, else report mtime
  "verdict": "SAFE",                         // discovery: LEADS | SAFE | UNKNOWN; audit: VERIFIED | ... 
  "cells_run": 2,                            // discovery: (subsystem x class) cells; audit: null
  "candidates_found": 0,                     // discovery: unverified leads surfaced; audit: null
  "learn": {                                 // learn() outcomes, read from .agentis/experience/*.jsonl
    "total": 2,
    "by_outcome": { "success": 0, "failure": 2, "partial": 0, "timeout": 0, "error": 0 },
    "outcomes": [                            // one compact record per learn() row (the run's activity)
      { "action": "hunt", "class": "C8",  "subsystem": "vault core", "in": "C8:vault core",
        "outcome": "failure", "ts": 1781373223882 }
    ]
  },
  "classes": [                               // per-(bug)class roll-up, sorted by class id
    { "class": "C8", "attempts": 1, "success": 0, "failure": 1, "fitness": 0.0 }
  ],
  "report": "/abs/path/discovery-out/discovery-report.md"   // the human report, or null
}
```

### Field semantics a consumer relies on

| Field | Meaning |
|-------|---------|
| `verdict` | **discovery**: `LEADS` when `candidates_found > 0` (unverified leads — each must clear `forge-verify.sh`), `SAFE` for a rigorous negative (nothing submitted), `UNKNOWN` if the report footer was unparseable. **audit**: the run's `Verdict:` line (e.g. `VERIFIED`). |
| `cells_run` / `candidates_found` | Parsed from the discovery report footer (`Cells run: N  Candidates surfaced: M`). `null` for the audit shape. |
| `learn.by_outcome` | Count of `learn()` rows per runtime outcome enum (`success`/`failure`/`partial`/`timeout`/`error`). For the discovery hunter a surfaced candidate is `success`, a rigorous `SAFE` is `failure` (so fitness rewards the classes that actually produce leads). |
| `classes[].fitness` | **Per-class fitness = `success / attempts`** on this run — the observable yield of a hunt class. A class that surfaces leads scores high; a class that only ever returns `SAFE` scores `0`. Same "fitness on acting rows" notion as `tools/auto-promote.sh`. A monitor ranks / reweights classes on this. |
| `last_run_at` | The newest experience-row timestamp (epoch-ms → UTC), so a monitor can show run freshness and detect a stale `--out`. Falls back to the report file mtime, then `generated_at`, when there is no experience log (e.g. a run with `learning.enabled = false`). |

The experience log is keyed by the agent **identity** (the branch, e.g. `main`), not the literal
agent name — so `agentis experience summary hunter` finds nothing. `run-summary.sh` reads the raw
`.agentis/experience/*.jsonl` the run wrote directly, which is the stable contract.

## How a monitor / dashboard consumes it

The file is a single self-describing JSON document — no daemon, no confidence keys, no
`federation-dashboard` changes required. Three integration shapes, cheapest first:

1. **Poll the file.** A dashboard tile / CI step reads `<out>/run-summary.json` and renders
   `verdict`, `cells_run`, `candidates_found`, the `learn.by_outcome` mix, and the per-class
   `fitness` table. `last_run_at` drives a "stale run" indicator. This is the parallel to the
   dashboard's daemon-agent stat tiles, sourced from a one-shot artifact instead of live memos.

   ```bash
   # a poller fragment: surface the verdict + lead count + freshest class
   jq -r '"\(.verdict)  cells=\(.cells_run)  leads=\(.candidates_found)  since=\(.last_run_at)"' \
       discovery-out/run-summary.json
   jq -r '.classes | sort_by(-.fitness)[0] | "top class \(.class) fitness \(.fitness)"' \
       discovery-out/run-summary.json
   ```

2. **Tail the event stream.** Pass `--emit-event` and the run appends one
   `{"event":"dark-factory:run_summary", ...}` line to `<out>/events.jsonl`. A monitor that tails
   per-run event files (the same NDJSON discipline as the colony's `dark-factory:hunt_result`
   bus emits) picks up each completed run without re-reading the whole JSON. The line carries
   `verdict`, `cells_run`, `candidates_found`, and `learn_total`.

3. **Aggregate across runs.** Collect many `run-summary.json` files (one per `--out`) into a fleet
   view — e.g. sum `candidates_found`, average per-class `fitness` across targets to see which bug
   classes pay off — entirely with `jq`, no runtime coupling.

## Stability contract

- `schema` is versioned (`dark-factory/run-summary@1`). Additive fields keep the `@1` tag; a
  removal / rename bumps it.
- The JSON is built with `python3` `json.dumps` (sorted keys, 2-space indent) per the repo
  convention — never hand-string JSON.
- With `--json`, **stdout is the JSON and nothing else** (diagnostics go to stderr), so
  `run-summary.sh --out … --json | jq …` is safe.
