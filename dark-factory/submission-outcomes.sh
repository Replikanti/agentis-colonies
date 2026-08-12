#!/usr/bin/env bash
# submission-outcomes.sh — SUBMISSION-OUTCOME MEASUREMENT VIEW (#1901, epic #1894 M5), the epic's KPI: how many
# real submissions, with what outcomes. A READ-ONLY, ZERO-EGRESS aggregator over the drop-dir `deliver-
# submission.sh` already writes and `ingest-slack-outcome.sh` already classifies — it NEVER re-runs
# feedback-intake.ag, never touches Slack/any bounty platform, never invokes agentis. It only reads three
# already-durable artifacts per staged submission dir: manifest.json, .outcome-ingested, .pending-confirmation.
#
# SCHEMA GROUNDING (real artifacts, not the epic's loose prose — see deliver-submission.sh / ingest-slack-
# outcome.sh, both reused VERBATIM, never modified):
#   manifest.json        the authoritative correlation record (deliver-submission.sh ~L313-336). This script
#                         reads submission_id / target / severity_band verbatim — never invented keys.
#   .outcome-ingested     written ONLY after a successful classify+learn (ingest-slack-outcome.sh:914), one line:
#                         `ingested <ISO-ts> disposition=<d> signal=<SUCCESS|FAILURE|PARTIAL> stage=<st>`
#                         disposition in {accepted,rejected,duplicate,needs-info,out-of-scope} (feedback-
#                         intake.ag's classifier vocabulary); stage in {impact-gate,scope-gate,dup-scout,
#                         report-writer} (feedback-intake.ag's gate-attribution vocabulary). This is the
#                         AUTHORITATIVE outcome — never OUTCOME.md's own optional `verdict:`/`payout:` override
#                         lines, which are present only when an operator hand-filled them and are not persisted
#                         back into any durable marker this script reads for classification.
#   .pending-confirmation a low-confidence classification HELD for a clearer operator reply (ingest-slack-
#                         outcome.sh:903), one line: `held <ISO-ts> reply_ts=<ts> disposition=<d>
#                         confidence=<c>`. No .outcome-ingested exists yet for this stage.
#   OUTCOME.md            read ONLY for an optional operator `payout:` override line (column-0 anchored, exactly
#                         like feedback-intake.ag's own `^verdict:` grep contract) — never for classification.
#
# Neither of manifest.json / .outcome-ingested / .pending-confirmation / OUTCOME.md is modified by this script.
#
# Usage: submission-outcomes.sh --summary [--drop-dir <dir>] [-h]
#   --summary   : required mode flag (the only mode today; a slot for a future --rates/--json machine mode
#                 without breaking this one, mirroring tools/track-issue-outcomes.sh's --summary/--rates split).
#   --drop-dir  : the drop-dir to walk (default ${DROP_DIR:-${DARK_FACTORY_DIR:-$HOME/.dark-factory}/drop},
#                 byte-identical to deliver-submission.sh's own DROP_DIR resolution).
#   -h/--help   : print this header.
#
# Output: one TSV row per valid submission dir (one with a manifest.json) to STDOUT:
#   submission_id<TAB>target<TAB>severity<TAB>outcome<TAB>payout<TAB>reason
#   outcome: the disposition (accepted|rejected|duplicate|needs-info|out-of-scope) when .outcome-ingested
#            exists; `held` when only .pending-confirmation exists; `pending` when neither exists yet.
#   reason:  .outcome-ingested's stage field; `<disposition>/low-confidence` for a held row; empty for pending.
#   payout:  the OUTCOME.md `^payout:` override line, trimmed of its trailing comment; empty when absent.
# Plus ONE rollup line to STDERR:
#   submission-outcomes.sh: rollup accepted=<n> rejected=<n> duplicate=<n> needs-info=<n> out-of-scope=<n>
#   held=<n> pending=<n> total=<n>
#
# Rows are emitted in dirname order (bash's own sorted glob expansion, the same `for d in "$DROP_DIR"/*/`
# idiom ingest-slack-outcome.sh's --all sweep uses) for determinism. A subdir with no manifest.json is SKIPPED
# (a noted, non-fatal stderr line) and never counted — it is not a valid submission (e.g. deliver-submission.sh
# crashed mid-write).
# An empty/missing drop-dir -> zero TSV rows, an all-zero rollup line, exit 0 (a clean state, never an error).
#
# Requires: bash + python3 (JSON parsing, one python3 block, .get() fallbacks — no invented shell JSON parsing).
# python3 missing -> [SKIP], exit 0. Exit: 0 = ran (incl. empty drop-dir); 2 = bad/missing args.
set -u

DIR="${DARK_FACTORY_DIR:-$HOME/.dark-factory}"
DROP_DIR="${DROP_DIR:-$DIR/drop}"

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2 (repo-wide convention, e.g. bounty-payability-gate.sh's nv()).
nv() { [ "$1" -ge 2 ] || { echo "submission-outcomes.sh: $2 requires a value" >&2; exit 2; }; }

SUMMARY=""
while [ $# -gt 0 ]; do case "$1" in
  --summary)   SUMMARY="1"; shift;;
  --drop-dir)  nv "$#" "$1"; DROP_DIR="$2"; shift 2;;
  -h|--help)   sed -n '2,45p' "$0"; exit 0;;
  *) echo "submission-outcomes.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$SUMMARY" ] || { echo "submission-outcomes.sh: --summary is required (the only mode today)" >&2; exit 2; }

command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

acc=0 ; rej=0 ; dup=0 ; needs=0 ; oos=0 ; held=0 ; pend=0 ; total=0

if [ -d "$DROP_DIR" ]; then
  for d in "$DROP_DIR"/*/; do
    [ -d "$d" ] || continue
    mf="$d/manifest.json"
    if [ ! -f "$mf" ]; then
      echo "submission-outcomes.sh: skipping $d — no manifest.json (not a valid submission stage)" >&2
      continue
    fi

    # All JSON parsing in one python3 block, .get() fallbacks — never crashes on a garbled/partial manifest.
    row="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        m = json.load(f)
except Exception:
    m = {}
sid = m.get("submission_id", "") or ""
tgt = m.get("target", "") or ""
sev = m.get("severity_band", "") or ""
print(sid)
print(tgt)
print(sev)
' "$mf" 2>/dev/null)"
    sid="$(printf '%s\n' "$row" | sed -n '1p')"
    tgt="$(printf '%s\n' "$row" | sed -n '2p')"
    sev="$(printf '%s\n' "$row" | sed -n '3p')"

    outcome="pending" ; reason=""
    ing="$d/.outcome-ingested"
    pending_marker="$d/.pending-confirmation"
    if [ -f "$ing" ]; then
      line="$(sed -n '1p' "$ing")"
      disp="$(printf '%s\n' "$line" | sed -n 's/.*disposition=\([^ ]*\).*/\1/p')"
      stg="$(printf '%s\n' "$line" | sed -n 's/.*stage=\([^ ]*\).*/\1/p')"
      [ -n "$disp" ] && outcome="$disp"
      reason="$stg"
    elif [ -f "$pending_marker" ]; then
      line="$(sed -n '1p' "$pending_marker")"
      disp="$(printf '%s\n' "$line" | sed -n 's/.*disposition=\([^ ]*\).*/\1/p')"
      outcome="held"
      reason="${disp}/low-confidence"
    fi

    # payout: column-0 anchored `^payout:` line in OUTCOME.md ONLY (the operator hand-filled override) — the
    # SAME anchor discipline as feedback-intake.ag's own `^verdict:` grep, so an indented `  payout:` line
    # inside the `platform_response: |` body is never mistaken for the override.
    payout=""
    om="$d/OUTCOME.md"
    if [ -f "$om" ]; then
      pline="$(grep -m1 '^payout:' "$om" 2>/dev/null || true)"
      if [ -n "$pline" ]; then
        payout="$(printf '%s\n' "$pline" | sed -e 's/^payout:[[:space:]]*//' -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//')"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$sid" "$tgt" "$sev" "$outcome" "$payout" "$reason"

    total=$((total + 1))
    case "$outcome" in
      accepted)     acc=$((acc + 1));;
      rejected)     rej=$((rej + 1));;
      duplicate)    dup=$((dup + 1));;
      needs-info)   needs=$((needs + 1));;
      out-of-scope) oos=$((oos + 1));;
      held)         held=$((held + 1));;
      pending)      pend=$((pend + 1));;
    esac
  done
fi

echo "submission-outcomes.sh: rollup accepted=$acc rejected=$rej duplicate=$dup needs-info=$needs out-of-scope=$oos held=$held pending=$pend total=$total" >&2
exit 0
