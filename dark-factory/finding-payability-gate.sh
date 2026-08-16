#!/usr/bin/env bash
# finding-payability-gate.sh — FINDING-LEVEL payability gate (#1930). The sibling of bounty-payability-gate.sh
# (#1897) one stage later in the funnel: #1897 is the PROGRAM-level, USD-floor QUEUE filter that decides which
# TARGET is worth a hunt; this one decides which FINDING of a hunted target is worth DELIVERING, by comparing
# each finding's severity WORD against the program's published pay floor. A Medium lead on a program whose
# rewards table starts at High earns $0 — it is unpayable noise, not progress, and must not be packaged as if
# it were. The two scripts are deliberately NOT fused: they key on different identifiers (`immunefi:<id>` rows
# vs. verify-findings.sh's schema), speak different units (USD vs. severity), and #1897's contract is "only ever
# removes queue lines", which this gate's re-shaping would break.
#
# Usage: finding-payability-gate.sh --findings <verified_findings.json> --pay-floor <critical|high|medium|low>
#                                   [--mode drop|flag] [--out <file>] [-h]
#   --findings  : verify-findings.sh's verified_findings.json (the seam-3 schema). REQUIRED.
#   --pay-floor : the LOWEST severity this program actually pays (run-immunefi-intake.sh derives it into the
#                 queue's `payfloor:<sev>` scope token + its payinfo sidecar). REQUIRED.
#   --mode      : `drop` (default) MOVES sub-floor findings out of verified[] into a new unpayable[] array;
#                 `flag` leaves every finding in verified[] and only annotates it. Nothing is ever DELETED.
#   --out       : output path (default = --findings, i.e. gates in place). Written via a temp file + mv, so a
#                 failure never leaves a truncated artifact behind.
#
# SEVERITY RANK (the closed vocabulary shared with run-immunefi-intake.sh + lib/impact-lens.py):
#   low=1 < medium=2 < high=3 < critical=4. A finding is PAYABLE iff rank(severity) >= rank(pay_floor).
#
# FAIL-OPEN on an unknown severity: a blank / unparseable severity is NEVER dropped (it is annotated
# `pay_verdict: "unknown"` and stays in verified[]) — the repo-wide "a missing/garbled field never false-drops"
# rule, and the only safe default when the alternative is silently discarding a real finding.
#
# WHAT IT WRITES (additive; every pre-existing key is preserved verbatim):
#   verified[].pay_verdict   payable | unpayable | unknown
#   verified[].pay_note      only on an unpayable finding: why it earns $0 here
#   unpayable[]              (--mode drop only) the sub-floor findings, MOVED with their evidence intact
#   pay_floor                the floor that was applied (top level)
#   totals.verified          rewritten to len(verified) so the existing len==totals invariant still holds
#   totals.verified_pregate  what totals.verified was before the gate
#   totals.unpayable         how many findings the gate judged unpayable
#
# SKIP contract: --findings missing/empty -> [SKIP], exit 0, --out UNWRITTEN. Unparseable JSON -> [SKIP],
# exit 0, --out UNWRITTEN (never a truncated artifact). python3 missing -> [SKIP], exit 0.
# Bad args: unknown flag / a missing value / a missing-or-invalid --pay-floor / an unknown --mode -> exit 2.
#
# Requires: python3. READ-ONLY with respect to the outside world: no network, no bounty platform, no delivery.
set -u

# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise crash
# on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "finding-payability-gate.sh: $2 requires a value" >&2; exit 2; }; }

FINDINGS="" ; PAY_FLOOR="" ; MODE="drop" ; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --findings)  nv "$#" "$1"; FINDINGS="$2"; shift 2;;
  --pay-floor) nv "$#" "$1"; PAY_FLOOR="$2"; shift 2;;
  --mode)      nv "$#" "$1"; MODE="$2"; shift 2;;
  --out)       nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help)   sed -n '2,47p' "$0"; exit 0;;
  *) echo "finding-payability-gate.sh: unknown arg: $1" >&2; exit 2;;
esac; done

[ -n "$FINDINGS" ] || { echo "finding-payability-gate.sh: --findings <verified_findings.json> is required" >&2; exit 2; }
case "$PAY_FLOOR" in
  critical|high|medium|low) : ;;
  "") echo "finding-payability-gate.sh: --pay-floor <critical|high|medium|low> is required" >&2; exit 2;;
  *)  echo "finding-payability-gate.sh: --pay-floor must be one of critical|high|medium|low (got '$PAY_FLOOR')" >&2; exit 2;;
esac
case "$MODE" in
  drop|flag) : ;;
  *) echo "finding-payability-gate.sh: --mode must be drop or flag (got '$MODE')" >&2; exit 2;;
esac
[ -n "$OUT" ] || OUT="$FINDINGS"

# Missing / empty input -> nothing to gate (mirrors bounty-payability-gate.sh's SKIP contract).
if [ ! -s "$FINDINGS" ]; then
  echo "[SKIP] no findings file at $FINDINGS — nothing to gate" >&2
  exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "[SKIP] python3 not installed" >&2; exit 0; }

FINDINGS="$FINDINGS" PAY_FLOOR="$PAY_FLOOR" MODE="$MODE" OUT_DISPLAY="$OUT" python3 - > "$OUT.tmp.$$" <<'PY'
import sys, os, json

findings_path = os.environ["FINDINGS"]
pay_floor = os.environ["PAY_FLOOR"].strip().lower()
mode = os.environ["MODE"].strip().lower()

# The closed severity rank (see the header). Anything outside it is UNKNOWN, never a silent 0.
SEV_RANK = {"low": 1, "medium": 2, "high": 3, "critical": 4}
floor_rank = SEV_RANK[pay_floor]

try:
    data = json.load(open(findings_path, encoding="utf-8"))
except Exception as exc:
    sys.stderr.write("[SKIP] finding-payability-gate: %s is not parseable JSON (%s) — leaving it untouched\n"
                     % (findings_path, exc.__class__.__name__))
    sys.exit(9)
if not isinstance(data, dict):
    sys.stderr.write("[SKIP] finding-payability-gate: %s is not a verified_findings.json object — "
                     "leaving it untouched\n" % findings_path)
    sys.exit(9)

verified_in = data.get("verified")
if not isinstance(verified_in, list):
    verified_in = []


def rank_of(f):
    """The finding's severity rank, or None when it carries no usable severity (-> fail-open `unknown`)."""
    if not isinstance(f, dict):
        return None
    return SEV_RANK.get(str(f.get("severity", "") or "").strip().lower())


kept, unpayable = [], []
n_payable = n_unpayable = n_unknown = 0
for f in verified_in:
    if not isinstance(f, dict):
        # A malformed entry is passed through untouched: this gate removes MONEY-LESS findings, not garbage.
        kept.append(f)
        continue
    r = rank_of(f)
    if r is None:
        f["pay_verdict"] = "unknown"
        n_unknown += 1
        kept.append(f)
    elif r >= floor_rank:
        f["pay_verdict"] = "payable"
        n_payable += 1
        kept.append(f)
    else:
        f["pay_verdict"] = "unpayable"
        f["pay_note"] = ("unpayable ($0 below this program's pay floor: %s)" % pay_floor)
        n_unpayable += 1
        # MOVED, never deleted: the evidence stays in the artifact either way, only its array changes.
        (unpayable if mode == "drop" else kept).append(f)

data["verified"] = kept
data["pay_floor"] = pay_floor
if mode == "drop":
    data["unpayable"] = unpayable

totals = data.get("totals")
if not isinstance(totals, dict):
    totals = {}
    data["totals"] = totals
# verified_pregate records what totals.verified meant BEFORE the gate; totals.verified is rewritten to
# len(verified) so the `len(verified) == totals.verified` invariant every downstream reader relies on holds.
totals["verified_pregate"] = totals.get("verified", len(verified_in))
totals["verified"] = len(kept)
totals["unpayable"] = n_unpayable

json.dump(data, sys.stdout, indent=2)
sys.stdout.write("\n")
sys.stderr.write("finding-payability-gate: payable %d, unpayable %d, unknown %d (floor=%s, mode=%s) -> %s\n"
                 % (n_payable, n_unpayable, n_unknown, pay_floor, mode,
                    os.environ.get("OUT_DISPLAY", "") or findings_path))
PY
rc=$?
if [ "$rc" -eq 9 ]; then
  # A [SKIP] the python side already explained: leave --out exactly as it was (never a truncated artifact).
  rm -f "$OUT.tmp.$$"
  exit 0
fi
if [ "$rc" -ne 0 ]; then
  rm -f "$OUT.tmp.$$"
  exit "$rc"
fi

mkdir -p "$(dirname "$OUT")" 2>/dev/null || true
mv "$OUT.tmp.$$" "$OUT"
