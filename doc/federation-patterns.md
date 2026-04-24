# Federation patterns

Sketches of federations beyond `dev-apprenticeship/` to demonstrate
that the [federation portability contract](./adr/ADR-0003-federation-portability-contract.md)
holds across domains. **Patterns only — no code.** Each entry
describes a plausible federation, its colony decomposition, the bus
events that cross colony boundaries, and what the `autonomous` tier
([ADR-0001](./adr/ADR-0001-confidence-tiers.md)) would do at the top
of the gradient. Use these as starting points if you are scaffolding
a new federation; treat the colony names and event names as
illustrative, not normative.

The contract is the same in every case: `<federation>/VERSION`,
`<federation>/CHANGELOG.md`, `<federation>/<colony>/agents/*.ag`,
`<colony>/scripts/start-colony.sh` conforming to ADR-0003. What
changes per pattern is the data source, the agent specialisation, and
the terminal-action vocabulary.

## Index

- [data-ops — ingestion + anomaly + alerting](#data-ops--ingestion--anomaly--alerting)
- [research — paper triage, citation mapping, summarisation](#research--paper-triage-citation-mapping-summarisation)
- [support-triage — ticket routing + draft replies + escalation](#support-triage--ticket-routing--draft-replies--escalation)
- [monitoring-ops — metric watch + runbook suggest + incident draft](#monitoring-ops--metric-watch--runbook-suggest--incident-draft)

---

## data-ops — ingestion + anomaly + alerting

A federation that watches data pipelines and surfaces issues before
the on-call dashboard does. Reads from a metrics warehouse + the
pipeline orchestrator's API; writes to an alerting channel + a runbook
annotation store.

### Colony decomposition (sketch)

| Colony | What it watches | Representative agents |
|--------|-----------------|------------------------|
| `ingestion` | Pipeline run logs, row counts, schema drift | `row_count_watcher`, `schema_drift_spotter`, `late_run_detector` |
| `detection` | Time-series metrics, baseline deviations | `anomaly_spotter`, `seasonality_classifier`, `baseline_recalibrator` |
| `alerting` | Alert routing, dedup, escalation | `alert_router`, `dedup_correlator`, `severity_classifier` |
| `annotation` | Post-incident note drafting against the runbook store | `runbook_linker`, `note_drafter` |

### Cross-colony bus events (sketch)

```
ingestion:row_count_anomaly         -> anomaly_spotter, severity_classifier
ingestion:schema_drift              -> annotation/runbook_linker
detection:metric_anomaly            -> alert_router, severity_classifier
detection:seasonality_match         -> dedup_correlator
alerting:alert_dispatched           -> annotation/note_drafter
```

### What `autonomous` looks like

Autonomous-tier `alert_router` dispatches a real alert to the on-call
channel without human review. Autonomous-tier `note_drafter` posts the
post-incident note to the runbook store as the agent's own
attribution. Autonomous-tier `dedup_correlator` suppresses an alert
chain it has labelled as a known-recurring storm. The
`review-gated` versions of all three propose the same action and wait
for an operator click.

### Platform tools that "just work"

- `federation-dashboard` shows per-colony tier counts, confidence
  trends, autonomous-tier promotions across all 4 colonies.
- `auto-promote` evolves under-performing anomaly spotters based on
  experience-tagged outcomes (true-positive vs false-positive) the
  alerting colony writes back via `learn(..., outcome=...)`.
- The Forge Rate Limits tile renders an `err: exit 2` for every
  colony (no forge → no `--rate-limit-status`). The rest of the
  dashboard works.

---

## research — paper triage, citation mapping, summarisation

A federation that reads arXiv / OpenReview / your team's reading list
and produces structured notes. Writes to a knowledge-base store + a
weekly digest channel.

### Colony decomposition (sketch)

| Colony | What it watches | Representative agents |
|--------|-----------------|------------------------|
| `intake` | New papers in tracked categories | `arxiv_poller`, `openreview_poller`, `reading_list_watcher` |
| `triage` | Relevance scoring, dedup against existing notes | `relevance_scorer`, `dedup_matcher`, `topic_tagger` |
| `analysis` | Section-level summarisation, citation extraction | `abstract_summariser`, `citation_extractor`, `method_classifier` |
| `synthesis` | Weekly digests, cross-paper trend notes | `digest_writer`, `trend_spotter` |

### Cross-colony bus events (sketch)

```
intake:new_paper                 -> relevance_scorer, dedup_matcher
triage:scored_paper              -> abstract_summariser (if score >= floor)
analysis:summary_ready           -> digest_writer
analysis:citation_extracted      -> trend_spotter
synthesis:digest_draft           -> (extension point — operator review)
```

### What `autonomous` looks like

Autonomous-tier `digest_writer` posts the weekly digest to the team
channel without operator review. Autonomous-tier `topic_tagger` writes
its tags directly to the knowledge-base store. Autonomous-tier
`dedup_matcher` silently drops a paper as a known duplicate without
flagging it for human resolution. `review-gated` versions stage the
same outputs for one-click confirmation.

### Platform tools that "just work"

- Dashboard tile counts and confidence trends as for any other
  federation.
- `auto-promote` watches the `digest_writer`'s acceptance rate
  (operators who edit vs. accept-as-is the draft digest) as the
  fitness signal.

---

## support-triage — ticket routing + draft replies + escalation

A federation that reads a helpdesk API and produces draft replies +
routing decisions + escalation flags. Writes to the helpdesk's
internal-note channel.

### Colony decomposition (sketch)

| Colony | What it watches | Representative agents |
|--------|-----------------|------------------------|
| `intake` | New tickets, customer profile lookups | `ticket_poller`, `customer_context_loader` |
| `classify` | Topic, urgency, sentiment, language | `topic_classifier`, `urgency_scorer`, `sentiment_reader`, `language_detector` |
| `route` | Team / agent assignment, dedup against open tickets | `team_router`, `assignee_picker`, `dedup_correlator` |
| `respond` | Draft reply, KB-article suggester, escalation flag | `reply_drafter`, `kb_suggester`, `escalation_flagger` |

### Cross-colony bus events (sketch)

```
intake:new_ticket                 -> topic_classifier, urgency_scorer
classify:topic_known              -> kb_suggester, team_router
classify:urgency_high             -> escalation_flagger
route:assigned                    -> reply_drafter
respond:draft_ready               -> (extension point — agent review)
respond:escalation_flagged        -> (extension point — manager queue)
```

### What `autonomous` looks like

Autonomous-tier `reply_drafter` posts the reply to the customer
directly under the team's account. Autonomous-tier `team_router`
re-assigns the ticket without operator review. Autonomous-tier
`escalation_flagger` pages the on-call manager for `urgency_high`
tickets. `review-gated` versions stage all three for human approval.

### Platform tools that "just work"

- Dashboard shows the same per-tier counts, restart controls,
  evolve / quarantine knobs as for `dev-apprenticeship`.
- `auto-promote` reads acceptance rate from the `learn(...)` outcome
  field (operator edits vs. accept-as-is the drafted reply) and
  promotes / demotes accordingly.
- Helpdesk APIs typically have rate limits. If the federation's
  helpdesk wrapper exposes `start-colony.sh --rate-limit-status`,
  the Forge Rate Limits tile shows the budget per colony.

---

## monitoring-ops — metric watch + runbook suggest + incident draft

A federation that reads Grafana / Prometheus / Datadog and produces
runbook suggestions + draft incident reports during an event. Writes
to the incident channel + the post-mortem doc store.

### Colony decomposition (sketch)

| Colony | What it watches | Representative agents |
|--------|-----------------|------------------------|
| `metric_watch` | Critical metric channels, SLO burn rate | `slo_burn_watcher`, `latency_anomaly_spotter`, `error_rate_watcher` |
| `correlate` | Cross-service correlation, causality hints | `service_graph_correlator`, `recent_deploy_linker` |
| `respond` | Runbook lookup, draft incident message | `runbook_picker`, `incident_drafter`, `severity_estimator` |
| `postmortem` | Post-incident summary + timeline drafting | `timeline_assembler`, `postmortem_drafter` |

### Cross-colony bus events (sketch)

```
metric_watch:slo_burn_high         -> service_graph_correlator
metric_watch:latency_anomaly       -> recent_deploy_linker, severity_estimator
correlate:probable_cause           -> runbook_picker, incident_drafter
respond:incident_acknowledged      -> postmortem/timeline_assembler
postmortem:draft_ready             -> (extension point — IC review)
```

### What `autonomous` looks like

Autonomous-tier `incident_drafter` posts the incident message to the
ops channel and pages the on-call. Autonomous-tier `postmortem_drafter`
publishes the post-mortem to the doc store. Autonomous-tier
`runbook_picker` triggers a known-safe runbook (e.g. cache flush)
without operator review. `review-gated` versions wait for IC click.

### Platform tools that "just work"

- Dashboard, `auto-promote`, `kill-federation` operate identically.
- The autonomous-warning vocabulary in the dashboard
  (`merging changes, tagging releases, publishing artifacts`) is
  dev-apprenticeship-flavoured; a future iteration ([#258](https://github.com/Replikanti/agentis-colonies/issues/258)
  deferred bucket) will let monitoring-ops federations override it
  to `paging the on-call, triggering a runbook, publishing a post-mortem`.
  Until then it reads slightly off but does not block adoption.

---

## How to use this document

You are *not* expected to implement any of these federations from this
file alone. The colony breakdowns are sketches; the bus events are
illustrative; the agent names are starting suggestions. The
load-bearing claim is that **the platform contract from
[ADR-0003](./adr/ADR-0003-federation-portability-contract.md) holds
across all four** — none of these patterns require platform changes,
only per-federation `.ag` files and `start-colony.sh` wiring.

To scaffold a real federation:

1. Run `tools/new-federation.sh <name>` to generate the compliant
   directory shape.
2. Edit the generated `start-colony.sh` to export your data source's
   env vars (the platform does not care what they are).
3. Author your `.ag` agents. Tier-gate every external write per
   ADR-0001.
4. Add your federation to the `COMPONENTS` array in
   `tools/check-changelog.sh` so the release-PR check covers it.
5. Add a row to the top-level `README.md` Federations table.

When your federation lands, the deferred items in
[#258](https://github.com/Replikanti/agentis-colonies/issues/258)
("Later" bucket — multi-federation install collisions, dashboard
plurality, per-federation autonomous-warning vocabulary) will become
live design work. They are explicitly out of scope until then.
