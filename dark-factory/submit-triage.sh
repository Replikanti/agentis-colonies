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
# Usage: submit-triage.sh [--root <dir>] [--checklist <candidate-dir>] [--known-issues <file>] [-h]
#   --root <dir>          Staging root to scan for candidate packages (a dir is a candidate if it holds a
#                         report.md). Default: $PWD. Recurses, so both <out>/submission/ (single) and
#                         <out>/submission/<key>/ (batch) shapes are found.
#   --checklist <dir>     Print the human-review + submission checklist for ONE candidate package and exit.
#   --known-issues <file> Public-disclosure / known-issue list (one signature per line: a function name, a
#                         rule token, or free text; `#` comments allowed). A candidate whose affected
#                         function or report body matches a line is flagged DUP-RISK — Immunefi pays only
#                         the FIRST reporter, so an already-disclosed finding is not worth a submission slot.
# Readiness: READY = report.md + a PoC/witness present + the NOT-SUBMITTED marker; DUP-RISK = otherwise-READY
# but matches a known issue (see --known-issues); otherwise INCOMPLETE (the missing pieces are listed). The
# IMPACT column flags whether the report quantifies funds-at-risk (Immunefi pays on demonstrated impact) and
# the NOVELTY column carries the dedup verdict. The verdict that produced the finding came from a hunt ENGINE,
# never an LLM; this tool only triages what was staged. Exit 0 on success or clean [SKIP]; exit 2 on bad args.
set -u

nv() { [ "$1" -ge 2 ] || { echo "submit-triage.sh: $2 requires a value" >&2; exit 2; }; }
ROOT="$PWD" ; CHECKLIST="" ; KNOWN_ISSUES=""
while [ $# -gt 0 ]; do case "$1" in
  --root)         nv "$#" "$1"; ROOT="$2"; shift 2;;
  --checklist)    nv "$#" "$1"; CHECKLIST="$2"; shift 2;;
  --known-issues) nv "$#" "$1"; KNOWN_ISSUES="$2"; shift 2;;
  -h|--help)      sed -n '2,24p' "$0"; exit 0;;
  *) echo "submit-triage.sh: unknown arg $1" >&2; exit 2;; esac; done
[ -z "$KNOWN_ISSUES" ] || [ -f "$KNOWN_ISSUES" ] || { echo "submit-triage.sh: --known-issues not a file: $KNOWN_ISSUES" >&2; exit 2; }
ROOT="${ROOT%/}"; [ -n "$ROOT" ] || ROOT="."   # strip a trailing slash so the relative-path display is clean

# A PoC/witness file in a package dir: a Rust PoC, a Foundry test, or an exploit .sol. Test each candidate
# (a non-matching glob expands to its literal, which `-f` rejects) so one present file is enough.
has_poc() {
  for f in "$1"/poc.rs "$1"/poc_standalone.rs "$1"/*.t.sol "$1"/*xploit*.sol; do
    [ -f "$f" ] && return 0
  done
  return 1
}

# Best-effort severity from an Immunefi-shaped report.md. Matches both the real table row
# `| Severity (Immunefi) | High |` and a plain `Severity: High` line: take the first severity
# word on the first line mentioning "severity". "?" if absent.
severity_of() {
  grep -i 'severity' "$1" 2>/dev/null \
    | grep -ioE 'critical|high|medium|low' | head -1 | tr 'a-z' 'A-Z' || true
}

# Impact-credibility: Immunefi pays on DEMONSTRATED fund-loss, so a report is credible only when it carries a
# quantified funds-at-risk section AND a primacy-of-impact category (both written by auditor.ag #1456). Prints
# "quant" when both present, "qual?" otherwise (a warning for the human, not a hard block).
impact_of() {
  if grep -qi '## Impact quantification' "$1" 2>/dev/null && grep -qi 'Impact category' "$1" 2>/dev/null; then
    echo "quant"
  else
    echo "qual?"
  fi
}

# The finding's affected function, pulled from the Immunefi-shaped report table row
# `| Affected function | `node` |`. Empty if absent.
affected_fn() {
  awk -F'|' 'tolower($2) ~ /affected function/ {gsub(/[`]/,"",$3); gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3; exit}' "$1" 2>/dev/null
}

# A REPRODUCTION.md manifest (fork/slot + toolchain + rerun command) staged next to the report (#1457).
has_repro() { [ -f "$1/REPRODUCTION.md" ]; }

# Duplicate-risk against a --known-issues list. A candidate is DUP-RISK if a known-issue line (lowercased,
# trimmed; `#`/blank skipped) either references this finding's affected function or appears verbatim in the
# report body. Read-only, no egress — the operator still confirms. Returns 0 on a hit. NOTE: private
# submission queues are invisible; this raises confidence, it does not guarantee primacy.
dup_hit() {  # $1 = report.md path (uses global KNOWN_ISSUES)
  [ -n "$KNOWN_ISSUES" ] && [ -f "$KNOWN_ISSUES" ] || return 1
  local rpt="$1" fn line l
  fn="$(affected_fn "$rpt" | tr 'A-Z' 'a-z')"
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    l="$(printf '%s' "$line" | tr 'A-Z' 'a-z' | awk '{gsub(/^[ \t]+|[ \t]+$/,"");print}')"
    [ -n "$l" ] || continue
    if [ -n "$fn" ] && [ "$fn" != "(handler)" ] && printf '%s' "$l" | grep -qF "$fn"; then return 0; fi
    if grep -qiF "$l" "$rpt" 2>/dev/null; then return 0; fi
  done < "$KNOWN_ISSUES"
  return 1
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
  echo "  impact quant   : $( impact_of "$D/report.md" )"
  echo "  repro manifest : $( has_repro "$D" && echo present || echo 'MISSING (REPRODUCTION.md)' )"
  echo "  novelty        : $( dup_hit "$D/report.md" && echo 'DUP-RISK (matches --known-issues)' || { [ -n "$KNOWN_ISSUES" ] && echo 'novel (vs known-issues list)' || echo 'unchecked (pass --known-issues)'; } )"
  echo "  not-submitted  : $( grep -q 'NOT SUBMITTED' "$D/report.md" 2>/dev/null && echo 'marked (good)' || echo 'marker absent' )"
  echo "  --- operator must confirm before submitting (this tool never submits) ---"
  echo "  [ ] PoC reproduces the finding on the same fork/block the verdict used"
  echo "  [ ] repro manifest (REPRODUCTION.md) matches the live deployment / current fork"
  echo "  [ ] target + the affected functions are IN the program's scope"
  echo "  [ ] not a duplicate / not an already-disclosed finding (private queues are invisible here)"
  echo "  [ ] funds-at-risk quantified against the LIVE deployment, mapped to the platform rubric"
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

total=0 ; ready=0 ; dup=0
printf 'STATUS\tSEVERITY\tIMPACT\tNOVELTY\tCANDIDATE\tMISSING\n'
while IFS= read -r rpt; do
  [ -n "$rpt" ] || continue
  d="$(dirname "$rpt")"
  total=$((total+1))
  miss=""
  has_poc "$d" || miss="${miss}poc,"
  grep -q 'NOT SUBMITTED' "$rpt" 2>/dev/null || miss="${miss}not-submitted-marker,"
  sev="$(severity_of "$rpt")"; [ -n "$sev" ] || sev="?"
  imp="$(impact_of "$rpt")"
  rel="${d#"$ROOT"/}"; [ "$rel" = "$d" ] && rel="$d"
  # Novelty: only meaningful when --known-issues is supplied; otherwise "unchecked".
  if [ -z "$KNOWN_ISSUES" ]; then nov="unchecked"
  elif dup_hit "$rpt"; then nov="DUP-RISK"
  else nov="novel"; fi
  if [ -n "$miss" ]; then
    status="INCOMPLETE"; miss="${miss%,}"
  elif [ "$nov" = "DUP-RISK" ]; then
    status="DUP-RISK"; dup=$((dup+1)); miss="-"   # otherwise-ready, but matches a known disclosure
  else
    status="READY"; ready=$((ready+1)); miss="-"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$status" "$sev" "$imp" "$nov" "$rel" "$miss"
done <<EOF
$CANDS
EOF

echo "submit-triage: $total candidate(s), $ready READY, $dup DUP-RISK for human review under $ROOT. Submission is manual — the colony never posts to a platform." >&2
