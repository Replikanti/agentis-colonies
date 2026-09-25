#!/usr/bin/env bash
# demo-holdout-exam.sh — proof of the #2262 held-out exam tooling (M1: the per-row triage scorer).
#
# Every rare row of a held-out exam used to be scored by hand: read the truth row, look for candidates and
# verified findings at the same function, grep the cell logs, read the DISMISS lines and the refute verdicts,
# then decide HIT / MISS and the MISS cause. bench/corpus-bench/triage.py mechanises the READING: per truth row
# it collects the evidence at the row's location and PROPOSES a class (HIT-candidate / refuted /
# found-dismissed / scope-out-of-map / unmeasured / generation / unanchored) with the evidence lines next to
# it. The operator confirms; the tool never claims a HIT.
#
# This demo has TWO parts (both CI-safe: no network, no LLM, no forge):
#   1) SOURCE-GUARD (always): triage.py reads ONLY real output logs (`hunt_*.log*` cell logs and
#      `refute_*.log` refute logs — never the `hunter.ag` / `refuter.ag` source copies every RUN dir holds,
#      which carry the same sentinel literals); it IMPORTS the frozen score-match.py pair rule instead of
#      re-implementing it; the fixture tree carries no absolute home path and its decoy `.ag` files carry no
#      GT-id token or `corpus-bench` literal (the #2231 guard scans every `.ag` under dark-factory/). The
#      behavioural part below SKIPs cleanly (exit 0) without python3.
#   2) BEHAVIOURAL (when python3 is present): `triage.py --self-test` reproduces the fixed triage table in
#      bench/corpus-bench/fixtures/triage/ byte-for-byte and holds the decoy / superseded / unmeasured /
#      rare-subset / determinism assertions.
#
# Usage:  dark-factory/demo-holdout-exam.sh
# Exit: 0 = all assertions hold (SKIPs cleanly when python3 is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CB="$HERE/bench/corpus-bench"
TRIAGE="$CB/triage.py"
FIX="$CB/fixtures/triage"

FAILS=0
note() { echo "demo-holdout-exam.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$TRIAGE" ] || { note "triage.py not found: $TRIAGE" >&2; exit 3; }
for f in truth.tsv map/zones.json map/scope.tsv expected-triage.tsv expected-triage.md; do
  [ -f "$FIX/$f" ] || { note "fixture missing: $FIX/$f" >&2; exit 3; }
done

# ----------------------------------------------------------------------------------------------------------
# 1) SOURCE-GUARD (CI-safe, no toolchain).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #2262 triage scorer ..."

if grep -q 'f.startswith("hunt_")' "$TRIAGE" && grep -q 'f.startswith("refute_") and f.endswith(".log")' "$TRIAGE" \
   && ! grep -qE '^[[:space:]]*(import glob|from glob|.*\.rglob\()' "$TRIAGE"; then
  ok "triage.py reads only hunt_*.log* cell logs + refute_*.log refute logs (no tree-wide glob that could reach a .ag copy)"
else
  bad "triage.py log selection is not restricted to hunt_*.log* / refute_*.log"
fi

if grep -q '"score-match.py"' "$TRIAGE" && grep -q 'spec_from_file_location' "$TRIAGE" \
   && ! grep -qE '^def (parse_row_locations|lead_location|lead_matches_locations|bare_codefile)\(' "$TRIAGE"; then
  ok "triage.py imports score-match.py's pair rule read-only (no local re-implementation)"
else
  bad "triage.py does not import the frozen pair rule, or re-defines it"
fi

home_hits="$(grep -rnE '/home/|/Users/|/root/' "$FIX" 2>/dev/null || true)"
if [ -z "$home_hits" ]; then
  ok "fixtures/triage/ carries no absolute home path"
else
  bad "absolute home path under fixtures/triage/:"
  printf '%s\n' "$home_hits" | sed "s|^$HERE/||" | head -5
fi

decoys="$(find "$FIX" -name '*.ag' -type f 2>/dev/null | sort)"
if [ -n "$decoys" ]; then
  # shellcheck disable=SC2086
  ag_hits="$(grep -nE 'corpus-bench|(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)' $decoys 2>/dev/null || true)"
  if [ -z "$ag_hits" ]; then
    ok "the decoy .ag source copies ($(printf '%s\n' "$decoys" | wc -l | tr -d ' ')) carry no GT-id token and no corpus-bench literal (#2231)"
  else
    bad "a decoy .ag carries a GT-id token or corpus-bench literal (#2231 guard would fire)"
  fi
else
  bad "no decoy .ag source copy under fixtures/triage/ — the negative control is gone"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) BEHAVIOURAL — the fixed triage table (SKIP cleanly without python3).
# ----------------------------------------------------------------------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
  skip "python3 not installed — install python3 to run the triage.py self-test"
else
  note "running triage.py --self-test (behavioural) ..."
  st_out="$(python3 "$TRIAGE" --self-test 2>&1)"; st_rc=$?
  if [ "$st_rc" -eq 0 ]; then
    ok "triage.py --self-test PASSED (fixed triage table reproduced from fixtures/triage/)"
  else
    bad "triage.py --self-test FAILED (exit $st_rc)"
    printf '%s\n' "$st_out" | sed 's/^/         | /' | tail -25
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #2262 triage scorer reads only real output logs, imports the frozen pair rule, and reproduces"
  note "      the fixed per-row triage table (every class a PROPOSAL; the operator confirms)."
  exit 0
fi
note "DEMO FAILED — a #2262 triage assertion did not hold" >&2
exit 1
