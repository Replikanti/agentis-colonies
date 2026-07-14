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

The pattern is now **federation-wide**: all 22 `dev-apprenticeship` agents
participate — 21 wired with the 4-step idiom below, and one
(`planning/risk_assessor`) carrying a documented file-scope waiver because
its advisory risk list has no separable mechanical forge signal to compare
against (see the [ground-truth signal catalog](#ground-truth-signal-catalog)
row and the [Enforcement](#enforcement) section). What began as a pilot on a
single agent and fanned out colony-by-colony (#1453, Wave 1 + Wave 2 M1–M6)
is now the default shape for every acting agent in this federation;
[`tools/check-reality-check.sh`](../tools/check-reality-check.sh) is the
`colony-lint`-enforced mechanism that keeps new agents from regressing it.

- **Included:** the 4-step pattern, memo schema, signal-to-outcome
  mapping, per-colony ground-truth signal catalog, pilot reference
  ([`triage/labeler`](../dev-apprenticeship/triage/agents/labeler.ag)),
  interaction with the per-agent confidence memo from #106, the
  `check-reality-check.sh` enforcement mechanism.
- **Excluded:** the tier contract (in ADR-0001), the auto-promote
  classifier (in `auto-promote.md`), the experience-store schema (in
  the agentis runtime docs).

## Enforcement

[`tools/check-reality-check.sh`](../tools/check-reality-check.sh) (run by
`colony-lint.sh`) enforces the file-scope rule going forward: every
`dev-apprenticeship/*/agents/*.ag` file that writes to the forge (opens an
MR, posts a note, tags/releases, merges — the 9 verbs behind
`forge-api.sh`) must either contain the `"<agent>:pending_verdict"` memo
key from step 1 below, or carry a `// colony-lint: reality-check-waived:
<reason>` annotation. `planning/risk_assessor.ag` is the worked example of
the waiver path — read its annotation for the shape of a justified
exception.

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

3. **Compare suggestion vs. current state** deterministically with
   native `.ag` builtins (`json_get`/`json_get_raw` +
   `json_array_to_strings`/`json_array_object_field_values` for the JSON
   leaves, `regex_find_all`/`sort_unique_strings` + `filter`/`len` for
   set operations); use `json_get` + `parse_int` when it's a single
   field. The #1587 substrate-purity ratchet retired the last embedded
   `python3 -c` comparators (Phase 3 cluster B), so every scorer is now
   pure `.ag`. **Avoid another `prompt()` round-trip** — comparison is
   mechanical, not semantic.

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
| `3` | No overlap (operator acted, result diverges from ours) | `"failure"` | `-0.15` |

Signal `0` is the critical case. When the operator hasn't yet touched
the artefact, the verdict must stay pending — do not emit a
`"success"` row for "nothing happened". That would re-introduce the
structural optimism this pattern exists to fix.

Binary (`success` / `failure`) is sufficient for agents where the ground
truth is clearly dichotomous (approval posted or not, tag created or
not). Use the full ternary when partial credit is meaningful (label
set overlap, file-list overlap, estimate within ±30%). The outcome enum
is exactly `success` / `partial` / `failure` / `timeout` / `error` — the
experience store rejects any other literal (e.g. a bare `"fail"`) at
runtime, so a mis-typed outcome errors the tick before the pending
verdict clears.

## Ground-truth signal catalog

| Colony / agent | Ground truth | Comparison primitive |
|---|---|---|
| `triage/labeler` | label set on the issue N ticks after suggestion | native `.ag` set operations (`json_get_raw` -> `json_array_to_strings`, `member`/`subset`/`intersect` via `filter`+`len`) over the issue labels |
| `triage/prioritizer` | `priority::*` label survival | native flat `regex_find_all(PRISET)` over the raw label array (quote-anchored `priority*`/`p<digits>`/`urgent`/custom-pv), constant-cost regardless of label count (#1638 B2) |
| `triage/router` | issue actually worked on by the routed colony (branch / MR created, or issue closed with the colony's trail) | `mr-list --ref=<issue_id_derived_branch>` or label check |
| `triage/issue_creator` **(Wave 2 M5)** | fate of the self-observe issue it `create-issue`'d — closed as real work vs. closed as noise | `forge-api.sh issue <iid>` state + native quote-anchored `index_of` label-set membership (same helper family as `planning/scope_estimator`, Wave 2 M3) |
| `code-review/{style,logic,security,test}_reviewer` | review comment survival (resolved / dismissed / quoted-in-diff) | GitLab `mr-notes` fetch; compare comment id across ticks |
| `code-review/approval_decider` **(Wave 1)** | MR fate after the approve/request_changes call — merged vs. closed-unmerged | bounded `merge-requests --state merged \| closed --per-page 50` list-scan + native `.ag` iid membership (`json_array_object_field_values` + `member`, merged checked first, both-ends bracket guard) |
| `planning/plan_reviewer` **(Wave 1)** | auto-promotion (#1362) survival — impl trigger label kept vs. `needs-planning` re-added, after a 30-min soak | `forge-api.sh issue <iid>` raw labels + native `.ag` set membership (`json_get_raw` -> `json_array_to_strings` + `member`) |
| `planning/scope_estimator` **(Wave 2 M3)** | fate of the issue the estimate was posted on — closed as real work vs. closed as noise | `forge-api.sh issue <iid>` state + native quote-anchored `index_of` label-set membership |
| `planning/risk_assessor` **(WAIVED)** | _(no wired signal — advisory risk list has no separable mechanical forge signal; a structured risk-outcome marker would be needed, see the `// colony-lint: reality-check-waived:` annotation in the agent)_ | _(n/a)_ |
| `planning/task_decomposer` **(Wave 2 M3)** | fate of the issue the breakdown was posted on — closed as real work vs. closed as noise | `forge-api.sh issue <iid>` state + native quote-anchored `index_of` label-set membership |
| `implementation/code_writer` **(Wave 1)** | fate of the deterministic `fix/issue-<iid>` branch's MR — merged, closed-unmerged, or still open | bounded `merge-requests --state merged \| closed \| opened` list-scan via `raw_list_has_branch` (merged checked first) |
| `implementation/{test_writer,refactorer}` | MR outcome — merged, reverted, or follow-up fix merged within a window | bounded `merge-requests` list-scan by branch |
| `release/ship_decider` **(Wave 1)** | a release (new tag) actually cut after a `ship` verdict — **success-only** signal; the 24 h ageout drops the verdict UNSCORED (a `partial` would carry a positive delta and reward ignored ship calls) | sanitized tag-name **SET** baseline via `tags --per-page 50` + native `.ag` set diff — a free `cur == baseline` early-exit plus a flat union-length test (`len(union) > len(baseline)`), constant-cost regardless of tag history (#1638 B2); GitHub `/tags` is unordered, so a set diff, not a latest-tag compare |
| `release/version_bumper` **(Wave 2 M4)** | tag survival — does the tag it created still exist; genuine ternary (found -> success, confirmed absent past a 24h grace window -> failure) | `tag_exists` boundary-anchored `index_of` membership over `tags --per-page 50` (deliberately NOT ship_decider's prefix-filtered tag-name set — version_bumper runs per customer repo, not just this federation's own) |
| `release/changelog_writer` **(Wave 2 M4)** | a release actually cut after its draft — **success-only** signal; the 24 h ageout drops the verdict UNSCORED | newest-`tag_name` compare over `releases --per-page 1` (both backends return releases pre-sorted newest-first) |
| `release/release_checker` **(Wave 2 M4)** | a release actually cut after it flagged the MR ready — **success-only** signal; the 24 h ageout drops the verdict UNSCORED | same newest-`tag_name` compare over `releases --per-page 1` |

Each row is a GitLab API call the agent already has access to (the
pilot reuses `gitlab-api.sh get-issue`), plus a deterministic
comparison. No core change is needed.

**Caveat — no `--iid` / `get-mr` point-lookup verb.** The forge wrappers
expose list verbs (`merge-requests --state <s>`), not a single-MR fetch, so
the Wave-1 agents score against a **bounded list scan** within the 24 h
verdict window: fetch the merged (and, if needed, closed / opened) lists at
`--per-page 50` and test membership deterministically. The merged list is
always checked FIRST and must PARSE as a JSON array before anything is
scored — GitHub reports merged PRs as `state=closed` too, so a transient
merged-query failure could otherwise misread a merged MR as
closed-unmerged. Adding a `get-mr <iid>` verb is a possible future
optimisation but is out of scope for Wave 1.

**Rollout complete (#1453).** Wave 1 carried the pilot's 4-step idiom onto
the four agents closest to terminal actions — `code-review/approval_decider`,
`implementation/code_writer`, `planning/plan_reviewer`,
`release/ship_decider` (bold rows above). Wave 2 (M1–M6) fanned the pattern
out to every remaining acting agent, colony by colony; the per-row
`**(Wave 2 M<n>)**` tags above are historical provenance for which PR
shipped which row. All 22 dev-apprenticeship agents now participate — 21
wired, 1 documented waiver (`planning/risk_assessor`) — and
[`tools/check-reality-check.sh`](../tools/check-reality-check.sh) is the
regression guard that keeps it that way for any agent added from here on.

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
3. Step 3 (compare): the set-comparison emits signal 0 / 1 / 2 / 3.
   (Originally an inline `python3 -c`; the #1587 ratchet Phase 3 cluster B
   rewrote it to a native `.ag` `member`/`subset`/`intersect` compare —
   same signals.)
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
- **Fan-out to the other 20 agents.** Done — #1453 Wave 2 (M1–M6) carried
  the pattern (wired or documented-waived) to every remaining acting
  agent. Any *new* acting agent added to `dev-apprenticeship` is caught by
  [`tools/check-reality-check.sh`](../tools/check-reality-check.sh) at PR
  time rather than needing a manual follow-up ticket. Autonomous-tier
  coverage is tracked separately (see below).

## Autonomous-tier extension (#203, labeler pilot)

The propose / review-gated pattern above hinges on a separable
operator signal: the agent suggests, the operator reacts, and the
reaction is the ground truth. Autonomous-tier agents don't have that
shape — the agent *is* the writer, so "did the operator apply our
suggestion?" collapses into "yes, we did." The longer-horizon
question that still makes sense is "**did the operator revert the
autonomous write?**" — and that takes time to settle, so a
single-slot `pending_verdict` idiom won't work.

### Memo schema

The autonomous path uses one blob per in-flight iid plus a separate
index to make them iterable:

```
labeler:autonomous_verdict:<iid>  -> "[ts, iid, \"labels_csv\"]"
labeler:autonomous_verdict_index  -> CSV of iids with pending blobs
```

The index is the only structure the per-tick scanner reads to decide
which iids to check. Blobs are read per-iid inside the scanner, and
a missing blob (index drift) triggers a self-heal that drops the iid
from the index without emitting a learn row.

### Soak and ageout

- **Soak: 30 min (1800 s).** An autonomous write is scored no earlier
  than 30 minutes after it lands. That gives the operator time to
  notice and react before the agent decides "no revert = success."
  Too short and the system converges on false positives; too long and
  the feedback loop stalls.
- **Ageout: 48 h (172 800 s).** After 48 hours the blob is dropped
  without emitting a learn row. Absence of action is not evidence of
  a wrong write (same rationale as the propose path's 24 h ageout at
  line 150 of `labeler.ag`). The longer window reflects the longer
  human-response horizon — operators notice a misapplied label within
  a working day or two, not within a lunch hour.

Both windows are intentionally `.ag` literals rather than config
knobs; if they need tuning once signal flows, the next iteration
lifts them into a memo or config file (same posture as propose-path
`delta` values).

### Two-row pattern at autonomous tier

Autonomous writes emit **two** `learn()` rows per action, not one:

| When               | Row                                                                             | Outcome    | Tag bucket  |
|--------------------|---------------------------------------------------------------------------------|------------|-------------|
| At write           | `learn("label", "issue <iid>", <labels>, "success", [scope, "triage", "acted"])` | success    | acted       |
| After 30 min soak  | `learn("label", "issue <iid> autonomous-revert-check", ..., <outcome>, [scope, "triage", "acted"])` | success / partial / failure | acted       |

The at-write row preserves the acting-path fitness signal the
existing `#186` aggregation consumes. The post-soak row lands in the
same tag bucket and averages in — so if operators consistently revert
an autonomous write, the acting fitness for that agent drifts down
despite the at-write optimism. One correctly-kept write plus one
reverted write nets to ~0.0 fitness delta, which is the honest answer.

### Signal interpretation

The compare step in `score_one_autonomous()` differs from the propose
path because we wrote the labels ourselves. There is no "no signal
yet" case (signal 0 doesn't exist here) — if the operator has cleared
our labels entirely, that is a reversal, not silence. The native `.ag`
compare output is strict:

- **1 — full match:** every suggested label still present → `success`
- **2 — partial erosion:** some labels removed → `partial`
- **3 — full reversal:** none of our labels remain → `failure`

### Ordering invariant

`record_autonomous_verdict` is called **before** the at-write
`learn("success")` in the autonomous branch. If the memo write
succeeds but `learn()` fails, we have a soak row coming but no
at-write row — acceptable asymmetry (the soak row is the honest one).
If `learn()` succeeds but the memo write fails, we have an at-write
row with no future reality-check — acceptable asymmetry (the acting
fitness is at worst slightly optimistic, which is the bias the
two-row pattern is designed to correct over time).

## Related

- [ADR-0001: Four-tier confidence contract](./adr/ADR-0001-confidence-tiers.md) — tier boundary semantics this pattern sits inside.
- [`auto-promote.md`](./auto-promote.md) — consumer of the honest signal.
- [#106](https://github.com/Replikanti/agentis-colonies/issues/106) — auto-confidence from feedback (per-agent memo track).
- [#186](https://github.com/Replikanti/agentis-colonies/issues/186) / [#192](https://github.com/Replikanti/agentis-colonies/pull/192) — tag classification that makes the honest signal consumable.
- [#195](https://github.com/Replikanti/agentis-colonies/issues/195) — this pattern's parent issue (propose / review-gated).
- [#203](https://github.com/Replikanti/agentis-colonies/issues/203) — autonomous-tier extension documented in the section above.
