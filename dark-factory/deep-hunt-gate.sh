#!/usr/bin/env bash
# deep-hunt-gate.sh — the STAGE 4.5 (--deep-hunt) merge adapter + an adversarial REFUTE gate over each
# invariant-hunt FINDING before it is recorded (#1938).
#
# STAGE 4.5 (run-zone-hunt.sh) runs run-invariant-hunt.sh over a zone and, on an INVARIANT|<target>|FINDING
# with a shrunk STEP| witness, used to append a schema-compatible verified[] entry straight into
# verified_findings.json. That ungated merge WAS the bug this closes: a fuzzer reproducing a broken predicate
# is necessary but NOT sufficient — the predicate may be a mis-specified invariant (a per-operation budget
# read as a cumulative cap), a documented by-design behaviour, or a witness that only a TRUSTED role can drive.
# Three such findings shipped as "verified" false positives this session (reserve RebalancingLib, balancer
# Vault.settle, balancer Vault SYS-solvency).
#
# This helper is a VERBATIM port of that inline merge adapter (the #1778 aggregate-log filter, the fn/STEP/
# verdict extraction, the entry shape) PLUS a gate that runs BEFORE the record is written:
#   * not a FINDING           -> print `0` (a no-op, exactly as before).
#   * FINDING, refute ON      -> run refuter.ag (run-refute.sh --invariant-mode) over the broken invariant +
#                                witness + target source. REAL -> verified[] + print `1`; REFUTED -> a NEW
#                                additive refuted[] bucket (with the refute_reason) + print `refuted`.
#   * gate ERROR / no verdict -> FAIL-OPEN-WITH-TAG: verified[] with "refute_gate":"unassessed" + a loud stderr
#                                line + print `1`, so a transient gate flake never silently deletes a
#                                fuzzer-witnessed finding — it stays distinguishable, not destroyed.
#   * --no-refute             -> the raw pre-gate merge, BYTE-IDENTICAL to the pre-#1938 inline adapter (used by
#                                run-zone-hunt.sh's --no-deep-hunt-refute opt-out, golden-pinned in the demo).
#
# The gate is READ-ONLY over the target and NEVER contacts a bounty platform (it only re-reads the finding).
#
# Usage:
#   deep-hunt-gate.sh --deep-out <DZOUT> --relfile <rel> --class <C> --repo <dir> --verified-json <json> \
#                     --backend <b> --agentis <bin> [--invariant-harness <t.sol>] [--no-refute]
#
# Stdout: exactly ONE token — `0` (no FINDING), `1` (merged into verified[]) or `refuted` (moved to refuted[]).
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
REFUTE="$HERE/run-refute.sh"

DEEP_OUT="" ; RELFILE="" ; DCLASS="" ; REPO="" ; VERIFIED_JSON=""
BACKEND="flat-cyborg" ; AGENTIS="agentis" ; INV_HARNESS="" ; NO_REFUTE=0

need() { [ "$1" -ge 2 ] || { echo "deep-hunt-gate.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --deep-out)          need "$#"; DEEP_OUT="$2"; shift 2 ;;
    --relfile)           need "$#"; RELFILE="$2"; shift 2 ;;
    --class)             need "$#"; DCLASS="$2"; shift 2 ;;
    --repo)              need "$#"; REPO="$2"; shift 2 ;;
    --verified-json)     need "$#"; VERIFIED_JSON="$2"; shift 2 ;;
    --backend)           need "$#"; BACKEND="$2"; shift 2 ;;
    --agentis)           need "$#"; AGENTIS="$2"; shift 2 ;;
    --invariant-harness) need "$#"; INV_HARNESS="$2"; shift 2 ;;
    --no-refute)         NO_REFUTE=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "deep-hunt-gate.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$DEEP_OUT" ] && [ -n "$RELFILE" ] && [ -n "$DCLASS" ] && [ -n "$VERIFIED_JSON" ] || {
  echo "deep-hunt-gate.sh: --deep-out, --relfile, --class and --verified-json are all required" >&2; exit 2; }
[ "$NO_REFUTE" -eq 1 ] || [ -x "$REFUTE" ] || { echo "deep-hunt-gate.sh: run-refute.sh not found/executable at $REFUTE" >&2; exit 3; }

# --- commit(): the VERBATIM merge-adapter port. Re-reads the aggregate invariant log, rebuilds the entry with
# the pre-#1938 key order (byte-identity of --no-refute / a REAL survivor) and appends per disposition:
#   verified   -> verified[] + totals.verified++          (raw merge / REAL survivor)
#   unassessed -> verified[] + "refute_gate":"unassessed"  (fail-open on a gate flake)
#   refuted    -> refuted[]  + totals.refuted++            (the gate killed it)
# Prints `1` for a verified/unassessed merge, `refuted` for a refuted move.
commit() {
  cg_disp="$1"; cg_reason="${2:-}"
  python3 - "$VERIFIED_JSON" "$DEEP_OUT" "$RELFILE" "$DCLASS" "$cg_disp" "$cg_reason" <<'PY'
import sys, os, json, glob, re
verified_json, dzout, relfile, dclass, disp, reason = sys.argv[1:7]
logs = sorted(glob.glob(os.path.join(dzout, "run", "invariant_*.log")))
# #1778 filter: read the AGGREGATE `invariant_<t>.log`, never a per-candidate `invariant_<t>_c<N>.log`.
logs = [p for p in logs if not re.search(r"_c[0-9]+\.log$", os.path.basename(p))]
verdict = None
inv_target = ""
steps = []
if logs:
    with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
        for line in fh:
            if "INVARIANT|" in line:
                seg = line.split("INVARIANT|", 1)[1].strip()
                cols = seg.split("|")
                inv_target = cols[0].strip()
                if len(cols) >= 2:
                    verdict = cols[1].strip()
            if line.startswith("STEP|"):
                steps.append(line[len("STEP|"):].rstrip("\n"))
# fn = first identifier-before-( in the shrunk STEP| sequence; fall back to the contract-file stem.
fn = ""
for s in steps:
    m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", s)
    if m:
        fn = m.group(1); break
if not fn:
    fn = os.path.splitext(os.path.basename(relfile))[0]
steps_joined = " ; ".join(steps)
broken = "stateful invariant broken on " + (inv_target or relfile)
exploit = (broken + " | " + steps_joined) if steps_joined else broken
try:
    data = json.load(open(verified_json, encoding="utf-8"))
except Exception:
    data = {}
if not isinstance(data, dict):
    data = {}
if disp == "refuted":
    # NEW additive bucket: a fuzzer-witnessed finding the invariant-mode refuter killed, with its reason so
    # every refutation is auditable (a wrong one is visible, not silent). Never touches verified[]/totals.verified.
    rentry = {
        "location": "%s:%s" % (relfile, fn),
        "file": relfile,
        "class": dclass,
        "severity": "High",
        "exploit": exploit,
        "source": "invariant-hunt",
        "refute_verdict": "REFUTED",
        "refute_reason": reason,
    }
    data.setdefault("refuted", []).append(rentry)
    totals = data.setdefault("totals", {})
    totals["refuted"] = int(totals.get("refuted", 0)) + 1
    out = "refuted"
else:
    # verified survivor / --no-refute raw merge / unassessed fail-open. The key ORDER below is a VERBATIM port
    # of the pre-#1938 STAGE 4.5 inline adapter — do NOT reorder (the --no-refute path is golden-pinned).
    entry = {
        "location": "%s:%s" % (relfile, fn),
        "file": relfile,
        "class": dclass,
        "severity": "High",
        # exploit carries the broken-invariant text AND the joined STEP| names so score-match's technical-token
        # FALLBACK still matches when the primary location fn is imperfect.
        "exploit": exploit,
        "poc_sketch": steps_joined,
        "verdict": "FINDING",
        "reason": "stateful-invariant fuzzer reproduced a shrunk exploit sequence",
        "source": "invariant-hunt",
    }
    if disp == "unassessed":
        entry["refute_gate"] = "unassessed"
    data.setdefault("verified", []).append(entry)
    totals = data.setdefault("totals", {})
    totals["verified"] = int(totals.get("verified", 0)) + 1
    out = "1"
with open(verified_json, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
print(out)
PY
}

# --- plan phase: is there an aggregate FINDING, and what are its fn + (pipe-safe) exploit for the manifest? ---
PLAN="$(python3 - "$DEEP_OUT" "$RELFILE" <<'PY'
import sys, os, glob, re
dzout, relfile = sys.argv[1], sys.argv[2]
logs = sorted(glob.glob(os.path.join(dzout, "run", "invariant_*.log")))
logs = [p for p in logs if not re.search(r"_c[0-9]+\.log$", os.path.basename(p))]
if not logs:
    print("NOFINDING"); sys.exit(0)
verdict = None
inv_target = ""
steps = []
with open(logs[-1], encoding="utf-8", errors="ignore") as fh:
    for line in fh:
        if "INVARIANT|" in line:
            seg = line.split("INVARIANT|", 1)[1].strip()
            cols = seg.split("|")
            inv_target = cols[0].strip()
            if len(cols) >= 2:
                verdict = cols[1].strip()
        if line.startswith("STEP|"):
            steps.append(line[len("STEP|"):].rstrip("\n"))
if verdict != "FINDING":
    print("NOFINDING"); sys.exit(0)
fn = ""
for s in steps:
    m = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*\(", s)
    if m:
        fn = m.group(1); break
if not fn:
    fn = os.path.splitext(os.path.basename(relfile))[0]
steps_joined = " ; ".join(steps)
broken = "stateful invariant broken on " + (inv_target or relfile)
exploit = (broken + " | " + steps_joined) if steps_joined else broken
# run-refute.sh splits the candidate manifest on '|', so the exploit column may not carry one (map to '/', the
# same scrub _clean_reason applies). The MERGED entry keeps the verbatim exploit — commit() rebuilds it.
print("FINDING")
print(fn)
print(exploit.replace("|", "/"))
PY
)"

VERDICT_KIND="$(printf '%s\n' "$PLAN" | sed -n '1p')"
if [ "$VERDICT_KIND" != "FINDING" ]; then
  printf '0\n'
  exit 0
fi
FN="$(printf '%s\n' "$PLAN" | sed -n '2p')"
MEXPLOIT="$(printf '%s\n' "$PLAN" | sed -n '3p')"

# --no-refute: the raw pre-gate merge, byte-identical to the pre-#1938 adapter (run-zone-hunt.sh's opt-out).
if [ "$NO_REFUTE" -eq 1 ]; then
  commit verified ""
  exit 0
fi

# --- gate: run the invariant-mode refuter over the finding, then scrape its single verdict row. ---
GATE_OUT="$DEEP_OUT/refute-gate"
mkdir -p "$GATE_OUT"
MANIFEST="$GATE_OUT/candidate.manifest"
# code-file column = <relfile> resolved against --code-dir <repo> (verify-findings.sh:run_gate_refute's shape) —
# robust whether $REPO is absolute or relative, where a literal "$repo/$rel" column would double-count a relative repo.
printf '%s:%s|%s|High|%s|%s\n' "$RELFILE" "$FN" "$DCLASS" "$MEXPLOIT" "$RELFILE" > "$MANIFEST"

GATE_LOG="$GATE_OUT/gate.log"
GATE_RC=0
if [ -n "$INV_HARNESS" ]; then
  "$REFUTE" --candidates "$MANIFEST" --code-dir "$REPO" --invariant-mode --invariant-harness "$INV_HARNESS" \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$GATE_OUT/refute-out" >"$GATE_LOG" 2>&1 || GATE_RC=$?
else
  "$REFUTE" --candidates "$MANIFEST" --code-dir "$REPO" --invariant-mode \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$GATE_OUT/refute-out" >"$GATE_LOG" 2>&1 || GATE_RC=$?
fi

REPORT="$GATE_OUT/refute-out/refute-report.md"
GV="ERROR"; GR="gate produced no refute report"
if [ "$GATE_RC" -eq 0 ] && [ -f "$REPORT" ]; then
  # The refuter row is `| <loc> | <class> | <VERDICT> | <reason> |` — read field 4/5 of the first data row,
  # exactly as verify-findings.sh:run_gate_refute does.
  SCRAPE="$(awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r);
        print v "\t" r; found=1; exit } }
    END { if (!found) print "ERROR\tno verdict row" }
  ' "$REPORT")"
  GV="$(printf '%s' "$SCRAPE" | cut -f1)"
  GR="$(printf '%s' "$SCRAPE" | cut -f2-)"
fi

case "$GV" in
  REAL)
    commit verified "" ;;
  REFUTED)
    commit refuted "$GR" ;;
  *)
    echo "deep-hunt-gate.sh: WARNING refute gate did NOT assess $RELFILE:$FN ($DCLASS) — verdict='$GV', rc=$GATE_RC (see $GATE_LOG). Recording the FINDING as verified with refute_gate=unassessed (FAIL-OPEN: a fuzzer-witnessed finding is not silently destroyed by a transient gate flake)." >&2
    commit unassessed "" ;;
esac
