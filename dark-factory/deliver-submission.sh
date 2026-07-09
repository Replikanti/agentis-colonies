#!/usr/bin/env bash
# deliver-submission.sh — the DELIVERY MUSCLE that closes the human->federation half of the feedback loop
# (#1526, epic #1505). report-writer.ag (#1508) renders a SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft; this
# script STAGES that draft into an operator DROP-DIRECTORY under a stable submission id so a human can review it,
# file it on the platform out-of-band, and later write the platform's outcome back for feedback-intake.ag to
# fold into learning. It is pure muscle: writing a file into a directory needs no LLM.
#
# DESIGN DECISION (baked in): a LOCAL DROP-DIRECTORY is the exchange point — no bounty-platform API, no scrape.
# Offline-testable, operator-mediated, human-gated. This script never submits: it NEVER contacts any bounty
# platform (no network fetch/egress primitive to a platform) and REFUSES (exit 3) to stage any draft that does
# not carry the human-gate marker SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW — the never-submit invariant is baked
# into the muscle. The finding-ready alert below (via `monitor/scripts/notify.sh`) is an operator page on the
# operator's OWN channel — not a platform submission; it adds no egress to any bounty platform and the
# never-submit invariant is unchanged.
#
# Secret Gist (#1540, best-effort, opt-in on the operator's `gh`/token): the Immunefi PoC form wants a "secret
# Gist environment to support your PoC", so when a PoC source is staged this can auto-create a SECRET gist via
# `gh gist create --secret` carrying the PoC source + REPRODUCE.md + a README. That gist is a SECOND egress —
# but to the operator's OWN GitHub, NOT a bounty-platform submission; the human-gated submit + never-submit
# (no bounty-platform egress) invariants are UNCHANGED. It is capability-gated (`gist_ready()`: `gh` present AND
# a token/auth) and best-effort: on no token / any failure it degrades to bundling the exact `gh gist create
# --secret` command (poc/GIST_COMMAND.txt) + a gist-URL placeholder, and can NEVER fail a stage that succeeded.
#
# Slack/Discord alert (#1538, opt-in): after a successful stage this reuses dark-factory/monitor/scripts/notify.sh
# to page the operator with a finding-ready JSON alert. Configure DARK_FACTORY_SLACK_WEBHOOK (a `secret://...`
# URI per tools/parse-toml-secret.py's grammar, or a raw webhook URL) to opt in; falls back to
# MONITOR_WEBHOOK_URL. With no webhook configured this is a no-op (notify.sh's own stdout no-op fallback,
# redirected to stderr here) — no network, no behaviour change.
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
#                           #   + immunefi_fields (project/asset/impact/severity/title, extracted from the draft)
#                           #   + poc_files/poc_run/reproduce/gist_url (the #1540 PoC-form artifact set)
#     submission-draft.md   # report-writer.ag's SUBMISSION-DRAFT|PENDING-HUMAN-REVIEW draft, verbatim
#     OUTCOME.md            # the outcome TEMPLATE the operator fills IN-PLACE, then feeds to feedback-intake.ag
#     REPRODUCE.md          # (#1540, when a PoC is staged) the toolchain + concrete run command + expected [PASS]
#     poc-run.txt           # (#1540, optional) a captured passing PoC run-log (from run-poc.sh's warm re-run)
#     poc/                  # (#1540, when a PoC is staged) the verbatim PoC source + GIST_README.md; and, with no
#                           #   token, GIST_COMMAND.txt (the exact `gh gist create --secret` command to run by hand)
#
# Usage: deliver-submission.sh --id <submission_id> (--draft-file <path> | draft on stdin) \
#          [--target T] [--commit C] [--finding-slug S] [--title T] [--location L] [--impact I] \
#          [--impact-class K] [--severity B] [--scope-verdict L] [--impact-verdict L] [--dup-risk L] \
#          [--drop-dir DIR] [--poc-file P ...] [--poc-run P] [--poc-kind foundry|hardhat] \
#          [--poc-target C.sol[:Name]] [--poc-match PREFIX]
# Requires: bash + python3 (gh optional, for the secret gist). Exit: 0 staged, 2 bad/missing args, 3 draft
# missing the human-gate marker.
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
DROP_DIR="${DROP_DIR:-$DIR/drop}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2 (run-batch.sh convention).
nv() { [ "$1" -ge 2 ] || { echo "deliver-submission.sh: $2 requires a value" >&2; exit 2; }; }

ID="" ; DRAFT_FILE="" ; TARGET="" ; COMMIT="" ; FINDING_SLUG="" ; TITLE="" ; LOCATION="" ; IMPACT=""
IMPACT_CLASS="" ; SEVERITY="" ; SCOPE_VERDICT="" ; IMPACT_VERDICT="" ; DUP_RISK=""
POC_FILES=() ; POC_RUN="" ; POC_KIND="" ; POC_TARGET="" ; POC_MATCH="test"
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
  --poc-file)       nv "$#" "$1"; POC_FILES+=("$2"); shift 2;;
  --poc-run)        nv "$#" "$1"; POC_RUN="$2"; shift 2;;
  --poc-kind)       nv "$#" "$1"; POC_KIND="$2"; shift 2;;
  --poc-target)     nv "$#" "$1"; POC_TARGET="$2"; shift 2;;
  --poc-match)      nv "$#" "$1"; POC_MATCH="$2"; shift 2;;
  -h|--help)        sed -n '2,54p' "$0"; exit 0;;
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

# --- PoC-form artifact set (#1540, additive; the marker guard above already ran, so an unmarked draft stages ---
# NOTHING — no poc/ dir is ever created for a refused draft). Stage the complete Immunefi PoC-form bundle:
# the verbatim PoC source, a captured passing run-log, a generated REPRODUCE.md, and (best-effort) a secret gist.
# Every step is graceful: a missing input warns to stderr and is skipped, never fatal (writeup-only degradation).

# infer_kind: derive the toolchain from a poc-file basename when --poc-kind is absent (.t.sol -> foundry,
# .js/.ts -> hardhat, else unknown -> handled by the caller).
infer_kind() {
  case "$1" in
    *.t.sol) echo foundry ;;
    *.js|*.ts) echo hardhat ;;
    *) echo "" ;;
  esac
}

# Stage the verbatim PoC source(s). Record the staged basenames (for the manifest + the gist file list).
POC_STAGED=()
if [ "${#POC_FILES[@]}" -gt 0 ]; then
  mkdir -p "$STAGE/poc"
  for _p in "${POC_FILES[@]}"; do
    if [ -f "$_p" ]; then
      _b="$(basename "$_p")"
      cp "$_p" "$STAGE/poc/$_b"
      POC_STAGED+=("$_b")
    else
      echo "deliver-submission.sh: WARNING --poc-file not found, skipping: $_p" >&2
    fi
  done
fi

# The primary PoC basename + the resolved toolchain kind drive REPRODUCE.md and the gist.
PRIMARY_POC=""
[ "${#POC_STAGED[@]}" -gt 0 ] && PRIMARY_POC="${POC_STAGED[0]}"
RESOLVED_KIND="$POC_KIND"
[ -z "$RESOLVED_KIND" ] && [ -n "$PRIMARY_POC" ] && RESOLVED_KIND="$(infer_kind "$PRIMARY_POC")"

# Stage the (optional) captured run-evidence -> poc-run.txt. Given-but-missing warns + skips; absent = no file.
POC_RUN_REL=""
if [ -n "$POC_RUN" ]; then
  if [ -f "$POC_RUN" ]; then
    cp "$POC_RUN" "$STAGE/poc-run.txt"
    POC_RUN_REL="poc-run.txt"
  else
    echo "deliver-submission.sh: WARNING --poc-run not found, skipping: $POC_RUN" >&2
  fi
fi

# Generate REPRODUCE.md whenever a PoC source OR an explicit --poc-kind is known (skipped in pure writeup-only
# mode). Dash-safe { printf ...; } block (NO heredoc; the OUTCOME.md style). INVERTED POLARITY: a PASSING PoC
# means the exploit reproduced (this is the finding).
REPRODUCE_REL=""
if [ -n "$PRIMARY_POC" ] || [ -n "$POC_KIND" ]; then
  _basename="${PRIMARY_POC:-<poc-test-file>}"
  if [ "$RESOLVED_KIND" = "hardhat" ]; then
    _tool="Hardhat (npx hardhat)"
    _cmd="npx hardhat test test/$_basename"
  else
    _tool="Foundry (forge)"
    _cmd="forge test --match-path test/$_basename --match-test $POC_MATCH -vvv"
  fi
  {
    printf '%s\n' "# REPRODUCE — run this PoC against the in-scope target"
    printf '%s\n' ""
    printf '%s\n' "Toolchain: $_tool"
    [ -n "$POC_TARGET" ] && printf '%s\n' "Target: $POC_TARGET"
    printf '%s\n' ""
    printf '%s\n' "1. Copy poc/$_basename into the target repository's test/ directory."
    printf '%s\n' "2. Run: $_cmd"
    printf '%s\n' "3. Expect a PASSING test, e.g. \`[PASS] test_frontrun() (gas: ...)\`."
    printf '%s\n' ""
    printf '%s\n' "INVERTED POLARITY: a PASSING PoC means the exploit REPRODUCED — that is the finding; a failing"
    printf '%s\n' "PoC would mean the exploit did not reproduce."
    printf '%s\n' ""
    printf '%s\n' "A captured passing run-log is bundled at poc-run.txt when present."
    printf '%s\n' ""
    printf '%s\n' "This PoC is a human-triaged LEAD — it is NEVER auto-submitted to any bounty platform."
  } > "$STAGE/REPRODUCE.md"
  REPRODUCE_REL="REPRODUCE.md"
fi

# The form title, extracted from the draft's FIELD|title| line (for the gist desc + README). The full FIELD set
# is extracted into immunefi_fields inside the manifest builder below.
FIELD_TITLE="$(printf '%s\n' "$DRAFT" | sed -n 's/^FIELD|title|//p' | head -1)"

# --- Secret Gist (#1540, best-effort, gated by gist_ready) --------------------------------------------------
# gist_ready: gh present AND (a token is set OR `gh auth status` succeeds). The whole block is wrapped so it can
# NEVER fail a stage that already succeeded, and gh's stdout (the URL) is captured via $(...) with chatter routed
# to stderr, so the one-line staged-path stdout contract holds.
gist_ready() {
  command -v gh >/dev/null 2>&1 || return 1
  if [ -n "${GITHUB_TOKEN:-}" ] || [ -n "${GH_TOKEN:-}" ]; then
    return 0
  fi
  gh auth status >/dev/null 2>&1
}

GIST_URL=""
GIST_PLACEHOLDER="<gist URL: PENDING — create the secret gist for the Immunefi PoC form (see poc/GIST_COMMAND.txt)>"
if [ "${#POC_STAGED[@]}" -gt 0 ]; then
  GIST_DESC="dark-factory PoC${FIELD_TITLE:+ for $FIELD_TITLE} (human-gated; NOT a bounty-platform submission)"
  # A README the operator can read inside the gist (title + repro summary + the human-gated / not-a-submission note).
  {
    printf '%s\n' "# ${FIELD_TITLE:-dark-factory PoC}"
    printf '%s\n' ""
    printf '%s\n' "A runnable PoC supporting an Immunefi submission. See REPRODUCE.md for the exact toolchain +"
    printf '%s\n' "command; the PoC PASSES iff the exploit reproduces (inverted polarity)."
    printf '%s\n' ""
    printf '%s\n' "This gist lives on the operator's OWN GitHub and is human-gated: it is NOT a bounty-platform"
    printf '%s\n' "submission. The dark-factory pipeline never submits."
  } > "$STAGE/poc/GIST_README.md"

  # The exact `gh gist create --secret ...` file list (relative to $STAGE), reused for both the live create and
  # the no-token GIST_COMMAND.txt fallback.
  GIST_FILES=()
  for _b in "${POC_STAGED[@]}"; do GIST_FILES+=("poc/$_b"); done
  [ -n "$REPRODUCE_REL" ] && GIST_FILES+=("$REPRODUCE_REL")
  GIST_FILES+=("poc/GIST_README.md")

  if gist_ready; then
    GIST_URL="$(cd "$STAGE" && gh gist create --secret --desc "$GIST_DESC" "${GIST_FILES[@]}" 2>"$STAGE/.gist-err" || true)"
    GIST_URL="$(printf '%s' "$GIST_URL" | tr -d '\r' | tail -1)"
  fi

  if [ -z "$GIST_URL" ]; then
    # No token OR the create failed/returned empty: bundle the exact command + a placeholder, so the operator can
    # still create the gist by hand for the form. A LOUD stderr warning — the operator NEEDS the gist for the form.
    echo "deliver-submission.sh: WARNING secret gist not created (no gh/token or gh error) — bundling poc/GIST_COMMAND.txt for a manual create; the Immunefi PoC form needs a secret gist" >&2
    _cmd="gh gist create --secret --desc \"$GIST_DESC\""
    for _f in "${GIST_FILES[@]}"; do _cmd="$_cmd $_f"; done
    {
      printf '%s\n' "# Run this from inside the staged dir to create the secret gist for the Immunefi PoC form:"
      printf '%s\n' "#   cd $STAGE"
      printf '%s\n' "$_cmd"
    } > "$STAGE/poc/GIST_COMMAND.txt"
    GIST_URL="$GIST_PLACEHOLDER"
  fi
fi

# manifest.json — the authoritative correlation record (python3 json.dumps, repo convention). Carries the
# canonical submission_id + the three RAW gate verdict lines (verbatim) so intake never re-parses prose, plus the
# #1540 immunefi_fields (FIELD|<label>|<value> extracted from the in-memory draft) + the PoC-form artifact refs.
# Built AFTER the PoC staging + REPRODUCE.md + gist so poc_files/poc_run/reproduce/gist_url are all resolved.
POC_FILES_JOINED=""
[ "${#POC_STAGED[@]}" -gt 0 ] && POC_FILES_JOINED="$(printf '%s\n' "${POC_STAGED[@]}")"
SUBMISSION_ID="$ID" TARGET="$TARGET" IN_SCOPE_COMMIT="$COMMIT" FINDING_SLUG="$FINDING_SLUG" \
FINDING_TITLE="$TITLE" FINDING_LOCATION="$LOCATION" FINDING_IMPACT="$IMPACT" IMPACT_CLASS="$IMPACT_CLASS" \
SEVERITY_BAND="$SEVERITY" SCOPE_VERDICT="$SCOPE_VERDICT" IMPACT_VERDICT="$IMPACT_VERDICT" DUP_RISK="$DUP_RISK" \
DRAFT_TEXT="$DRAFT" POC_FILES_JOINED="$POC_FILES_JOINED" POC_RUN_REL="$POC_RUN_REL" \
REPRODUCE_REL="$REPRODUCE_REL" GIST_URL="$GIST_URL" \
python3 - > "$STAGE/manifest.json" <<'PY'
import json, os, datetime
# Extract the five FIELD|<label>|<value> lines the report-writer draft carries into a nested immunefi_fields dict
# (value = everything after the 2nd '|'). A missing label defaults to "". json.dumps handles all escaping.
fields = {"project": "", "asset": "", "impact": "", "severity": "", "title": ""}
for line in os.environ.get("DRAFT_TEXT", "").splitlines():
    if line.startswith("FIELD|"):
        parts = line.split("|", 2)
        if len(parts) == 3 and parts[1] in fields:
            fields[parts[1]] = parts[2]
poc_files = [x for x in os.environ.get("POC_FILES_JOINED", "").splitlines() if x]
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
    "immunefi_fields": fields,
    "poc_files":       poc_files,
    "poc_run":         os.environ.get("POC_RUN_REL", ""),
    "reproduce":       os.environ.get("REPRODUCE_REL", ""),
    "gist_url":        os.environ.get("GIST_URL", ""),
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

# --- Slack/Discord finding-ready alert (#1538, opt-in, best-effort, additive) ---------------------------------
# An operator PAGE on the operator's OWN webhook — NOT a platform submission; the never-submit invariant above
# is unchanged. Gated purely on a configured webhook (resolved below); with none configured this degrades to
# notify.sh's own stdout no-op fallback, redirected to stderr so it can never corrupt this script's documented
# stdout contract (the staged path, printed below) — the single most load-bearing detail of this wiring.
RESOLVED_WEBHOOK="${MONITOR_WEBHOOK_URL:-}"
if [ -n "${DARK_FACTORY_SLACK_WEBHOOK:-}" ]; then
  if [ -f "$SCRIPT_DIR/../tools/parse-toml-secret.py" ]; then
    RESOLVED_WEBHOOK="$(python3 "$SCRIPT_DIR/../tools/parse-toml-secret.py" --resolve "$DARK_FACTORY_SLACK_WEBHOOK" 2>/dev/null)"
  else
    # Defensive fallback (should never happen in a checked-out repo): a missing resolver must never turn a
    # successful stage into a failure — use the configured value verbatim.
    RESOLVED_WEBHOOK="$DARK_FACTORY_SLACK_WEBHOOK"
  fi
fi

# Map the severity band to notify.sh's own routing vocabulary (high|warn|<anything else> -> base URL).
case "$SEVERITY" in
  Critical|High) NOTIFY_SEVERITY=high ;;
  Medium)        NOTIFY_SEVERITY=warn ;;
  *)             NOTIFY_SEVERITY=low ;;
esac

# Build the finding-ready alert as a JSON OBJECT (python3, args passed via env — no untrusted interpolation),
# mirroring the monitor/scripts/check-drift.sh convention. `severity` is the field notify.sh's own routing reads.
ALERT="$(SUBMISSION_ID="$ID" TARGET="$TARGET" NOTIFY_SEVERITY="$NOTIFY_SEVERITY" SEVERITY_BAND="$SEVERITY" \
  SCOPE_VERDICT="$SCOPE_VERDICT" IMPACT_VERDICT="$IMPACT_VERDICT" DUP_RISK="$DUP_RISK" \
  DRAFT_PATH="$STAGE/submission-draft.md" \
  python3 -c '
import json, os
band = os.environ.get("SEVERITY_BAND", "") or "(unspecified)"
draft_path = os.environ["DRAFT_PATH"]
message = (
    "dark-factory finding ready for human review: " + os.environ["SUBMISSION_ID"] +
    " | severity " + band +
    " | scope=" + os.environ.get("SCOPE_VERDICT", "") +
    " impact=" + os.environ.get("IMPACT_VERDICT", "") +
    " dup=" + os.environ.get("DUP_RISK", "") +
    " | draft: " + draft_path +
    " -- relay to the platform, then fill OUTCOME.md and run feedback-intake.ag."
)
print(json.dumps({
    "kind": "finding-ready",
    "verdict": "pending-human-review",
    "severity": os.environ["NOTIFY_SEVERITY"],
    "submission_id": os.environ["SUBMISSION_ID"],
    "target": os.environ.get("TARGET", ""),
    "scope_verdict": os.environ.get("SCOPE_VERDICT", ""),
    "impact_verdict": os.environ.get("IMPACT_VERDICT", ""),
    "dup_risk": os.environ.get("DUP_RISK", ""),
    "draft_path": draft_path,
    "message": message,
}))
')"

# Invoke via `bash` (never `sh`/dot-source — the #1507/#1534 dash-safety lesson). Notify's stdout is redirected
# to stderr (>&2) so its no-webhook fallback (`[monitor:alert] ...` on stdout) never leaks into THIS script's
# stdout contract. `|| true`: a broken/bogus webhook (notify.sh exit 3/4) must never fail a stage that already
# succeeded — delivery is pure best-effort muscle.
MONITOR_WEBHOOK_URL="$RESOLVED_WEBHOOK" bash "$SCRIPT_DIR/monitor/scripts/notify.sh" "$ALERT" >&2 || true

printf '%s\n' "$STAGE"
exit 0
