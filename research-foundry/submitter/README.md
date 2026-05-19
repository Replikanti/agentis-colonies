# Submitter Colony

> Part of the [Preprint Foundry](../) federation.

Builds `arxiv-metadata.json` (title / abstract / MSC / categories /
authors from `research-foundry/config/authors.toml`), packages
`submission.tar.gz` per arXiv submission format, drafts a cover letter
with explicit AI-assistance disclosure (arXiv 2024+ policy), and
writes a `status: DRAFTED` row to `preprint-ledger.jsonl`.

**HITL gate (mandatory):** the submitter MUST NOT auto-send to arXiv.
It idles after writing the DRAFTED row until a human flips the
per-claim memo key
`submitter:claim-<id>:human_status` to `approved` or `rejected`. On
its next tick the submitter either SMTPs the tarball via
`$PREPRINT_ARXIV_GATEWAY` and writes `status: SUBMITTED`, or writes
`status: HUMAN_REJECTED` plus the operator-supplied reason. See the
federation README §HITL workflow and `tools/review-cli.sh` for the
review helper.

## Agents

| Agent | File | Learns | Autonomy after |
|-------|------|--------|----------------|
| submitter | `agents/submitter.ag` | which arXiv categories accept this author's previous submissions (post-Phase 1) | never auto-promotes past HITL gate |

## Setup

1. Copy and edit the config:
   ```bash
   cp config/colony.example.toml config/colony.toml
   ```

2. Edit `research-foundry/config/authors.toml` with real author
   metadata (name, email, ORCID, endorsed categories) BEFORE the first
   real run. The submitter joins all `[[authors]]` entries with "; "
   into the metadata `authors` field; arXiv rejects submissions
   without a verifiable human author.

3. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

4. Configure the SMTP relay your host uses to reach
   `submit@arxiv.org`. The submitter picks up `$PREPRINT_SMTP_HOST` /
   `$PREPRINT_SMTP_PORT` from env (default: `localhost:25`).

5. Start the colony as part of the federation. Cross-colony handoff is
   now direct via the shared memo store; no `--source-*` flags. See
   `research-foundry/tools/run-research.sh --help` for the current
   invocation.

6. Review DRAFTED rows and approve / reject:
   ```bash
   bash ../tools/review-cli.sh
   bash ../tools/review-cli.sh --show claim-<pid>-t<tick>
   bash ../tools/review-cli.sh --approve claim-<pid>-t<tick>
   bash ../tools/review-cli.sh --reject claim-<pid>-t<tick> --reason "..."
   ```

## preprint-ledger.jsonl row contract (#596 / #600)

Each row is a single JSON object. Rows are append-only chronological;
the latest status per `source_claim_id` wins. All rows are constructed
via `python3 json.dumps` so quotes / newlines / control characters in
LLM-emitted free text cannot corrupt the line (#600 sub-issue 3).

Fields by status:

| Field | Type | Status | Notes |
|-------|------|--------|-------|
| `ts` | int (ms) | all | epoch millis at row-write time |
| `source_audit_run` | string | DRAFTED | upstream audit-foundry run id |
| `source_claim_id` | string | all | upstream claim id (e.g. `claim-<pid>-t<tick>`) |
| `preprint_path` | string | DRAFTED | per-claim output dir holding `main.pdf` / `submission.tar.gz` |
| `title` | string | DRAFTED | paper title (under 200 chars) |
| `abstract` | string | DRAFTED | clean ASCII abstract for the arXiv form |
| `arxiv_category` | string | DRAFTED | primary arXiv category (e.g. `math.GR`) |
| `msc_codes` | array of string | DRAFTED | MSC2020 codes parsed from the LLM-emitted CSV |
| `msc_codes_csv` | string | DRAFTED | original comma-separated CSV; retained for back-compat |
| `status` | string | all | one of `DRAFTED`, `SUBMITTED`, `HUMAN_REJECTED` |
| `latex_compile_ok` | bool | DRAFTED | did latexmk produce `main.pdf`? |
| `reproducibility_runs_ok` | bool | DRAFTED | did the computer's script emit its `expected_substring`? |
| `arxiv_id` | string \| null | DRAFTED | always null on DRAFTED row |
| `submission_ts` | int \| null | DRAFTED / SUBMITTED | epoch millis when the SMTP send fired |
| `smtp_result` | string | SUBMITTED | `sent` or `smtp-error:<reason>` |
| `reason` | string | HUMAN_REJECTED | operator-supplied free-form rejection reason |
| `provenance.editor_pid` | string | DRAFTED / SUBMITTED / HUMAN_REJECTED | pid of the editor that produced `final_tex` |
| `provenance.computer_pid` | string | DRAFTED / SUBMITTED / HUMAN_REJECTED | pid of the computer that produced the reproducibility script + output |
| `provenance.introducer_pid` | string | DRAFTED / SUBMITTED / HUMAN_REJECTED | pid of the introducer that produced the title + MSC seeds |
| `provenance.tick` | int | DRAFTED / SUBMITTED / HUMAN_REJECTED | upstream tick that produced the editor / computer / introducer outputs (used to trace a SUBMITTED row back to the originating chain) |

### `msc_codes` vs `msc_codes_csv` (#600 sub-issue 1)

The MSC2020 codes the LLM produces are received as a comma-separated
string. The ledger row emits BOTH shapes:

- `msc_codes` — array, e.g. `["20D60", "20E45", "05A18"]`. This is the
  shape downstream consumers should rely on (matches the #596
  preprint-ledger.jsonl spec).
- `msc_codes_csv` — original comma-separated string, e.g.
  `"20D60,20E45,05A18"`. Retained for back-compat with v0.1 consumers
  built against the original shape; new code should prefer the array.

The `Metadata` type field name in `submitter.ag` remains
`msc_codes_csv: string` because that is the literal shape returned by
the LLM JSON schema; the array form is computed at row-write time by
splitting on `,` and dropping empty entries.
