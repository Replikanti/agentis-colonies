#!/usr/bin/env bash
# deliver-submission.sh — the DELIVERY MUSCLE that closes the human->federation half of the feedback loop
# (#1526, epic #1505). report-writer.ag (#1508) renders a SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft; this
# script STAGES that draft into an operator DROP-DIRECTORY under a stable submission id so a human can review it,
# file it on the platform out-of-band, and later write the platform's outcome back for feedback-intake.ag to
# fold into learning. It is pure muscle: writing a file into a directory needs no LLM.
#
# DESIGN DECISION (baked in): a LOCAL DROP-DIRECTORY is the exchange point — no platform API, no gist, no scrape.
# Offline-testable, operator-mediated, human-gated. This script never submits: it NEVER contacts any bounty
# platform (no network fetch/egress primitive) and REFUSES (exit 3) to stage any draft that does not carry the
# human-gate marker SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW — the never-submit invariant is baked into the muscle.
#
# Correlation (load-bearing): the stable submission id is `<target>@<in-scope-commit>:<finding-slug>` (e.g.
# `enzyme-onyx@a1b2c3d:sync-deposit-nav-frontrun`). It is written VERBATIM into manifest.json (the authoritative
# correlation record) and echoed as a comment header in OUTCOME.md. The on-disk subdir name is a filesystem-safe
# slug of the id; feedback-intake reads the canonical id back from manifest.json, never from the dirname, so an
# operator can never break correlation by editing a file.
#
# Drop-dir layout ($DROP_DIR default ${DARK_FACTORY_DIR:-$HOME/.dark-factory}/drop, override --drop-dir/$DROP_DIR):
#   $DROP_DIR/<slug>/
#     manifest.json         # canonical submission_id + the three raw gate verdicts + severity + finding metadata
#     submission-draft.md   # report-writer.ag's SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft, verbatim
#     OUTCOME.md            # the outcome TEMPLATE the operator fills IN-PLACE, then feeds to feedback-intake.ag
#
# Usage: deliver-submission.sh --id <submission_id> (--draft-file <path> | draft on stdin) \
#          [--target T] [--commit C] [--finding-slug S] [--title T] [--location L] [--impact I] \
#          [--impact-class K] [--severity B] [--scope-verdict L] [--impact-verdict L] [--dup-risk L] \
#          [--drop-dir DIR]
# Requires: bash + python3. Exit: 0 staged, 2 bad/missing args, 3 draft missing the human-gate marker.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
DROP_DIR="${DROP_DIR:-$DIR/drop}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2 (run-batch.sh convention).
nv() { [ "$1" -ge 2 ] || { echo "deliver-submission.sh: $2 requires a value" >&2; exit 2; }; }

ID="" ; DRAFT_FILE="" ; TARGET="" ; COMMIT="" ; FINDING_SLUG="" ; TITLE="" ; LOCATION="" ; IMPACT=""
IMPACT_CLASS="" ; SEVERITY="" ; SCOPE_VERDICT="" ; IMPACT_VERDICT="" ; DUP_RISK=""
while [ $# -gt 0 ]; do case "$1" in
  --id)             nv "$#" "$1"; ID="$2"; shift 2;;
  --draft-file)     nv "$#" "$1"; DRAFT_FILE="$2"; shift 2;;
  --target)         nv "$#" "$1"; TARGET="$2"; shift 2;;
  --commit)         nv "$#" "$1"; COMMIT="$2"; shift 2;;
  --finding-slug)   nv "$#" "$1"; FINDING_SLUG="$2"; shift 2;;
  --title)          nv "$#" "$1"; TITLE="$2"; shift 2;;
  --location)       nv "$#" "$1"; LOCATION="$2"; shift 2;;
  --impact)         nv "$#" "$1"; IMPACT="$2"; shift 2;;
  --impact-class)   nv "$#" "$1"; IMPACT_CLASS="$2"; shift 2;;
  --severity)       nv "$#" "$1"; SEVERITY="$2"; shift 2;;
  --scope-verdict)  nv "$#" "$1"; SCOPE_VERDICT="$2"; shift 2;;
  --impact-verdict) nv "$#" "$1"; IMPACT_VERDICT="$2"; shift 2;;
  --dup-risk)       nv "$#" "$1"; DUP_RISK="$2"; shift 2;;
  --drop-dir)       nv "$#" "$1"; DROP_DIR="$2"; shift 2;;
  -h|--help)        sed -n '2,44p' "$0"; exit 0;;
  *) echo "deliver-submission.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$ID" ] || { echo "deliver-submission.sh: --id <submission_id> is required" >&2; exit 2; }

# Read the draft (from --draft-file, else stdin). A missing --draft-file that resolves to an empty stdin is a
# bad-args condition (nothing to stage).
if [ -n "$DRAFT_FILE" ]; then
  [ -f "$DRAFT_FILE" ] || { echo "deliver-submission.sh: draft file not found: $DRAFT_FILE" >&2; exit 2; }
  DRAFT="$(cat "$DRAFT_FILE")"
else
  DRAFT="$(cat)"
fi
[ -n "$DRAFT" ] || { echo "deliver-submission.sh: empty draft (no --draft-file and no stdin)" >&2; exit 2; }

# HUMAN-GATE INVARIANT: refuse to stage anything that is not a report-writer draft pending human review. This
# bakes the never-auto-submit contract into the muscle — a non-gated artifact can never reach the drop-dir.
case "$DRAFT" in
  *"SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW"*) : ;;
  *) echo "deliver-submission.sh: draft is missing the SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW human-gate marker; refusing to stage" >&2; exit 3;;
esac

# Filesystem-safe slug of the submission id for the on-disk subdir name (the canonical id lives in manifest.json).
SLUG="$(printf '%s' "$ID" | sed 's/[^A-Za-z0-9._@-]/-/g')"
[ -n "$SLUG" ] || { echo "deliver-submission.sh: --id produced an empty slug" >&2; exit 2; }
STAGE="$DROP_DIR/$SLUG"
mkdir -p "$STAGE"

# manifest.json — the authoritative correlation record (python3 json.dumps, repo convention). Carries the
# canonical submission_id + the three RAW gate verdict lines (verbatim) so intake never re-parses prose.
SUBMISSION_ID="$ID" TARGET="$TARGET" IN_SCOPE_COMMIT="$COMMIT" FINDING_SLUG="$FINDING_SLUG" \
FINDING_TITLE="$TITLE" FINDING_LOCATION="$LOCATION" FINDING_IMPACT="$IMPACT" IMPACT_CLASS="$IMPACT_CLASS" \
SEVERITY_BAND="$SEVERITY" SCOPE_VERDICT="$SCOPE_VERDICT" IMPACT_VERDICT="$IMPACT_VERDICT" DUP_RISK="$DUP_RISK" \
python3 - > "$STAGE/manifest.json" <<'PY'
import json, os, datetime
d = {
    "submission_id":   os.environ.get("SUBMISSION_ID", ""),
    "target":          os.environ.get("TARGET", ""),
    "in_scope_commit": os.environ.get("IN_SCOPE_COMMIT", ""),
    "finding_slug":    os.environ.get("FINDING_SLUG", ""),
    "finding_title":   os.environ.get("FINDING_TITLE", ""),
    "finding_location":os.environ.get("FINDING_LOCATION", ""),
    "finding_impact":  os.environ.get("FINDING_IMPACT", ""),
    "impact_class":    os.environ.get("IMPACT_CLASS", ""),
    "severity_band":   os.environ.get("SEVERITY_BAND", ""),
    "scope_verdict":   os.environ.get("SCOPE_VERDICT", ""),
    "impact_verdict":  os.environ.get("IMPACT_VERDICT", ""),
    "dup_risk":        os.environ.get("DUP_RISK", ""),
    "created_at":      datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "status":          "delivered",
}
print(json.dumps(d, indent=2, sort_keys=True))
PY

# submission-draft.md — the report-writer draft, verbatim.
printf '%s\n' "$DRAFT" > "$STAGE/submission-draft.md"

# OUTCOME.md — the template the operator fills IN-PLACE after the platform responds, then feeds to
# feedback-intake.ag. Generated with a { printf ...; } block (NO heredoc — dash-safe, no \xHH escapes; the
# run-batch.sh style). The three gate-verdict lines are NOT in the template (they live uneditable in
# manifest.json) so the operator cannot corrupt attribution; only verdict/severity/payout/reason are filled in.
{
  printf '%s\n' "# OUTCOME — fill after the platform responds, then run feedback-intake.ag over this dir."
  printf '%s\n' "# submission_id: $ID   (do NOT edit — correlation key; authoritative copy in manifest.json)"
  printf '%s\n' "verdict:        <accepted|closed|duplicate|needs-info>"
  printf '%s\n' "severity:       <Critical|High|Medium|Low|>         # accepted only"
  printf '%s\n' "payout:         <amount+currency, e.g. 25000 USDC>   # accepted only"
  printf '%s\n' "reason:         <one line, e.g. \"front-run of a privileged action, not an on-chain-provable claim\">"
  printf '%s\n' "reviewer_notes: |"
  printf '%s\n' "  <freeform multi-line reviewer reasoning, verbatim from the platform>"
} > "$STAGE/OUTCOME.md"

echo "deliver-submission.sh: staged $ID -> $STAGE (PENDING HUMAN REVIEW — NOT SUBMITTED)" >&2
printf '%s\n' "$STAGE"
exit 0
