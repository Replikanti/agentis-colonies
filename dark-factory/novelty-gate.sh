#!/usr/bin/env bash
# novelty-gate.sh — reject a candidate finding that restates a KNOWN issue (#1485). On a bounty, findings that
# are already in the target's provided audits / known-issues list are NOT rewardable — submitting one is a
# rejected report that costs the operator reputation. So before a finding is staged, it is matched against the
# EXCLUSION set (known-issue signatures the `intel` agent extracts from the audits, or a hand-curated list):
# a candidate that shares a target function/contract identifier AND overlaps on salient terms with a known
# issue is treated as KNOWN and rejected; a genuinely-novel one passes.
#
# Heuristic, not a proof: it errs toward FLAGGING (better to hold a maybe-known finding for human review than
# to auto-stage a duplicate). The human always reviews before submission.
#
# Usage: novelty-gate.sh --exclusion <file> [--min-overlap N] [<finding-file>|-]
#   --exclusion <file>  one known-issue signature per line (free text: finding title + affected function/area).
#   --min-overlap N     salient-term overlap threshold to call a match KNOWN (default 2). A shared `foo(`
#                       function token alone also counts as a match.
#   <finding-file>|-    the candidate finding text (file or stdin). Default stdin.
# Exit: 0 = NOVEL (not in the exclusion set) ; 1 = KNOWN (matches a known issue; the match is printed) ;
#       2 = bad args. Prints the verdict line to stdout.
set -u

nv() { [ "$1" -ge 2 ] || { echo "novelty-gate.sh: $2 requires a value" >&2; exit 2; }; }
EXCL="" ; MIN_OVERLAP="2" ; FINDING="-"
while [ $# -gt 0 ]; do case "$1" in
  --exclusion)   nv "$#" "$1"; EXCL="$2"; shift 2;;
  --min-overlap) nv "$#" "$1"; MIN_OVERLAP="$2"; shift 2;;
  -h|--help)     sed -n '2,20p' "$0"; exit 0;;
  -*)            echo "novelty-gate.sh: unknown flag: $1" >&2; exit 2;;
  *)             FINDING="$1"; shift;;
esac; done

[ -n "$EXCL" ] && [ -r "$EXCL" ] || { echo "novelty-gate.sh: --exclusion <file> required and readable" >&2; exit 2; }
case "$MIN_OVERLAP" in ''|*[!0-9]*) echo "novelty-gate.sh: --min-overlap must be a whole number" >&2; exit 2;; esac

if [ "$FINDING" = "-" ]; then FTEXT="$(cat)"; else [ -r "$FINDING" ] || { echo "novelty-gate.sh: finding not readable: $FINDING" >&2; exit 2; }; FTEXT="$(cat "$FINDING")"; fi
[ -n "$FTEXT" ] || { echo "novelty-gate.sh: empty finding" >&2; exit 2; }

# Match in python: extract salient tokens (function calls `name(`, CamelCase identifiers, vuln-class keywords),
# then for each exclusion line compute overlap; a shared function-call token OR >= min-overlap salient terms => KNOWN.
FTEXT="$FTEXT" EXCL="$EXCL" MIN_OVERLAP="$MIN_OVERLAP" python3 - <<'PY'
import os, re, sys

VULN = {"reentrancy","reentrant","rounding","overflow","underflow","oracle","stale","staleness","deviation",
        "slippage","frontrun","frontrunning","sandwich","donation","inflation","solvency","liquidation",
        "liquidate","cursor","drift","band","clip","anchor","velocity","fee","griefing","dos","precision",
        "sequencer","callback","allowance","approval","share","shares","bindebt","baddebt","insolvency"}

def salient(text):
    low = text.lower()
    # function-call tokens: `name(`
    funcs = set(m.group(1).lower() for m in re.finditer(r'\b([A-Za-z_][A-Za-z0-9_]{2,})\s*\(', text))
    # camelCase identifiers — lower OR upper first letter, with >=1 internal uppercase hump
    # (Solidity is lowerCamel: calculatePriceAtBinPosition, token1BalanceScaled, plus UpperCamel PriceProviderL2)
    camel = set(m.group(0).lower() for m in re.finditer(r'\b[A-Za-z][a-z0-9]*(?:[A-Z][A-Za-z0-9]*)+\b', text))
    # a bare mention of a known identifier (no paren) should still match the func set, so fold camel into funcs too
    ident = funcs | camel
    vk = set(w for w in re.findall(r'[a-z]+', low) if w in VULN)
    return ident, (ident | vk)

ffuncs, fterms = salient(os.environ["FTEXT"])
try:
    minov = int(os.environ["MIN_OVERLAP"])
except ValueError:
    minov = 2

best = None
for raw in open(os.environ["EXCL"], encoding="utf-8", errors="ignore"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    efuncs, eterms = salient(line)
    shared_funcs = ffuncs & efuncs
    overlap = fterms & eterms
    is_match = bool(shared_funcs) or len(overlap) >= minov
    if is_match:
        score = (len(shared_funcs) * 100) + len(overlap)
        if best is None or score > best[0]:
            best = (score, line, sorted(overlap)[:8], sorted(shared_funcs)[:4])

if best:
    print("KNOWN: candidate restates a known issue -> reject (human reviews).")
    print("  matched exclusion: %s" % best[1][:160])
    if best[3]:
        print("  shared function(s): %s" % ", ".join(best[3]))
    print("  overlapping terms: %s" % ", ".join(best[2]))
    sys.exit(1)
else:
    print("NOVEL: no overlap with the known-issue exclusion set -> eligible for human triage + PoC.")
    sys.exit(0)
PY
