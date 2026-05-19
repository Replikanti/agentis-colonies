# Auto-promote / auto-evolve reference

`tools/auto-promote.sh` is the layer-1 scheduler script that promotes agents up
the four-tier confidence ladder (shadow → propose → review-gated →
autonomous) when their fitness signal clears a statistical bar, or
triggers `agentis evolve` when the signal degrades. This document is the
reference for how the decision is made, what the thresholds mean, and
how to audit what the scheduler did.

Scheduling is installed by `dev-apprenticeship/install.sh` (§7). The
sidecar that invokes this script is spawned by `start-federation.sh`
when `.auto-promote-install.toml` has `enabled = true`; it dies when
the federation is torn down, so no scheduling state lingers after
`kill-federation.sh`. See [#216](https://github.com/Replikanti/agentis-colonies/issues/216) for the design rationale.

For the tier boundaries themselves, see
[ADR-0001: Four-tier confidence contract](./adr/ADR-0001-confidence-tiers.md).

## Scope

- **Included:** experience-store classification, fitness computation,
  promote/evolve/skip decision table, journal format, per-federation
  tuning.
- **Excluded:** the four-tier semantic contract (in ADR-0001), the
  `tier()` builtin semantics (in the agentis runtime docs), and the
  dashboard UI for manual promotion (federation-dashboard).

## Decision table (DMN)

For each running agent, the scheduler evaluates a conjunctive decision rule
against the agent's experience rows, runtime state, and configured
thresholds. All inputs must evaluate `true` for a `promote` outcome;
any `false` leads to `skip` with the failed criteria listed in the
journal. `evolve` takes priority over `promote` when the agent is
degrading (see _Evolve trigger_ below).

### Inputs

| Input | Source | Meaning |
|---|---|---|
| `entries_total` | count of rows in `.agentis/experience/<agent>.jsonl` | total experience rows, any tag |
| `entries_acting` | count where row `tags` contain `acted`, `review-gated`, `emitted`, or `replicated` | rows from tier-gated acting branches |
| `runtime_hours` | `now - daemon.started_at` | daemon age |
| `reject_rate_acting` | acting rows with `verdict == reject` or `outcome == reject` or `rejected == true` / `entries_acting` | reject rate on acting rows only |
| `delta_slope_acting` | linear-regression slope of `delta` over the last `delta_slope_window` acting rows | short-window delta trend on acting rows |
| `confidence` | `recall_latest("<agent>:confidence")` | current tier anchor |

### Rules (promote)

| `entries_total ≥ min_entries` | `entries_acting ≥ effective_min_acting` | `runtime_hours ≥ min_runtime_hours` | `reject_rate_acting < reject_rate_threshold` | `delta_slope_acting ≥ delta_slope_min` | → |
|:---:|:---:|:---:|:---:|:---:|:---:|
| true | true | true | true | true | **promote** |
| _any false_ | | | | | skip |

`effective_min_acting = step.min_acting_entries_override if set else global.min_acting_entries`.

When `effective_min_acting == 0` (shadow → propose step), the two
fitness gates (`reject_rate_acting`, `delta_slope_acting`) are **not
evaluated**, because both are undefined on zero acting rows. See
[Bootstrap exception](#bootstrap-exception-shadow--propose).

### Rules (evolve)

Evaluated before promote. If true, emit `evolve` and skip promote check.

| `entries_acting ≥ evolve.trigger.delta_slope_negative_for` AND `evolve_slope < 0` | `entries_acting > 0` AND `reject_rate_acting > evolve.trigger.reject_rate_above` | → |
|:---:|:---:|:---:|
| true | _don't care_ | **evolve** |
| _don't care_ | true | **evolve** |
| false | false | fall through to promote rules |

`evolve_slope` is computed like `delta_slope_acting` but over a longer
window (default 1000 acting rows).

## Classification

Every row in the experience store carries a `tags` array (see the
canonical `.ag` pattern in [CLAUDE.md](../CLAUDE.md#agent-conventions-ag-files)).
The scheduler classifies each row into one of three tag buckets:

| Bucket | Match | Example tag set |
|---|---|---|
| **acting** | contains `acted` OR `review-gated` OR `emitted` OR `replicated` | `["acted", "triage"]`, `["emitted", "triage"]`, `["review-gated", "code-review"]`, `["replicated", "math-foundry"]` |
| **observe** | contains `observed` (and no acting tag) | `["observed", "triage"]` |
| **legacy** | neither (or no `tags` field) | `[]`, missing field |

Acting-tag breakdown:

| Tag | Tier | Meaning |
|---|---|---|
| `emitted` | propose | emit on bus + draft external writes |
| `review-gated` | review-gated | direct external writes (non-terminal) |
| `acted` | review-gated / autonomous | tier-gated acting branch fired |
| `replicated` | autonomous | acted by autonomous-tier daemon (replicate fired) — emitted by tribes-bench hunters + math-foundry / research-foundry explorer + Phase 9 PR-C colonies on a successful M2-Malthusian replicate. Replicate-failure tags (`replicate-skip`, `replicate-error`, `replicate-nak`) stay in the `legacy` bucket so failed-replicate rows do not pad `entries_acting`. |

Rationale: observe-step `learn()` calls are hardcoded to `outcome:
"success"` by the canonical pattern. Including them in fitness stats
would bias `reject_rate` toward zero regardless of actual acting
quality. Only tier-gated acting rows carry meaningful success / reject
signal.

## Per-step rationale

The three promote steps align with the ADR-0001 tier boundaries. Each
step has a different risk profile and therefore a different fitness
bar.

### `0.4 → 0.6` (shadow → propose)

**`min_acting_entries_override: 0`** (bootstrap, required).

Shadow-tier `.ag` branches never reach an acting path — the canonical
pattern gates emit / draft / direct writes on `tier == "propose"` or
higher. An agent at confidence 0.4 therefore has `entries_acting = 0`
by construction. Requiring any positive number would make the first
promotion unreachable, leaving all fresh agents stranded in shadow.

With the override, the first step effectively checks only
`entries_total ≥ 200` and `runtime_hours ≥ 48`: has the agent ticked
long enough to accumulate observation data? The fitness gates
(`reject_rate`, `delta_slope`) are not evaluated here.

### `0.6 → 0.8` (propose → review-gated)

**Uses global `min_acting_entries` (default 60).**

Propose-tier agents emit suggestion events (tag `emitted`), which count
as acting rows. Promoting into review-gated means the agent starts
doing direct non-terminal writes, so `reject_rate` on the acting path
becomes a meaningful gate.

### `0.8 → 0.95` (review-gated → autonomous)

**`min_acting_entries_override: 120`** (stricter).

Autonomous agents do terminal writes (merge, tag, publish) without a
review gate. The acceptance bar should be stricter than for
review-gated.

The override is derived by halving the tolerable reject rate
(`0.05 → 0.025`) and re-applying rule-of-three:
`ceil(3 / 0.025) = 120`. An agent promoted with 120 clean acting rows
has a 95% CI upper bound of 2.5% on its reject rate — half the nominal
threshold. The `reject_rate_threshold` itself is unchanged; the extra
safety margin comes entirely from requiring more acting rows before
crossing this boundary.

## Formula

The default `min_acting_entries` is derived from
`reject_rate_threshold` using rule-of-three:

```
min_acting_entries = ceil(3 / reject_rate_threshold)
```

**Rationale.** With `N` trials and 0 observed failures, the 95%
confidence interval upper bound for the true failure rate is
approximately `3 / N`. Setting `3 / N = reject_rate_threshold` means
an observed zero reject rate is statistically consistent with the
acceptance criterion at 95% confidence; fewer rows would leave the
statistical gap open, more rows would over-demand evidence.

At the default `reject_rate_threshold = 0.05`, this yields
`min_acting_entries = 60`.

If an operator tunes `reject_rate_threshold`, the acting floor scales
automatically: lowering the threshold to 0.02 raises the default floor
to 150; raising it to 0.10 drops the floor to 30. The two thresholds
stay statistically consistent without manual re-tuning.

## Bootstrap exception (shadow → propose)

Shadow-tier agents cannot produce acting rows, so the fitness gates
(`reject_rate_acting`, `delta_slope_acting`) are not evaluated for the
first promote step. This is wired by the `min_acting_entries_override:
0` config on the step, which the scheduler reads as "no acting floor; and
since acting count is zero, the ratio-based gates are also skipped".

The skip is explicit, not silent. The journal records
`min_acting_entries_effective: 0` in evidence, and the reject /
delta-slope gates are simply not listed in `fails`. An operator
reviewing the journal sees at a glance that the first step used the
bootstrap exception, not a malformed config.

## Journal format

Every scheduler run appends one JSON line per agent to
`tools/auto-promote-journal.jsonl`:

```json
{
  "ts": 1776538800,
  "ts_iso": "2026-04-18T19:00:00Z",
  "agent": "risk_assessor",
  "decision": "skip",
  "dry_run": true,
  "evidence": {
    "entries_total": 425,
    "entries_acting": 0,
    "entries_observe": 425,
    "entries_legacy_untagged": 0,
    "runtime_hours": 96.3,
    "reject_rate_acting": 0.0,
    "delta_slope_acting": 0.0,
    "evolve_slope": 0.0,
    "confidence": 0.8,
    "pid": 12345,
    "min_acting_entries_effective": 120
  },
  "from": 0.8,
  "to": 0.95
}
```

### Reading skip reasons

`decision: "skip"` always carries a `reason` string listing failed
criteria:

```json
"reason": "prerequisites not met: entries_acting=0 < 120; delta_slope_acting=0.000000 < 0"
```

One line per failed criterion, separated by `; `. The scheduler collects
every failure (not just the first) so the journal shows complete
evidence. `skip` rows also include `evidence` and `from` / `to` so an
operator can compute the next-step bar without re-reading the source.

### Reading promote / evolve rows

`decision: "promote"` rows include `from` / `to` (step just taken) and
`evidence` at the moment of promotion. `decision: "evolve"` rows
include `evidence` and a `reason` identifying which trigger fired
(slope or reject rate).

## Operator override

The scheduler is one path to promotion; operators can promote manually via
the federation dashboard's Promote button on any agent card. That path
does **not** consult `auto-promote-config.yaml` — it writes
`<agent>:confidence` directly and restarts the daemon. Use it when:

- You want to promote an agent outside the scheduler's `steps` ladder (e.g.
  jump from 0.6 to 0.95 for a controlled test).
- The fitness signal hasn't accumulated yet but you trust the agent
  from independent review.
- You need to demote an agent that's misbehaving (dashboard exposes
  the same slider for negative moves).

The auto-promote journal does not record manual dashboard actions; the
dashboard has its own audit trail (see the federation-dashboard
timeline).

## Dry-run and --live

`dry_run: true` in config (the default) logs decisions to the journal
but does not write to memo or restart daemons. Flip to `false` only
after reviewing a few scheduler runs' worth of journal entries.

`./tools/auto-promote.sh <fed> --live` overrides `dry_run` for one run,
irrespective of config. Useful for one-off "actually promote now" from
a shell, bypassing the installed scheduler's dry-run-preserving loop.

## Per-federation tuning

The config in `tools/auto-promote-config.yaml` ships defaults calibrated
for a small long-running federation (dev-apprenticeship scale: ~20
agents, ~1 tick/minute). Different federations may need different
values:

- **Fast-tick federations** (tick every few seconds): lower
  `min_runtime_hours` (the agent will accumulate the 200-row entries
  floor much faster than 48h).
- **Higher-risk workloads**: lower `reject_rate_threshold` (and the
  acting floor scales up automatically via the formula).
- **Larger federations**: the defaults scale linearly; no change
  needed.

The config is not federation-scoped today — it lives alongside the
tool. A future extension could support per-federation overrides via a
YAML include, but the use case hasn't surfaced yet.

## Prerequisites

- `agentis >= 1.4.1`. Earlier versions hardcoded `fitness_delta: 0.0`
  in `learn()`, so `delta_slope_acting` would be a no-op. v1.4.1
  shipped the fix that populates `fitness_delta` from the `outcome`
  argument (Success=+0.15, Failure=-0.15, etc.). See #542 (core) and
  #191 (MIN_VERSION bump in `install.sh`).
- `python3` with either PyYAML or the fallback regex parser baked into
  the script (no external install needed for the fallback path).
- `flock(1)` for the lock file.

## Related

- [ADR-0001: Four-tier confidence contract](./adr/ADR-0001-confidence-tiers.md) — tier boundary rationale.
- [#148](https://github.com/Replikanti/agentis-colonies/issues/148) — auto-governance roadmap, layers 1-3.
- [#186](https://github.com/Replikanti/agentis-colonies/issues/186) — tag-based classification fix (this document's origin).
- [#163](https://github.com/Replikanti/agentis-colonies/issues/163) — related dashboard flat-slope threshold calibration.
- `tools/auto-promote.sh` — the scheduler script itself.
- `tools/auto-promote-config.yaml` — threshold configuration.
- `tools/auto-promote-journal.jsonl` — audit log (created on first run).
