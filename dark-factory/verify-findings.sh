#!/usr/bin/env bash
# verify-findings.sh — #1630 (milestone M4 of epic #1611: verify integration). The M3 -> verify BRIDGE.
#
# run-discovery.sh (M3) emits discovery-results.json: a machine-readable set of UNVERIFIED candidate LEADS, one
# per (subsystem x class) cell. A candidate is worth a human's attention ONLY after a SECOND, independent gate
# fails to kill it. This script drives that gate over EVERY candidate and aggregates the survivors into
# verified_findings.json — the CONFIRMED-only input the M5 capstone hands to the submission pass.
#
# WHAT IT IS. For each candidate in discovery-results.json it derives a one-line gate manifest from the
# candidate's own fields and invokes the operator-selected gate:
#   --gate refute   (DEFAULT): run-refute.sh — a hostile skeptic re-reads the candidate against the real
#                   control-flow and defaults to REFUTED on any doubt; CONFIRMED = the `REAL` verdict.
#   --gate poc      : run-poc.sh — a concrete Foundry/Hardhat PoC; CONFIRMED = the `POC|<target>|FINDING` line.
#   --gate symbolic : run-symbolic.sh — a Halmos property; CONFIRMED = the `SYMBOLIC|<file:fn>|COUNTEREXAMPLE`.
# A candidate the gate cannot CONFIRM is DROPPED (unverified, never fatal). Per-candidate isolation: each gate
# call is wrapped so a gate that errors on one candidate is logged and SKIPPED, never aborting the batch.
#
# WHAT IT IS NOT. It is READ-ONLY over discovery-results.json (never mutates it), touches no network, and has NO
# submit verb anywhere — a CONFIRMED finding is still a LEAD a human triages. Surfacing the verified subset is
# the whole job; verification's downstream (packaging + the human-gated submission pass) is M5's capstone.
#
# Usage:
#   verify-findings.sh --results <discovery-results.json> --repo <dir> --out <dir> [options]
#
# Options:
#   --results <file>    M3 run-discovery.sh discovery-results.json (the candidate set). REQUIRED.
#   --repo <dir>        Cloned target repo root — the base for each candidate's code file. REQUIRED.
#   --out <dir>         Output dir for the per-candidate gate runs + verified_findings.json. REQUIRED.
#   --gate <refute|poc|symbolic>  Verification gate (default: refute — the best manifest-shape match + it has
#                       the offline --agentis/--backend mock stub seam).
#   --brief <file>      Optional protocol brief handed to the refute gate (invariants + known issues).
#   --backend <mock|flat-cyborg|claude>  LLM backend for the gate (default: flat-cyborg).
#   --agentis <bin>     agentis binary (default: `agentis` on PATH).
#   -h, --help          This help.
#
# Exit: 0 on a clean run that reached its aggregate (even with zero survivors — a rigorous negative is valid);
#       2 usage error; 3 missing prerequisite.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
RESULTS="" ; REPO="" ; OUT="" ; GATE="refute" ; BRIEF="" ; BACKEND="flat-cyborg"

nv() { [ "$1" -ge 2 ] || { echo "verify-findings.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --results) nv "$#"; RESULTS="$2"; shift 2 ;;
    --repo)    nv "$#"; REPO="$2"; shift 2 ;;
    --out)     nv "$#"; OUT="$2"; shift 2 ;;
    --gate)    nv "$#"; GATE="$2"; shift 2 ;;
    --brief)   nv "$#"; BRIEF="$2"; shift 2 ;;
    --backend) nv "$#"; BACKEND="$2"; shift 2 ;;
    --agentis) nv "$#"; AGENTIS="$2"; shift 2 ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "verify-findings.sh: unknown flag $1" >&2; exit 2 ;;
  esac
done

[ -n "$RESULTS" ] && [ -f "$RESULTS" ] || { echo "verify-findings.sh: --results <discovery-results.json> required" >&2; exit 2; }
[ -n "$REPO" ]    && [ -d "$REPO" ]    || { echo "verify-findings.sh: --repo <cloned repo dir> required" >&2; exit 2; }
[ -n "$OUT" ] || { echo "verify-findings.sh: --out <output dir> required" >&2; exit 2; }
case "$GATE" in
  refute|poc|symbolic) : ;;
  *) echo "verify-findings.sh: --gate must be one of refute|poc|symbolic (got '$GATE')" >&2; exit 2 ;;
esac
[ -z "$BRIEF" ] || [ -f "$BRIEF" ] || { echo "verify-findings.sh: --brief not found: $BRIEF" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "verify-findings.sh: python3 not installed" >&2; exit 3; }

# Resolve every operator path to ABSOLUTE (the gate scripts run from throwaway cwds).
REPO="$(cd "$REPO" && pwd)"
RESULTS="$(cd "$(dirname "$RESULTS")" && pwd)/$(basename "$RESULTS")"
[ -z "$BRIEF" ] || BRIEF="$(cd "$(dirname "$BRIEF")" && pwd)/$(basename "$BRIEF")"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"

REFUTE="$HERE/run-refute.sh"
POC="$HERE/run-poc.sh"
SYMBOLIC="$HERE/run-symbolic.sh"
case "$GATE" in
  refute)   [ -x "$REFUTE" ]   || { echo "verify-findings.sh: run-refute.sh not found/executable at $REFUTE" >&2; exit 3; } ;;
  poc)      [ -x "$POC" ]      || { echo "verify-findings.sh: run-poc.sh not found/executable at $POC" >&2; exit 3; } ;;
  symbolic) [ -x "$SYMBOLIC" ] || { echo "verify-findings.sh: run-symbolic.sh not found/executable at $SYMBOLIC" >&2; exit 3; } ;;
esac

REPO_NAME="$(basename "$REPO")"
WORK="$OUT/.verify-work"; rm -rf "$WORK"; mkdir -p "$WORK"
CELLS="$OUT/gates"; rm -rf "$CELLS"; mkdir -p "$CELLS"
CONFIRMED_TSV="$WORK/confirmed.tsv"; : > "$CONFIRMED_TSV"

# The gate-specific CONFIRMED token: refute=REAL, poc=FINDING, symbolic=COUNTEREXAMPLE.
case "$GATE" in
  refute)   CONFIRM_TOKEN="REAL" ;;
  poc)      CONFIRM_TOKEN="FINDING" ;;
  symbolic) CONFIRM_TOKEN="COUNTEREXAMPLE" ;;
esac

# --- parse discovery-results.json -> a per-candidate work manifest (python3, the read-only parse). Splits each
#     cells[].candidates[] on `|` into <file:fn:line>|<classid>|<severity>|<exploit>|<poc sketch> and derives the
#     code file = the part before the FIRST `:` of the location. One TSV line per candidate; this NEVER writes
#     back to discovery-results.json.
python3 - "$RESULTS" > "$WORK/candidates.tsv" <<'PY'
import sys, json
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = []
for cell in data.get("cells", []):
    subsystem = cell.get("subsystem", "")
    for cand in cell.get("candidates", []):
        parts = cand.split("|", 4)
        while len(parts) < 5:
            parts.append("")
        location, classid, severity, exploit, sketch = parts[0], parts[1], parts[2], parts[3], parts[4]
        codefile = location.split(":", 1)[0]
        # TAB-safe: candidate fields ride a single JSON string line (no tabs / newlines); scrub defensively.
        fields = [subsystem, location, codefile, classid, severity, exploit, sketch]
        fields = [f.replace("\t", " ").replace("\n", " ") for f in fields]
        rows.append("\t".join(fields))
sys.stdout.write("\n".join(rows))
if rows:
    sys.stdout.write("\n")
PY

# run_gate_refute <out> <location> <class> <severity> <exploit> <relfile> -> writes <out>/verdict.txt as
# "<VERDICT>\t<reason>"; returns 0 when the gate RAN (any verdict, incl. no-verdict -> REFUTED), non-zero only
# when the gate itself errored (so the caller SKIPS that candidate). The refuter report row is `| <location> |
# <class> | <VERDICT> | <reason> |`; we read field 4/5 of the single data row.
run_gate_refute() {
  rg_out="$1"; rg_loc="$2"; rg_cls="$3"; rg_sev="$4"; rg_expl="$5"; rg_relfile="$6"
  mkdir -p "$rg_out"
  printf '%s|%s|%s|%s|%s\n' "$rg_loc" "$rg_cls" "$rg_sev" "$rg_expl" "$rg_relfile" > "$rg_out/candidate.manifest"
  if [ -n "$BRIEF" ]; then
    "$REFUTE" --candidates "$rg_out/candidate.manifest" --code-dir "$REPO" --brief "$BRIEF" \
      --backend "$BACKEND" --agentis "$AGENTIS" --out "$rg_out/refute-out" >"$rg_out/gate.log" 2>&1 || return 1
  else
    "$REFUTE" --candidates "$rg_out/candidate.manifest" --code-dir "$REPO" \
      --backend "$BACKEND" --agentis "$AGENTIS" --out "$rg_out/refute-out" >"$rg_out/gate.log" 2>&1 || return 1
  fi
  rg_report="$rg_out/refute-out/refute-report.md"
  [ -f "$rg_report" ] || { printf 'REFUTED\tno refute report produced (dropped as unverified)\n' > "$rg_out/verdict.txt"; return 0; }
  awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r);
        print v "\t" r; found=1; exit } }
    END { if (!found) print "REFUTED\tno verdict row (dropped as unverified)" }
  ' "$rg_report" > "$rg_out/verdict.txt"
  return 0
}

# run_gate_poc <out> <class> <exploit> <relfile> -> the concrete-PoC gate. CONFIRMED = FINDING.
run_gate_poc() {
  rp_out="$1"; rp_cls="$2"; rp_expl="$3"; rp_relfile="$4"
  mkdir -p "$rp_out"
  rp_target="$(basename "$rp_relfile")"
  "$POC" --repo "$REPO" --target "$rp_target" --hypothesis "$rp_expl" --class "$rp_cls" \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$rp_out/poc-out" >"$rp_out/gate.log" 2>&1 || return 1
  rp_line="$(grep 'POC|' "$rp_out/gate.log" | tail -1 || true)"
  if [ -z "$rp_line" ]; then
    printf 'NO-POC\tno POC verdict line produced (dropped as unverified)\n' > "$rp_out/verdict.txt"; return 0
  fi
  rp_verd="$(printf '%s' "$rp_line" | sed 's/^.*\(POC|\)/\1/' | cut -d'|' -f3)"
  printf '%s\t%s\n' "$rp_verd" "concrete PoC gate over $rp_target" > "$rp_out/verdict.txt"
  return 0
}

# run_gate_symbolic <out> <location> <class> <exploit> <relfile> -> the Halmos gate. CONFIRMED = COUNTEREXAMPLE.
run_gate_symbolic() {
  rs_out="$1"; rs_loc="$2"; rs_cls="$3"; rs_expl="$4"; rs_relfile="$5"
  mkdir -p "$rs_out"
  printf '%s|%s|%s|%s|\n' "$rs_loc" "$rs_cls" "$rs_expl" "$rs_relfile" > "$rs_out/candidate.manifest"
  "$SYMBOLIC" --candidates "$rs_out/candidate.manifest" --repo "$REPO" --code-dir "$REPO" \
    --backend "$BACKEND" --agentis "$AGENTIS" --out "$rs_out/symbolic-out" >"$rs_out/gate.log" 2>&1 || return 1
  rs_line="$(grep 'SYMBOLIC|' "$rs_out/gate.log" | tail -1 || true)"
  if [ -z "$rs_line" ]; then
    printf 'INCONCLUSIVE\tno SYMBOLIC verdict line produced (dropped as unverified)\n' > "$rs_out/verdict.txt"; return 0
  fi
  rs_verd="$(printf '%s' "$rs_line" | sed 's/^.*\(SYMBOLIC|\)/\1/' | cut -d'|' -f3)"
  printf '%s\t%s\n' "$rs_verd" "symbolic (Halmos) gate over $rs_loc" > "$rs_out/verdict.txt"
  return 0
}

CANDIDATES=0 ; VERIFIED=0 ; SKIPPED=0
# Candidate loop: drive the selected gate over each candidate with per-candidate isolation. A gate that ERRORS
# is logged + SKIPPED (never fatal); an un-CONFIRMED candidate is DROPPED. Only a CONFIRMED verdict is kept.
while IFS='	' read -r SUBSYS LOCATION CODEFILE CLASS SEVERITY EXPLOIT SKETCH || [ -n "${SUBSYS:-}" ]; do
  [ -n "$LOCATION" ] || continue
  CANDIDATES=$((CANDIDATES + 1))
  SLUG="$(printf '%s' "$LOCATION" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
  CELL_OUT="$CELLS/${CANDIDATES}_${SLUG}"
  echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) ..." >&2
  case "$GATE" in
    refute)   run_gate_refute   "$CELL_OUT" "$LOCATION" "$CLASS" "$SEVERITY" "$EXPLOIT" "$CODEFILE" || { echo "verify-findings.sh: gate errored for $LOCATION (see $CELL_OUT/gate.log); skipping" >&2; SKIPPED=$((SKIPPED + 1)); continue; } ;;
    poc)      run_gate_poc      "$CELL_OUT" "$CLASS" "$EXPLOIT" "$CODEFILE" || { echo "verify-findings.sh: gate errored for $LOCATION (see $CELL_OUT/gate.log); skipping" >&2; SKIPPED=$((SKIPPED + 1)); continue; } ;;
    symbolic) run_gate_symbolic "$CELL_OUT" "$LOCATION" "$CLASS" "$EXPLOIT" "$CODEFILE" || { echo "verify-findings.sh: gate errored for $LOCATION (see $CELL_OUT/gate.log); skipping" >&2; SKIPPED=$((SKIPPED + 1)); continue; } ;;
  esac
  VERD="$(cut -f1 "$CELL_OUT/verdict.txt")"
  REASON="$(cut -f2- "$CELL_OUT/verdict.txt")"
  if [ "$VERD" = "$CONFIRM_TOKEN" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$SUBSYS" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT" "$SKETCH" "$VERD" "$REASON" >> "$CONFIRMED_TSV"
    VERIFIED=$((VERIFIED + 1))
    echo "verify-findings.sh:   -> CONFIRMED ($VERD)" >&2
  else
    echo "verify-findings.sh:   -> dropped ($VERD)" >&2
  fi
done < "$WORK/candidates.tsv"

# --- aggregate CONFIRMED-only -> verified_findings.json (python3 json.dumps, the repo convention; seam-3 schema).
VERIFIED_JSON="$OUT/verified_findings.json"
REPO_NAME="$REPO_NAME" GATE="$GATE" CANDIDATES="$CANDIDATES" VERIFIED="$VERIFIED" \
python3 - "$CONFIRMED_TSV" > "$VERIFIED_JSON" <<'PY'
import sys, os, json
verified = []
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 9:
            f.append("")
        verified.append({
            "subsystem": f[0], "location": f[1], "file": f[2], "class": f[3],
            "severity": f[4], "exploit": f[5], "poc_sketch": f[6],
            "verdict": f[7], "reason": f[8],
        })
out = {
    "repo": os.environ.get("REPO_NAME", ""),
    "gate": os.environ.get("GATE", ""),
    "verified": verified,
    "totals": {
        "candidates": int(os.environ.get("CANDIDATES", "0")),
        "verified": int(os.environ.get("VERIFIED", "0")),
    },
}
print(json.dumps(out, indent=2))
PY

echo >&2
echo "================ VERIFY [$GATE]: $CANDIDATES candidate(s), $VERIFIED confirmed, $SKIPPED skipped ================" >&2
echo "verify-findings.sh: verified findings at $VERIFIED_JSON" >&2
if [ "$VERIFIED" -gt 0 ]; then
  echo "verify-findings.sh: NEXT = run the human-gated submission pass over each verified finding (run-audit-pass.sh); submission stays human-gated." >&2
else
  echo "verify-findings.sh: no candidate survived the $GATE gate — a rigorous negative. Nothing to package, nothing submitted." >&2
fi
