# Feedback loop: reality-check pattern

Every `.ag` agent that emits a suggestion (tier `propose`, `review-gated`,
or `autonomous`) must be able to learn when that suggestion was wrong.
Without a feedback loop, every acting row lands in the experience store
with `outcome="success"` or `"partial"` regardless of what the operator
actually did on GitLab, which structurally pins
[auto-promote's](./auto-promote.md) `reject_rate_acting` at zero and
makes the brake gate unreachable.

This document describes the **reality-check pattern** — a 4-step idiom
built from existing core primitives that lets an agent close the loop:
emit now, measure against GitLab's state later, and record an honest
`outcome` for the original decision.

For the tier boundaries this pattern sits inside, see
[ADR-0001](./adr/ADR-0001-confidence-tiers.md). For how the honest
outcome is consumed, see [`auto-promote.md`](./auto-promote.md).

## Scope

- **Included:** the 4-step pattern, memo schema, signal-to-outcome
  mapping, per-colony ground-truth signal catalog, pilot reference
  ([`triage/labeler`](../dev-apprenticeship/triage/agents/labeler.ag)),
  interaction with the per-agent confidence memo from #106.
- **Excluded:** the tier contract (in ADR-0001), the auto-promote
  classifier (in `auto-promote.md`), the experience-store schema (in
  the agentis runtime docs).

## The pattern

Each participating agent carries a small verdict memo alongside its
normal state. On one tick, the agent stashes "I just suggested X for
artefact Y at time T". On some later tick, before doing new work, it
reads that memo back, queries GitLab's current state of Y, compares,
and emits a post-hoc `learn()` with an outcome that reflects reality.

```
tick N   : agent suggests labels ["bug", "priority::high"] for issue 42
          record_verdict(issue_id=42, suggested="bug,priority::high")

tick N+k : evaluate_verdict()
            blob    = recall_latest("<agent>:pending_verdict")
            current = exec sh "gitlab-api.sh get-issue 42"
            signal  = compare(suggested, current.labels)
            outcome = signal_to_outcome(signal)
            learn(topic="label", ..., outcome, tags=[scope, "<colony>", "acted"])
            clear verdict memo
```

### 4 steps

1. **Stash a verdict memo** after each acting-tier emission
   (propose, review-gated, or — if the feedback signal is
   separable — autonomous). The memo carries just enough to re-query
   and compare later:

   ```
   // JSON array: [emit_ts, artefact_id, "suggested_payload"]
   let blob = "[" + ts + "," + to_string(iid) + ",\"" + suggested + "\"]";
   memo_write("<agent>:pending_verdict", blob);
   ```

   The array shape keeps the writer total: `ts` is a `date +%s` int,
   `iid` is an int, and in practice the payload is ASCII-safe (label
   names, branch names, etc. have no quotes / newlines / backslashes
   on GitLab), so naive concatenation is sufficient and the agent
   avoids a JSON-encode round-trip.

2. **Re-query GitLab** at the top of the next tick, before any new
   work. Agents already poll GitLab for their main work; the
   reality-check query is a second, smaller read for the specific
   artefact captured in the memo.

3. **Compare suggestion vs. current state** deterministically. Use
   `exec sh` with a small inline `python3 -c '...'` when the comparison
   is set-based or numeric; use `json_get` + `parse_int` when it's a
   single field. **Avoid another `prompt()` round-trip** — comparison
   is mechanical, not semantic.

4. **Emit `learn()` with the honest outcome** and clear the verdict
   memo. Always include the `"acted"` tag so the row lands in
   [auto-promote's acting bucket](./auto-promote.md#classification)
   regardless of which tier originally produced the suggestion.

### Memo schema

| Memo key | Format | Purpose |
|---|---|---|
| `<agent>:pending_verdict` | `[emit_ts, artefact_id, "payload"]` JSON array | The single in-flight suggestion awaiting a reality check |
| `<agent>:last_check` | ISO-8601 UTC string | Already standard; the evaluate step does not touch it |
| `<agent>:confidence` | float as string | Already standard; `apply_feedback()` and `learn()` both write here orthogonally |

One in-flight verdict per agent is sufficient for the pilot. If an
agent needs to track multiple concurrent suggestions, extend the key
with the artefact id (`<agent>:pending_verdict:<iid>`) — the pilot
doesn't, because the tick cadence (60 s) is faster than operator
response time (minutes to hours) and single-slot overwriting is the
conservative default.

### Timeout

Verdicts must age out if the operator never acts:

```
if verdict_age_seconds(blob) > 86400 {   // 24 h
    memo_write("<agent>:pending_verdict", "");
    return;
}
```

Absence of operator action is not evidence of a wrong suggestion.
Aged-out verdicts are **dropped without scoring** — they emit no
`learn()` call. 24 h is the default; shorten it for fast-cadence
projects, lengthen for slower teams.

## Signal-to-outcome mapping

The comparison step returns an ordinal signal. Map it to the
experience-store `outcome` enum as follows:

| Signal | Meaning | `outcome` | `fitness_delta` (v1.4.1) |
|---|---|---|---|
| `0` | No signal yet (artefact unchanged) | _(skip: leave verdict pending)_ | _(no row emitted)_ |
| `1` | Suggestion fully matches reality | `"success"` | `+0.15` |
| `2` | Partial overlap (some of our suggestion landed) | `"partial"` | `+0.02` |
| `3` | No overlap (operator acted, result diverges from ours) | `"fail"` | `-0.15` |

Signal `0` is the critical case. When the operator hasn't yet touched
the artefact, the verdict must stay pending — do not emit a
`"success"` row for "nothing happened". That would re-introduce the
structural optimism this pattern exists to fix.

Binary (`success` / `fail`) is sufficient for agents where the ground
truth is clearly dichotomous (approval posted or not, tag created or
not). Use the full ternary when partial credit is meaningful (label
set overlap, file-list overlap, estimate within ±30%).

## Ground-truth signal catalog

| Colony / agent | Ground truth | Comparison primitive |
|---|---|---|
| `triage/labeler` | label set on the issue N ticks after suggestion | python3 set operations over `json.loads(raw).labels` |
| `triage/prioritizer` | `priority::*` label survival | same set-overlap over a filtered label subset |
| `triage/router` | issue actually worked on by the routed colony (branch / MR created, or issue closed with the colony's trail) | `mr-list --ref=<issue_id_derived_branch>` or label check |
| `code-review/{style,logic,security,test}_reviewer` | review comment survival (resolved / dismissed / quoted-in-diff) | GitLab `mr-notes` fetch; compare comment id across ticks |
| `code-review/approval_decider` | MR outcome after decision — merged clean, reverted, or conflict after ship | `merge-requests --state merged --iid` lookup |
| `planning/scope_estimator` | estimate accuracy vs. actual cycle time | timestamp delta between issue created and closed |
| `planning/risk_assessor` | did any listed risk materialise (e.g. CI failure tagged to the MR) | scan CI / comment history for risk keywords |
| `planning/task_decomposer` | breakdown revised by the operator before MR merged | compare task list before vs. after |
| `implementation/{code,test}_writer`, `implementation/refactorer` | MR outcome — merged, reverted, or follow-up fix merged within a window | `merge-requests --iid` status |
| `release/ship_decider` | post-ship health (build green / red, incident in window) | `pipelines --ref=<tag>` status |
| `release/{version_bumper,changelog_writer}` | artefact edited post-hoc (tag rollback, changelog amendment) | compare artefact hash / length vs. commit time |
| `release/release_checker` | ship decision actually made for the flagged MR | correlate against ship_decider's verdict row |

Each row is a GitLab API call the agent already has access to (the
pilot reuses `gitlab-api.sh get-issue`), plus a deterministic
comparison. No core change is needed.

## Pilot: `triage/labeler`

[`triage/labeler`](../dev-apprenticeship/triage/agents/labeler.ag) is
the first agent converted. Its existing #106 infrastructure (the
`pending_verdict` memo and `evaluate_label_verdict()` function) already
provided 3 of the 4 steps — the missing piece was the `learn()`
emission in step 4. The conversion was:

1. Step 1 (stash): unchanged. `record_label_verdict()` already writes
   the JSON blob.
2. Step 2 (re-query): unchanged. `evaluate_label_verdict()` already
   calls `get-issue`.
3. Step 3 (compare): unchanged. The inline `python3` set-comparison
   emits signal 0 / 1 / 2 / 3.
4. **Step 4 (emit `learn()`):** new. After the pre-existing
   `apply_feedback()` call that adjusts `labeler:confidence` (the #106
   path), the agent now also emits `learn("label", ..., outcome,
   [scope, "triage", "acted"])` with the ternary mapping above.

The two paths are orthogonal and complementary:

- `apply_feedback()` nudges the per-agent confidence memo, which
  drives the `tier()` builtin and therefore the agent's own behaviour
  on the next tick. This is local, fast, and only affects that one
  agent.
- `learn()` appends a row to the experience store, which feeds the
  auto-promote scheduler's fitness stats. This is federation-wide and
  affects all ladder-step decisions for the agent.

Keeping both means the pilot does not regress the #106 auto-confidence
behaviour while also producing the honest signal that #186's
classifier needs.

## Interaction with confidence memo (#106)

The confidence memo and the experience-store `fitness_delta` are two
separate ledgers. The pattern deliberately writes to both:

| Ledger | Writer | Reader | Effect |
|---|---|---|---|
| `<agent>:confidence` memo | `apply_feedback()` (#106) | `tier()` builtin | Next-tick branching (shadow / propose / review-gated / autonomous) |
| Experience store `fitness_delta` | `learn(outcome=...)` (#195 / this pattern) | `auto-promote.sh` fitness stats (#186) | Scheduler-driven ladder promotions |

Signal scaling differs:

- `apply_feedback()` uses small deltas (+0.02, +0.005, −0.01) so a
  single operator reaction doesn't crash or skyrocket the tier
  pointer. Auto-promotion is capped at 0.85 here; anything above
  requires operator sign-off via the dashboard or CLI.
- `fitness_delta` from v1.4.1 uses larger symmetric magnitudes (±0.15,
  +0.02, etc.) because the auto-promote scheduler aggregates over ≥ 60
  acting rows before making any decision. The larger per-row magnitude
  preserves signal under aggregation.

Both signals are honest about the same underlying reality-check
result; they just operate on different timescales.

## Cold start

A fresh agent has no pending verdict and no historical acting rows.
Until it emits its first suggestion, the reality-check branch no-ops
(the `len(blob) < 3` early return at the top of the evaluate step).
Once the first acting tick runs, the pattern bootstraps naturally: one
verdict in flight, one evaluation on the next applicable tick, one
`learn()` row appended to the experience store.

Auto-promote's `shadow → propose` step intentionally does not evaluate
the fitness gates (see [Bootstrap
exception](./auto-promote.md#bootstrap-exception-shadow--propose)), so
a fresh agent is not penalised for having no reality-check rows yet.

## Out of scope

- **Multi-agent consensus** ("reject is disputed by a peer agent").
  The pattern is single-agent only — it scores each agent's
  suggestion against the operator, not against other agents.
- **Evolve threshold tuning.** Let the honest signal land first; if
  `delta_slope_negative_for` or `evolve.trigger.reject_rate_above`
  need re-calibration once real reject rows flow, that is a follow-up
  (see [#163](https://github.com/Replikanti/agentis-colonies/issues/163)).
- **Autonomous-tier agents that write GitLab state directly.** When
  the agent is the one writing the label / comment / tag, there is no
  separable operator signal to score against. The pilot's
  `record_label_verdict()` is called only in the propose and
  review-gated branches for that reason. Future work may introduce a
  longer-horizon check (e.g. does the operator *revert* the
  autonomous write within N days?) but that is a separate pattern.
- **Fan-out to the other 20 agents.** One follow-up per colony or per
  agent; the pilot validates the shape, subsequent tickets copy it.

## Related

- [ADR-0001: Four-tier confidence contract](./adr/ADR-0001-confidence-tiers.md) — tier boundary semantics this pattern sits inside.
- [`auto-promote.md`](./auto-promote.md) — consumer of the honest signal.
- [#106](https://github.com/Replikanti/agentis-colonies/issues/106) — auto-confidence from feedback (per-agent memo track).
- [#186](https://github.com/Replikanti/agentis-colonies/issues/186) / [#192](https://github.com/Replikanti/agentis-colonies/pull/192) — tag classification that makes the honest signal consumable.
- [#195](https://github.com/Replikanti/agentis-colonies/issues/195) — this pattern's parent issue.
- [#163](https://github.com/Replikanti/agentis-colonies/issues/163) — follow-up calibration once signal flows.
