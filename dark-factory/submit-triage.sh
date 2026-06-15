#!/usr/bin/env bash
# submit-triage.sh — triage the human-gated submission packages the hunt pipeline stages on disk (#1056,
# epic #1053). run-audit.sh / run-batch.sh drop a verified FINDING under <out>/submission[/<key>]/ as a
# report.md (+ a PoC/witness) marked "PENDING HUMAN REVIEW — NOT SUBMITTED". This tool turns that pile into
# a fast review queue: it scans a staging root, scores each candidate's READINESS, and prints a per-candidate
# submission checklist — so the operator's manual review + submit is quick.
#
# It NEVER contacts a platform. The colony has zero platform-egress by design; a READY package is a LEAD a
# human reviews and submits manually. "Take one finding end-to-end to a real submission" is the operator's
# step (a payable target + their platform account/KYC + a manual post) — this tool makes that step fast, it
# does not perform it.
#
# Usage: submit-triage.sh [--root <dir>] [--checklist <candidate-dir>] [-h]
#   --root <dir>        Staging root to scan for candidate packages (a dir is a candidate if it holds a
#                       report.md). Default: $PWD. Recurses, so both <out>/submission/ (single) and
#                       <out>/submission/<key>/ (batch) shapes are found.
#   --checklist <dir>   Print the human-review + submission checklist for ONE candidate package and exit.
# Readiness: READY = report.md + a PoC/witness present + the NOT-SUBMITTED marker; otherwise INCOMPLETE
# (the missing pieces are listed). The verdict that produced the finding came from a hunt ENGINE, never an
# LLM; this tool only triages what was staged. Exit 0 on success or clean [SKIP]; exit 2 on bad args.
set -u

nv() { [ "$1" -ge 2 ] || { echo "submit-triage.sh: $2 requires a value" >&2; exit 2; }; }
ROOT="$PWD" ; CHECKLIST=""
while [ $# -gt 0 ]; do case "$1" in
  --root)      nv "$#" "$1"; ROOT="$2"; shift 2;;
  --checklist) nv "$#" "$1"; CHECKLIST="$2"; shift 2;;
  -h|--help)   sed -n '2,20p' "$0"; exit 0;;
  *) echo "submit-triage.sh: unknown arg $1" >&2; exit 2;; esac; done
ROOT="${ROOT%/}"; [ -n "$ROOT" ] || ROOT="."   # strip a trailing slash so the relative-path display is clean

# A PoC/witness file in a package dir: a Rust PoC, a Foundry test, or an exploit .sol. Test each candidate
# (a non-matching glob expands to its literal, which `-f` rejects) so one present file is enough.
has_poc() {
  for f in "$1"/poc.rs "$1"/poc_standalone.rs "$1"/*.t.sol "$1"/*xploit*.sol; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# Best-effort severity from an Immunefi-shaped report.md (a "severity ... High" line); "?" if absent.
severity_of() {
  grep -ioE 'severity[:* ]*(critical|high|medium|low)' "$1" 2>/dev/null \
    | grep -ioE 'critical|high|medium|low' | head -1 | tr 'a-z' 'A-Z' || true
}

# --- single-candidate checklist mode ---
if [ -n "$CHECKLIST" ]; then
  D="$CHECKLIST"
  [ -f "$D/report.md" ] || { echo "submit-triage.sh: no report.md in $D" >&2; exit 2; }
  sev="$(severity_of "$D/report.md")"; [ -n "$sev" ] || sev="?"
  echo "Submission checklist — $D"
  echo "  finding report : $( [ -f "$D/report.md" ] && echo present || echo MISSING ) ($D/report.md)"
  echo "  PoC / witness  : $( has_poc "$D" && echo present || echo MISSING )"
  echo "  severity       : $sev"
  echo "  not-submitted  : $( grep -q 'NOT SUBMITTED' "$D/report.md" 2>/dev/null && echo 'marked (good)' || echo 'marker absent' )"
  echo "  --- operator must confirm before submitting (this tool never submits) ---"
  echo "  [ ] PoC reproduces the finding on the same fork/block the verdict used"
  echo "  [ ] target + the affected functions are IN the program's scope"
  echo "  [ ] not a duplicate / not an already-disclosed finding"
  echo "  [ ] severity + impact match the platform's rubric"
  echo "  Then: submit report.md (+ PoC) MANUALLY on the platform. The colony never auto-posts."
  exit 0
fi

# --- scan mode ---
[ -d "$ROOT" ] || { echo "submit-triage.sh: --root not a directory: $ROOT" >&2; exit 2; }
# Collect candidate dirs = those containing a report.md (newline-safe enough for our on-disk layout).
CANDS="$(find "$ROOT" -type f -name report.md 2>/dev/null | sort)"
if [ -z "$CANDS" ]; then
  echo "[SKIP] no staged findings under $ROOT (run the hunt pipeline first) — nothing to triage" >&2
  exit 0
fi

total=0 ; ready=0
printf 'STATUS\tSEVERITY\tCANDIDATE\tMISSING\n'
while IFS= read -r rpt; do
  [ -n "$rpt" ] || continue
  d="$(dirname "$rpt")"
  total=$((total+1))
  miss=""
  has_poc "$d" || miss="${miss}poc,"
  grep -q 'NOT SUBMITTED' "$rpt" 2>/dev/null || miss="${miss}not-submitted-marker,"
  sev="$(severity_of "$rpt")"; [ -n "$sev" ] || sev="?"
  rel="${d#"$ROOT"/}"; [ "$rel" = "$d" ] && rel="$d"
  if [ -z "$miss" ]; then
    status="READY"; ready=$((ready+1)); miss="-"
  else
    status="INCOMPLETE"; miss="${miss%,}"
  fi
  printf '%s\t%s\t%s\t%s\n' "$status" "$sev" "$rel" "$miss"
done <<EOF
$CANDS
EOF

echo "submit-triage: $total candidate(s), $ready READY for human review under $ROOT. Submission is manual — the colony never posts to a platform." >&2
