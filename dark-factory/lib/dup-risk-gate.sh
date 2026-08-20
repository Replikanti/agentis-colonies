#!/usr/bin/env bash
# dup-risk-gate.sh --repo <local-git-dir> [--commit <ref>] [--file <relpath>] [--now <unixts>]
#                  [--fresh-days N] [--mature-days N]                                              (#1983)
#
# A NON-LLM, no-network git-history heuristic for the "already reported / duplicate" risk of a bounty target +
# finding, run BEFORE spending effort on a submission. No bounty platform exposes other researchers' reports,
# so this is a proxy: a high-value target that has been live a long time AND whose vulnerable code has been
# UNCHANGED a long time is likely already reported. That is exactly the miss this closes — the TermMax C15
# finding was Immunefi-rated Critical but a DUPLICATE of a report filed ~139 days earlier and still unfixed;
# the vulnerable code's age was the tell, and the existing audit-density probe (fix-audit-N commits) read
# density=0 and missed it. Prefer FRESH targets where a correct finding would be first.
#
# Emits ONE machine-parseable line on stdout, plus a human summary on stderr:
#   DUP-RISK|<LOW|MEDIUM|HIGH>|<target_age_days>|<finding_age_days|->|<reason>
# Bands (env-overridable FRESH_DAYS=30, MATURE_DAYS=90 via flags):
#   LOW    target OR vulnerable code younger than fresh-days  -> recently launched/introduced, likely first
#   HIGH   target >= mature-days AND vulnerable code >= mature-days (or no --file) -> stale surface, likely reported
#   MEDIUM everything in between -> verify freshness before investing
# Exit 0 always emits a band (best-effort); exit 2 on operator error (bad repo / bad numeric flag).
set -u

REPO="" ; COMMIT="" ; FILE="" ; NOW="" ; FRESH_DAYS=30 ; MATURE_DAYS=90
_int() { case "$2" in ''|*[!0-9]*) echo "dup-risk-gate.sh: $1 must be a non-negative integer: $2" >&2; exit 2;; esac; }
while [ $# -gt 0 ]; do case "$1" in
  --repo)        REPO="${2:-}"; shift 2;;
  --commit)      COMMIT="${2:-}"; shift 2;;
  --file)        FILE="${2:-}"; shift 2;;
  --now)         _int --now "${2:-}"; NOW="$2"; shift 2;;
  --fresh-days)  _int --fresh-days "${2:-}"; FRESH_DAYS="$2"; shift 2;;
  --mature-days) _int --mature-days "${2:-}"; MATURE_DAYS="$2"; shift 2;;
  -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
  *) echo "dup-risk-gate.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$REPO" ] && [ -d "$REPO/.git" ] || { echo "dup-risk-gate.sh: --repo must be a local git checkout" >&2; exit 2; }
[ -n "$NOW" ] || NOW=$(date +%s)
_ref="${COMMIT:-HEAD}"

# target age = age of the in-scope commit
_ct=$(git -C "$REPO" log -1 --format=%ct "$_ref" 2>/dev/null) || { echo "dup-risk-gate.sh: cannot read commit date for '$_ref' in $REPO" >&2; exit 2; }
target_age=$(( (NOW - _ct) / 86400 ))
[ "$target_age" -lt 0 ] && target_age=0

# finding age = age of the most recent commit that touched the vulnerable file, as of <ref> (best-effort)
finding_age="-"
if [ -n "$FILE" ]; then
  _fct=$(git -C "$REPO" log -1 --format=%ct "$_ref" -- "$FILE" 2>/dev/null)
  if [ -n "$_fct" ]; then
    finding_age=$(( (NOW - _fct) / 86400 ))
    [ "$finding_age" -lt 0 ] && finding_age=0
  fi
fi

# verdict
_code_mature=1                                   # true when there is no file signal OR the code is >= mature-days
if [ "$finding_age" != "-" ] && [ "$finding_age" -lt "$MATURE_DAYS" ]; then _code_mature=0; fi
if [ "$target_age" -lt "$FRESH_DAYS" ] || { [ "$finding_age" != "-" ] && [ "$finding_age" -lt "$FRESH_DAYS" ]; }; then
  band="LOW"; reason="fresh: target live ${target_age}d, vulnerable code ${finding_age}d (< ${FRESH_DAYS}d) — un-picked-over, a correct finding is likely first"
elif [ "$target_age" -ge "$MATURE_DAYS" ] && [ "$_code_mature" -eq 1 ]; then
  band="HIGH"; reason="picked-over: target live ${target_age}d and vulnerable code unchanged ${finding_age}d (>= ${MATURE_DAYS}d) — an obvious bug on this surface is likely already reported (duplicate risk HIGH)"
else
  band="MEDIUM"; reason="mid: target ${target_age}d / code ${finding_age}d — verify freshness before investing a full hunt"
fi

echo "DUP-RISK|$band|$target_age|$finding_age|$reason"
echo "dup-risk-gate.sh: $band — $reason" >&2
