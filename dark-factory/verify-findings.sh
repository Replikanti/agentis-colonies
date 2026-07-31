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
#   --jobs <N>          OPT-IN bounded-concurrency fan-out over the CANDIDATE gates (#1863; default N=1 =
#                       serial = today's exact statement sequence). Gate up to N candidates CONCURRENTLY:
#                       STAGE 4 is the SERIAL TAIL of a zone hunt (~4 min per refute gate x every candidate
#                       the merge produced) and each candidate's gate is independent of the others.
#                       Concurrency is HARD-CAPPED at min(N, LLM_MAX_VERIFY_GATES=4) so N concurrent
#                       `agentis go` / forge / solc processes cannot OOM-thrash a single host — the cap NEVER
#                       fails open. That env knob is deliberately SEPARATE from run-discovery.sh's
#                       LLM_MAX_DISCOVERY_CELLS: STAGE 3 and STAGE 4 are sequential stages, so their ceilings
#                       are tuned independently and never stack.
#                       STORE ISOLATION (already true serially, made explicit here): every candidate's gate
#                       runs in its OWN <out>/gates/<n>_<slug>/refute-out rundir, which run-refute.sh
#                       `rm -rf`s + `agentis init`s on every invocation, and each invocation is handed
#                       EXACTLY ONE manifest line. So the `learning.enabled` / `experience.enabled` store is
#                       created fresh for ONE candidate and never read again: there is NO cross-candidate
#                       refuter reweighting on EITHER path, and a verdict never depends on the candidate's
#                       position in the manifest. --jobs > 1 therefore loses no steering — there is none.
#                       C6 STAYS INSIDE ITS SLOT: run-refute.sh's #1699 C6 fallback is a SEQUENTIAL step of
#                       its own manifest loop, and this script backgrounds exactly ONE subshell per
#                       candidate, so peak agentis concurrency is effective_jobs, never effective_jobs x 2.
#                       The rule: fan-out lives in THIS launch loop and nothing below it backgrounds work.
#                       Aggregation is DEFERRED until the pool drains and then replayed in MANIFEST order
#                       (preflight-ERROR and gate-ERROR rows interleaved exactly as the serial path emits
#                       them), so verified[] / errors[] / totals are byte-identical to the serial run.
#                       Needs bash >= 4.3 (`wait -n`); an older bash degrades to serial with a notice.
#   -h, --help          This help.
#
# Exit: 0 on a clean run that reached its aggregate (even with zero survivors — a rigorous negative is valid);
#       2 usage error; 3 missing prerequisite.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd)"
AGENTIS="agentis"
RESULTS="" ; REPO="" ; OUT="" ; GATE="refute" ; BRIEF="" ; BACKEND="flat-cyborg"
JOBS=1  # #1863: opt-in bounded-concurrency gate fan-out; 1 = serial, today's exact statement sequence.

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
    --jobs)    nv "$#"; JOBS="$2"; shift 2 ;;
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
# #1863: --jobs is a POSITIVE integer, validated before any side effect (same shape as run-discovery.sh).
case "$JOBS" in ''|*[!0-9]*) echo "verify-findings.sh: --jobs must be a positive integer (got '$JOBS')" >&2; exit 2 ;; esac
[ "$JOBS" -ge 1 ] || { echo "verify-findings.sh: --jobs must be >= 1 (got '$JOBS')" >&2; exit 2; }
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

# #1863: the concurrency ceiling. Effective parallelism = min(--jobs, GATE_CAP); the cap is HARD (never
# fail-open) so N concurrent gates — each an `agentis go` LLM session, and under --gate poc/symbolic also a
# repo copy + a build — cannot OOM-thrash a single host. Conservative default 4; tune per host via
# LLM_MAX_VERIFY_GATES, which is deliberately NOT run-discovery.sh's LLM_MAX_DISCOVERY_CELLS: STAGE 3 and
# STAGE 4 are sequential stages, so one forwarded --jobs can never stack the two ceilings.
GATE_CAP="${LLM_MAX_VERIFY_GATES:-4}"
case "$GATE_CAP" in ''|*[!0-9]*) GATE_CAP=4 ;; esac
[ "$GATE_CAP" -ge 1 ] || GATE_CAP=4
effective_jobs="$JOBS"
# --jobs > 1 uses `wait -n` (bash >= 4.3). On an older bash, degrade to the serial path rather than misbehave.
if [ "$JOBS" -gt 1 ]; then
  if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 3 ]; }; then
    echo "verify-findings.sh: --jobs > 1 needs bash >= 4.3 (wait -n) — running serially instead" >&2
    JOBS=1
    effective_jobs=1
  elif [ "$effective_jobs" -gt "$GATE_CAP" ]; then
    echo "verify-findings.sh: --jobs $JOBS exceeds the hard cap LLM_MAX_VERIFY_GATES=$GATE_CAP; clamping concurrency to $GATE_CAP" >&2
    effective_jobs="$GATE_CAP"
  fi
fi

REPO_NAME="$(basename "$REPO")"
# #1861: the refute gate stages exactly ONE file, so a candidate anchored in an abstract base is judged with
# no implementation of it in view — the measured "…in this contract contains no…" refutation. lib/inheritance.py
# names the representative implementor and auditor/slice-fns.sh cuts it down to the members that carry the
# base's virtual behaviour. Both are OPTIONAL: either one missing means no aux, and a byte-identical manifest.
INHERITANCE="$HERE/lib/inheritance.py"
SLICER="$HERE/auditor/slice-fns.sh"
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
#     code file via bare_codefile() — the hunter sometimes decorates the location with an `@func` compound suffix
#     or a `:~(test/File.t.sol:test_fn)` parenthetical (#1691), so a naive split(":",1)[0] yields a path that is
#     never on disk and the candidate is then silently dropped as if rigorously refuted. bare_codefile strips the
#     decorations back to a resolvable repo-relative source path. Also flags a MALFORMED candidate (blank class OR
#     severity = a truncated record) so the loop can ERROR it loudly instead of landing a content-less finding.
#     One TSV line per candidate; this NEVER writes back to discovery-results.json.
python3 - "$RESULTS" > "$WORK/candidates.tsv" <<'PY'
import sys, json


def bare_codefile(location):
    # Reduce a (possibly decorated) location to the bare repo-relative source path. Strip order is PINNED and is
    # a no-op on an already-well-formed `file:function[:line]` shape (asserted in demo-verify-findings.sh):
    s = location
    s = s.split("~", 1)[0]    # (A) drop a `:~(test/File.t.sol:test_fn)` test-reference tail (and its colons)
    s = s.split(":", 1)[0]    # (B) the file is the part before the FIRST ':' delimiter
    s = s.split("@", 1)[0]    # (C) drop a compound `@func` suffix
    s = s.strip().rstrip("(").strip()  # (D) trim whitespace and a stray trailing '('
    return s


data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = []
for cell in data.get("cells", []):
    subsystem = cell.get("subsystem", "")
    for cand in cell.get("candidates", []):
        parts = cand.split("|", 4)
        while len(parts) < 5:
            parts.append("")
        location, classid, severity, exploit, sketch = parts[0], parts[1], parts[2], parts[3], parts[4]
        codefile = bare_codefile(location)
        # A blank class OR severity is the signature of a truncated record — route it to ERROR, never a finding.
        malformed = "1" if (classid.strip() == "" or severity.strip() == "") else "0"
        # TAB-safe: candidate fields ride a single JSON string line (no tabs / newlines); scrub defensively.
        fields = [subsystem, location, codefile, classid, severity, exploit, sketch, malformed]
        fields = [f.replace("\t", " ").replace("\n", " ") for f in fields]
        rows.append("\t".join(fields))
sys.stdout.write("\n".join(rows))
if rows:
    sys.stdout.write("\n")
PY

# resolve_aux_code <out> <relfile> -> prints the absolute path of a staged, function-sliced implementation
# APPENDIX for <relfile>, or nothing (#1861). Fires only when <relfile> declares an `abstract contract` with
# body-less `virtual` members AND a descendant elsewhere in the repo implements at least one of them; the
# whole helper degrades to "no aux" on every other input, so a target with no abstract bases produces a
# byte-identical gate manifest. Also writes <out>/aux.txt — the per-candidate record of WHAT was attached, so
# a verdict that turns on the appendix is attributable from the artifacts alone.
resolve_aux_code() {
  ra_out="$1"; ra_relfile="$2"
  [ -f "$INHERITANCE" ] && [ -x "$SLICER" ] || return 0
  ra_hit="$(python3 "$INHERITANCE" implementor --repo "$REPO" --file "$ra_relfile" 2>/dev/null || true)"
  [ -n "$ra_hit" ] || return 0
  ra_impl="$(printf '%s\n' "$ra_hit" | head -1 | cut -f1)"
  ra_fns="$(printf '%s\n' "$ra_hit" | head -1 | cut -f2)"
  [ -n "$ra_impl" ] && [ -n "$ra_fns" ] && [ -f "$REPO/$ra_impl" ] || return 0
  "$SLICER" "$REPO/$ra_impl" "$ra_fns" > "$ra_out/aux.sol" 2>/dev/null || { rm -f "$ra_out/aux.sol"; return 0; }
  [ -s "$ra_out/aux.sol" ] || { rm -f "$ra_out/aux.sol"; return 0; }
  printf '%s@%s\n' "$ra_impl" "$ra_fns" > "$ra_out/aux.txt"
  printf '%s' "$ra_out/aux.sol"
}

# run_gate_refute <out> <location> <class> <severity> <exploit> <relfile> -> writes <out>/verdict.txt as
# "<VERDICT>\t<reason>"; returns 0 when the gate RAN (any verdict, incl. no-verdict -> REFUTED), non-zero only
# when the gate itself errored (so the caller SKIPS that candidate). The refuter report row is `| <location> |
# <class> | <VERDICT> | <reason> |`; we read field 4/5 of the single data row.
run_gate_refute() {
  rg_out="$1"; rg_loc="$2"; rg_cls="$3"; rg_sev="$4"; rg_expl="$5"; rg_relfile="$6"
  mkdir -p "$rg_out"
  # #1861: the OPTIONAL 6th manifest column. No hit -> the line has five fields, byte-identical to today.
  rg_aux="$(resolve_aux_code "$rg_out" "$rg_relfile")"
  if [ -n "$rg_aux" ]; then
    echo "verify-findings.sh:   + implementation appendix for the abstract base $rg_relfile: $(cat "$rg_out/aux.txt")" >&2
    printf '%s|%s|%s|%s|%s|%s\n' "$rg_loc" "$rg_cls" "$rg_sev" "$rg_expl" "$rg_relfile" "$rg_aux" > "$rg_out/candidate.manifest"
  else
    printf '%s|%s|%s|%s|%s\n' "$rg_loc" "$rg_cls" "$rg_sev" "$rg_expl" "$rg_relfile" > "$rg_out/candidate.manifest"
  fi
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
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { r=$5; sub(/^[[:space:]]+/,"",r); sub(/[[:space:]]+$/,"",r);
        print v "\t" r; found=1; exit } }
    END { if (!found) print "REFUTED\tno verdict row (dropped as unverified)" }
  ' "$rg_report" > "$rg_out/verdict.txt"
  # #1699: also scrape the WINNING class from the same (first) data row. run-refute.sh's #1699 C6 fallback can
  # convert a candidate REFUTED under its assigned class into REAL under C6 and emits the report row with the
  # class it SURVIVED under — read that back so verified_findings.json records C6, not the mislabelled input.
  awk -F'|' '
    NF>=5 { v=$4; gsub(/[[:space:]]/,"",v);
      if (v=="REAL"||v=="REFUTED"||v=="ERROR") { c=$3; gsub(/[[:space:]]/,"",c); print c; exit } }
  ' "$rg_report" > "$rg_out/eff-class.txt"
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

CANDIDATES=0 ; VERIFIED=0 ; SKIPPED=0 ; ERRORED=0
ERRORS_TSV="$WORK/errored.tsv"; : > "$ERRORS_TSV"

# --- factored per-candidate primitives (#1863). The serial loop and the deferred parallel pass call these
# IDENTICALLY; only the DISPATCH differs between the two paths, so the block that decides verified[] /
# errors[] membership and ORDER — the likeliest place for a silent serial-vs-parallel divergence — exists in
# exactly ONE copy. All shared state (the counters, confirmed.tsv, errored.tsv) is mutated by the PARENT
# shell only; a backgrounded job writes solely inside its own per-candidate gates/<n>_<slug>/ directory. ---

# gate_candidate <cell_out> <location> <class> <severity> <exploit> <codefile> — dispatch the operator-selected
# gate for ONE candidate. Returns the gate's rc: 0 = the gate RAN (any verdict), non-zero = the gate itself
# errored (the caller SKIPS that candidate). run_gate_refute / run_gate_poc / run_gate_symbolic are untouched.
gate_candidate() {
  gc_out="$1"; gc_loc="$2"; gc_cls="$3"; gc_sev="$4"; gc_expl="$5"; gc_file="$6"
  case "$GATE" in
    refute)   run_gate_refute   "$gc_out" "$gc_loc" "$gc_cls" "$gc_sev" "$gc_expl" "$gc_file" ;;
    poc)      run_gate_poc      "$gc_out" "$gc_cls" "$gc_expl" "$gc_file" ;;
    symbolic) run_gate_symbolic "$gc_out" "$gc_loc" "$gc_cls" "$gc_expl" "$gc_file" ;;
  esac
}

# record_errored <location> <codefile> <reason> <status> — the ONE place a candidate lands in errors[]: the
# TSV append, the counter bump and the `-> ERRORED (<status>)` operator line. <status> keeps the two callers'
# distinct wording (the #1691 preflight's `ERROR_MALFORMED: …` vs the gate-propagated `ERROR` token).
record_errored() {
  re_loc="$1"; re_file="$2"; re_reason="$3"; re_status="$4"
  printf '%s\t%s\t%s\n' "$re_loc" "$re_file" "$re_reason" >> "$ERRORS_TSV"
  ERRORED=$((ERRORED + 1))
  echo "verify-findings.sh:   -> ERRORED ($re_status)" >&2
}

# classify_candidate <gate_rc> <cell_out> <subsys> <location> <codefile> <class> <severity> <exploit> <sketch>
# — everything the walk does with a gated candidate that is not the gate call itself: the gate-errored SKIP,
# the verdict read, the ERROR route into errors[], the CONFIRMED append into confirmed.tsv (#1699 effective
# class included) and the dropped line. A gate_rc that is not 0 — INCLUDING a missing or empty gate.rc under
# --jobs > 1, which the caller normalises to 1 — is the SKIPPED path: a background job the OOM killer took is
# a visibly unassessed candidate, never a silent drop and never a confirmed finding.
classify_candidate() {
  cc_rc="$1"; cc_out="$2"; cc_subsys="$3"; cc_loc="$4"; cc_file="$5"
  cc_cls="$6"; cc_sev="$7"; cc_expl="$8"; cc_sketch="$9"
  if [ "$cc_rc" -ne 0 ]; then
    echo "verify-findings.sh: gate errored for $cc_loc (see $cc_out/gate.log); skipping" >&2
    SKIPPED=$((SKIPPED + 1))
    return 0
  fi
  cc_verd="$(cut -f1 "$cc_out/verdict.txt")"
  cc_reason="$(cut -f2- "$cc_out/verdict.txt")"
  if [ "$cc_verd" = "ERROR" ]; then
    # A gate that PROPAGATED an ERROR token (e.g. run-refute.sh's loud unresolvable-code row) — errored, not
    # refuted (change 2 pre-validates, so this belt-and-suspenders path is rarely reached inside the pipeline).
    record_errored "$cc_loc" "$cc_file" "$cc_reason" "$cc_verd"
  elif [ "$cc_verd" = "$CONFIRM_TOKEN" ]; then
    # #1699: for the refute gate, record the class the candidate actually SURVIVED under (run-refute.sh's C6
    # fallback may differ from the originally-assigned class), so verified_findings.json is not mislabelled.
    cc_eff_class="$cc_cls"
    if [ "$GATE" = "refute" ] && [ -s "$cc_out/eff-class.txt" ]; then
      cc_eff="$(cat "$cc_out/eff-class.txt")"
      [ -n "$cc_eff" ] && [ "$cc_eff" != "$cc_cls" ] && cc_eff_class="$cc_eff"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$cc_subsys" "$cc_loc" "$cc_file" "$cc_eff_class" "$cc_sev" "$cc_expl" "$cc_sketch" "$cc_verd" "$cc_reason" >> "$CONFIRMED_TSV"
    VERIFIED=$((VERIFIED + 1))
    echo "verify-findings.sh:   -> CONFIRMED ($cc_verd)" >&2
  else
    echo "verify-findings.sh:   -> dropped ($cc_verd)" >&2
  fi
  return 0
}

# #1863 parallel bookkeeping: ONE row per candidate, pushed in MANIFEST order by the launch loop and replayed
# by the deferred pass below. Untouched (and unread) on the serial path. PJ_PREFLIGHT carries the #1691
# preflight reason when the candidate never reached a gate — the row is NOT emitted inline, because emitting
# preflight errors during the launch loop while gate-ERROR verdicts land in the drain pass would GROUP them
# instead of interleaving them, and errors[] would then differ between --jobs 1 and --jobs > 1 on any target
# carrying both kinds.
PJ_OUT=() ; PJ_SUBSYS=() ; PJ_LOC=() ; PJ_FILE=() ; PJ_CLS=() ; PJ_SEV=() ; PJ_EXPL=() ; PJ_SKETCH=() ; PJ_PREFLIGHT=()
live=0

# Candidate loop: drive the selected gate over each candidate with per-candidate isolation. A gate that ERRORS
# is logged + SKIPPED (never fatal); an un-CONFIRMED candidate is DROPPED. Only a CONFIRMED verdict is kept.
# A candidate whose normalized code file does NOT resolve on disk, or whose required fields were lost to
# truncation (MALFORMED), is routed to a distinguishable ERRORED status BEFORE the gate runs (#1691) — it is
# never counted as a rigorous REFUTED verdict and never lands a content-less finding in verified[].
# Read one raw TSV line at a time (IFS= so leading/trailing whitespace is preserved) and split with `cut`: a
# tab-whitespace `read` COLLAPSES consecutive empty fields, which would mis-align a truncated candidate's blank
# class/severity and drop the trailing MALFORMED flag — cut preserves every field, empty ones included.
# The parse block below is shared by both paths, so CELL_OUT stays index-stable and artifact paths never move.
while IFS= read -r CANDROW || [ -n "${CANDROW:-}" ]; do
  [ -n "$CANDROW" ] || continue
  SUBSYS="$(printf '%s\n' "$CANDROW" | cut -f1)"
  LOCATION="$(printf '%s\n' "$CANDROW" | cut -f2)"
  CODEFILE="$(printf '%s\n' "$CANDROW" | cut -f3)"
  CLASS="$(printf '%s\n' "$CANDROW" | cut -f4)"
  SEVERITY="$(printf '%s\n' "$CANDROW" | cut -f5)"
  EXPLOIT="$(printf '%s\n' "$CANDROW" | cut -f6)"
  SKETCH="$(printf '%s\n' "$CANDROW" | cut -f7)"
  MALFORMED="$(printf '%s\n' "$CANDROW" | cut -f8)"
  [ -n "$LOCATION" ] || continue
  CANDIDATES=$((CANDIDATES + 1))
  SLUG="$(printf '%s' "$LOCATION" | tr -cs 'A-Za-z0-9' '_' | sed 's/_*$//')"
  CELL_OUT="$CELLS/${CANDIDATES}_${SLUG}"
  EREASON=""
  if [ "${MALFORMED:-0}" = "1" ] || [ ! -f "$REPO/$CODEFILE" ]; then
    if [ "${MALFORMED:-0}" = "1" ]; then
      EREASON="malformed candidate (blank class/severity — truncated record)"
    else
      EREASON="code file not found: $CODEFILE"
    fi
  fi
  if [ "$JOBS" -le 1 ]; then
    # SERIAL path (default): today's exact statement sequence — preflight ERROR + continue, else the
    # "verifying …" line, the gate, and the classification, inline and in manifest order. Writes NO new artifact.
    if [ -n "$EREASON" ]; then
      record_errored "$LOCATION" "$CODEFILE" "$EREASON" "ERROR_MALFORMED: $EREASON"
      continue
    fi
    echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) ..." >&2
    GATE_RC=0
    gate_candidate "$CELL_OUT" "$LOCATION" "$CLASS" "$SEVERITY" "$EXPLOIT" "$CODEFILE" || GATE_RC=1
    classify_candidate "$GATE_RC" "$CELL_OUT" "$SUBSYS" "$LOCATION" "$CODEFILE" "$CLASS" "$SEVERITY" "$EXPLOIT" "$SKETCH"
    continue
  fi
  # PARALLEL path (#1863, --jobs > 1): record the candidate in manifest order, then — unless the #1691
  # preflight already disqualified it — wait for a free slot and background EXACTLY ONE gate subshell for it.
  # Nothing is classified here; the deferred pass below owns every row of verified[] and errors[].
  PJ_OUT+=("$CELL_OUT") ; PJ_SUBSYS+=("$SUBSYS") ; PJ_LOC+=("$LOCATION") ; PJ_FILE+=("$CODEFILE")
  PJ_CLS+=("$CLASS") ; PJ_SEV+=("$SEVERITY") ; PJ_EXPL+=("$EXPLOIT") ; PJ_SKETCH+=("$SKETCH")
  PJ_PREFLIGHT+=("$EREASON")
  if [ -n "$EREASON" ]; then
    continue
  fi
  while [ "$live" -ge "$effective_jobs" ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done
  echo "verify-findings.sh: [$GATE] verifying $LOCATION ($CLASS) ..." >&2
  mkdir -p "$CELL_OUT"
  # The subshell's ONLY stdout is the rc byte; the gates route their own output into gates/<n>_<slug>/gate.log.
  # stdin is /dev/null so a child can never consume the parent's candidates.tsv read.
  ( gate_candidate "$CELL_OUT" "$LOCATION" "$CLASS" "$SEVERITY" "$EXPLOIT" "$CODEFILE" && printf 0 || printf 1 ) \
    > "$CELL_OUT/gate.rc" </dev/null &
  live=$((live + 1))
done < "$WORK/candidates.tsv"

if [ "$JOBS" -gt 1 ]; then
  # Drain the pool FIRST — no candidate is classified while any gate is still running.
  while [ "$live" -gt 0 ]; do
    wait -n 2>/dev/null || true
    live=$((live - 1))
  done
  # Deferred aggregation: ONE pass over the recorded rows in MANIFEST order, so verified[], errors[] (the
  # #1691 preflight rows and the gate-propagated ERROR rows INTERLEAVED exactly as serial emits them) and the
  # totals are independent of completion order. A missing or EMPTY gate.rc — the shape a killed background
  # job leaves behind, since the redirect creates the file before the gate runs — is read as rc 1.
  pidx=0 ; pn=${#PJ_OUT[@]}
  while [ "$pidx" -lt "$pn" ]; do
    if [ -n "${PJ_PREFLIGHT[$pidx]}" ]; then
      record_errored "${PJ_LOC[$pidx]}" "${PJ_FILE[$pidx]}" "${PJ_PREFLIGHT[$pidx]}" "ERROR_MALFORMED: ${PJ_PREFLIGHT[$pidx]}"
    else
      GATE_RC=1
      if [ -s "${PJ_OUT[$pidx]}/gate.rc" ]; then
        GATE_RC="$(cat "${PJ_OUT[$pidx]}/gate.rc")"
      fi
      case "$GATE_RC" in ''|*[!0-9]*) GATE_RC=1 ;; esac
      classify_candidate "$GATE_RC" "${PJ_OUT[$pidx]}" "${PJ_SUBSYS[$pidx]}" "${PJ_LOC[$pidx]}" \
        "${PJ_FILE[$pidx]}" "${PJ_CLS[$pidx]}" "${PJ_SEV[$pidx]}" "${PJ_EXPL[$pidx]}" "${PJ_SKETCH[$pidx]}"
    fi
    pidx=$((pidx + 1))
  done
fi

# --- aggregate CONFIRMED-only -> verified_findings.json (python3 json.dumps, the repo convention; seam-3 schema).
#     totals.errored + errors[] (#1691) make a malformed/unresolvable candidate DISTINGUISHABLE from a rigorous
#     REFUTED verdict — the true rigorous-refutation count = candidates - verified - errored. Additive only:
#     existing keys are preserved, so verified[]-reading consumers (run-zone-hunt.sh, corpus-bench) are unaffected.
VERIFIED_JSON="$OUT/verified_findings.json"
REPO_NAME="$REPO_NAME" GATE="$GATE" CANDIDATES="$CANDIDATES" VERIFIED="$VERIFIED" ERRORED="$ERRORED" \
python3 - "$CONFIRMED_TSV" "$ERRORS_TSV" > "$VERIFIED_JSON" <<'PY'
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
errors = []
with open(sys.argv[2], encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        f = line.split("\t")
        while len(f) < 3:
            f.append("")
        errors.append({"location": f[0], "file": f[1], "reason": f[2]})
out = {
    "repo": os.environ.get("REPO_NAME", ""),
    "gate": os.environ.get("GATE", ""),
    "verified": verified,
    "errors": errors,
    "totals": {
        "candidates": int(os.environ.get("CANDIDATES", "0")),
        "verified": int(os.environ.get("VERIFIED", "0")),
        "errored": int(os.environ.get("ERRORED", "0")),
    },
}
print(json.dumps(out, indent=2))
PY

echo >&2
echo "================ VERIFY [$GATE]: $CANDIDATES candidate(s), $VERIFIED confirmed, $ERRORED errored (malformed/unresolvable), $SKIPPED skipped ================" >&2
echo "verify-findings.sh: verified findings at $VERIFIED_JSON" >&2
if [ "$VERIFIED" -gt 0 ]; then
  echo "verify-findings.sh: NEXT = run the human-gated submission pass over each verified finding (run-audit-pass.sh); submission stays human-gated." >&2
else
  echo "verify-findings.sh: no candidate survived the $GATE gate — a rigorous negative. Nothing to package, nothing submitted." >&2
fi
