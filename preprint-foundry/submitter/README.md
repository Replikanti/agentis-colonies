# Submitter Colony

> Part of the [Preprint Foundry](../) federation.

Builds `arxiv-metadata.json` (title / abstract / MSC / categories /
authors from `preprint-foundry/config/authors.toml`), packages
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

2. Edit `preprint-foundry/config/authors.toml` with real author
   metadata (name, email, ORCID, endorsed categories) BEFORE the first
   real run. The submitter joins all `[[authors]]` entries with "; "
   into the metadata `authors` field; arXiv rejects submissions
   without a verifiable human author.

3. Non-forge federation -- the only data sources are memo keys seeded
   by `tools/run-preprint.sh` (no GitLab/GitHub).

4. Configure the SMTP relay your host uses to reach
   `submit@arxiv.org`. The submitter picks up `$PREPRINT_SMTP_HOST` /
   `$PREPRINT_SMTP_PORT` from env (default: `localhost:25`).

5. Start the colony as part of the federation:
   ```bash
   bash ../tools/run-preprint.sh \
       --source-audit-run /path/to/claim-auditor/runs/<id> \
       --source-foundry-run /path/to/math-foundry/runs/<id>
   ```

6. Review DRAFTED rows and approve / reject:
   ```bash
   bash ../tools/review-cli.sh
   bash ../tools/review-cli.sh --show claim-<pid>-t<tick>
   bash ../tools/review-cli.sh --approve claim-<pid>-t<tick>
   bash ../tools/review-cli.sh --reject claim-<pid>-t<tick> --reason "..."
   ```
