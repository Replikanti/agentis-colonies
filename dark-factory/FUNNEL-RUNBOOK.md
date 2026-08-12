# Target-selection funnel — operator runbook (epic #1894)

The epic #1894 funnel decides **which** bounty target is worth a hunt at all —
per-severity payability, a freshness-first de-rank by audit density, and a
pre-hunt uniqueness GO/NO-GO — then wires the GO targets to a flat-cyborg hunt
and records one real outcome. This runbook covers two things:

- **(a)** the OFFLINE end-to-end composition that [`demo-funnel-e2e.sh`](./demo-funnel-e2e.sh)
  pins in CI — plumbing only, no real target, no submission;
- **(b)** the REAL operator run — the same chain against a live permissionless
  program, ending in a **human** submission click and a recorded outcome.

> **The offline validation is PLUMBING ONLY.** `demo-funnel-e2e.sh` runs a MOCK
> hunt on synthetic fixtures to prove the stage-to-stage handoffs compose. It is
> NOT a real hunt and NOT a submission. The real hunt is flat-cyborg-only and the
> real submission is a human action — see sections (b) and (d).

The six stages, and the scripts that implement them:

| Stage | Script | Role |
|-------|--------|------|
| M1 | [`bounty-payability-gate.sh`](./bounty-payability-gate.sh) | drop rows whose Medium/High payout is below the floor |
| M2 | [`apply-audit-density.sh`](./apply-audit-density.sh) | de-rank (never drop) heavily-audited targets |
| M3 | [`target-uniqueness-gate.sh`](./target-uniqueness-gate.sh) | pre-hunt GO/FLAG/SKIP + emit the exclusion set |
| M4 | [`run-batch.sh`](./run-batch.sh) + [`hunt-flat-cyborg.sh`](./hunt-flat-cyborg.sh) | gate, then hunt the GO targets on flat-cyborg |
| deliver | [`deliver-submission.sh`](./deliver-submission.sh) | stage a human-gated package (never submits) |
| M5 | [`submission-outcomes.sh`](./submission-outcomes.sh) | roll up recorded submission outcomes |

---

## (a) Offline end-to-end composition (what CI pins)

[`demo-funnel-e2e.sh`](./demo-funnel-e2e.sh) runs the ASSEMBLED chain on
synthetic fixtures and asserts the CROSS-STAGE HANDOFFS (the seams the per-stage
demos cannot cover). It is offline, deterministic, and never touches the real
`~/.dark-factory` (a throwaway `DARK_FACTORY_DIR` + temp drop-dir). Run it
directly, or let `tools/colony-lint.sh` run it:

```sh
dark-factory/demo-funnel-e2e.sh          # direct; exit 0, all [PASS]
./tools/colony-lint.sh                   # hooked alongside the M1–M5 demos
```

The exact command sequence it composes (each stage feeds the next):

```sh
# M1: a $0-Medium row is dropped, the real-Medium rows survive; output is still a 5-col queue.
bounty-payability-gate.sh --queue queue0.tsv --bounties bounties.json --out queue1.tsv

# M2: re-rank M1's OUTPUT via a --probe-cmd stub; the audited target sinks below the fresh one,
#     the row SET is preserved (a permutation — re-rank drops nothing).
apply-audit-density.sh --queue queue1.tsv --probe-cmd "<stub>" --penalty 20 --out queue2.tsv

# M3: GO on the fresh target M2 top-ranked; emit the exclusion set novelty-gate.sh consumes.
target-uniqueness-gate.sh --repo example/fresh --gh-cmd "<stub>" --probe-cmd "<stub>" \
    --exclusion-out exclusion.txt

# M4: gate (a stub mirroring M3's TARGET-UNIQUENESS shape) then a MOCK hunt.
#     The GO target is hunted + ledgered confirmed; the SKIP target is ledgered
#     skipped-known and NEVER hunted (no hunt spent) — the M3->M4 handoff.
run-batch.sh --queue queue2.tsv --pre-hunt-gate "<stub GO/SKIP>" \
    --hunt-cmd "<MOCK: echo VERDICT|confirmed|...>" --out batch-out --max-targets 10

# deliver: an UNMARKED draft is refused (exit 3 — the never-submit gate); a draft carrying
#          SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW is staged into the drop-dir.
deliver-submission.sh --id "example-fresh@abc123:rounding-drift" --draft-file marked-draft.md \
    --target example-fresh --severity High --drop-dir drop

# M5: the staged submission appears in the rollup as `pending` (no outcome recorded offline).
submission-outcomes.sh --summary --drop-dir drop
```

Handoffs asserted: M1→M2 (M2 re-ranks exactly the rows M1 kept), M2→M3 (M3 GO's
the fresh target M2 top-ranked), M3→M4 (GO hunted, SKIP ledgered skipped-known
without a hunt), M4→deliver (the never-submit human gate refuses an unmarked
draft), deliver→M5 (the staged submission rolls up as pending).

**Two honest seams**, documented rather than papered over:

- The **M4 pre-hunt gate is an operator-wired stub** keyed on `$BATCH_KEY` that
  mirrors M3's `TARGET-UNIQUENESS|<verdict>|...` output shape — NOT the real
  `target-uniqueness-gate.sh`. `run-batch.sh` keeps the gate a pure
  operator-wired seam (see its header); the real M3 verdict is produced
  independently in the M3 stage, over the same fresh target.
- The **report-writer draft is a canned fixture** carrying the real
  `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` marker. `report-writer.ag` renders this
  draft in production; an LLM render cannot run offline. The demo asserts the
  `deliver-submission.sh` INTERFACE contract (the human gate), not draft quality.

---

## (b) Operator runbook — the REAL run

1. **Discover** a candidate queue (the shipped intake writes a 5-col TSV queue:
   `score<TAB>key<TAB>url<TAB>title<TAB>scope_hint`).
2. **M1 — payability:** `bounty-payability-gate.sh --queue <queue> --out <queue>`
   drops programs whose Medium/High payout is below `--pay-floor`.
3. **M2 — audit density:** `apply-audit-density.sh --queue <queue> --out <queue>`
   de-ranks heavily-audited targets so fresh + less-picked-over rises to the top.
4. **M3 — uniqueness:** `target-uniqueness-gate.sh --repo <owner/name>` per
   candidate. Take the **GO** targets; a FLAG holds for human review, a SKIP is
   dropped. M3 also emits the exclusion set the finding-level `novelty-gate.sh`
   consumes.
5. **M4 — gate + hunt:**
   ```sh
   run-batch.sh --pre-hunt-gate target-uniqueness-gate.sh \
       --hunt-cmd hunt-flat-cyborg.sh
   ```
   **HARD:** the hunt runs on the **flat-cyborg** backend
   ([`hunt-flat-cyborg.sh`](./hunt-flat-cyborg.sh) drives the `auditor` colony
   under `llm.backend = flat-cyborg`). **NEVER `claude -p`** — the metered bypass
   is prohibited.
6. **deliver — stage the package:** `deliver-submission.sh` writes a
   `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW` package into the operator drop-dir. It
   has **no platform egress** and refuses any draft lacking the marker (exit 3).
7. **HUMAN — the submission click.** A human reviews the staged package and makes
   the **actual submission on the platform, out of band**. Nothing in this
   pipeline submits.
8. **Capture the outcome:** days later the platform replies. Paste it into the
   drop-dir's `OUTCOME.md` (or ingest via
   [`ingest-slack-outcome.sh`](./ingest-slack-outcome.sh)).
9. **M5 — record it:** `submission-outcomes.sh --summary` rolls the recorded
   outcome (accepted / dup / OOS + payout + reason) into the measurement view.

---

## (c) Target selection

Pick a target that is ALL of:

- **Fresh** — recently launched or recently expanded scope; less picked-over
  (M2's audit-density de-rank is the mechanical proxy for this).
- **Permissionless** — open scope you can hunt without an invite or allowlist.
- **Pays Medium/High meaningfully** — our unclaimed edge is common-class
  (Medium/High) findings, so the per-severity payout must clear the M1 floor;
  a program that pays $1M Critical but $0 Medium/High is worthless here.
- **KYC-at-payout only** — KYC required to receive a payout is fine; KYC required
  to *submit* is a blocker. Confirm before spending a hunt.

A dup or out-of-scope outcome is a **valid, recorded data point** — it validates
or corrects the targeting. It is not a failure.

---

## (d) Invariants (hard)

- **Human-gate / never-submit.** `deliver-submission.sh` has no bounty-platform
  egress and refuses any draft lacking `SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW`
  (exit 3). The submission is a human click on the platform. No stage auto-submits.
- **flat-cyborg backend.** The live hunt runs on flat-cyborg via
  `hunt-flat-cyborg.sh`. Never bypass with `claude -p`.
- **Content scrub (public repo).** No internal absolute paths, no local
  worktree paths, no client / private-core identifiers in any committed run-log
  or posted outcome. Name a target by its **public program name only**.

See [`CHANGELOG.md`](./CHANGELOG.md) for the per-milestone history.
