#!/usr/bin/env bash
# run-composable-lens-bench.sh — #1914 M4 (epic #1914). The TRANSFER bench for the class-agnostic
# general-solvency (SYS-solvency) deep-hunt lens: does it catch a composition-class High on >=2 DISTINCT corpus
# targets, not just the single surface it was shaped on?
#
# WHY A SEPARATE BENCH. run-corpus-bench.sh --hunt runs breadth + within-contract depth cells; it NEVER passes
# --deep-hunt, so the composable lens is never exercised there. This bench invokes run-zone-hunt.sh
# --deep-hunt --composable-lens over each selected corpus target and tabulates the SYS-solvency verdicts.
#
# THE TABULATION (composable-lens-tabulate.py owns the scoring):
#   * per target: {FINDING, CLEAN, HARNESS_ERROR} over the M3 lens-surface-matrix's general-solvency surfaces.
#     HARNESS_ERROR is a GAP (un-probed seam), counted DISTINCTLY from CLEAN — never a clean negative.
#   * ADVERSARY-PATH: a composable run that deploys `hooks: address(0)` is a VACUOUS CLEAN. A CLEAN/FINDING is
#     counted as MEANINGFUL only if the generated composable test source instantiated a NON-address(0)
#     adversarial actor (Handler/Hook/Adapter/Attacker). A run that never drove the adversary path is flagged
#     and NOT counted.
#   * CATCH = an adversary-DRIVEN FINDING. The M4 gate is CATCH on >=2 DISTINCT targets; the bench exits
#     non-zero when unmet so a live run's pass/fail is unambiguous.
#   * depth_per_zone (#1880 budget.depth_per_zone, the EFFECTIVE per-zone depth) is recorded next to every
#     number — a recall figure is quoted against THAT, never the nominal flag.
#
# TWO PATHS.
#   --self-test (default; CI-safe, no network / LLM / forge): drive the tabulation + adversary-path parsing +
#     catch-counting over SYNTHETIC FINDING/CLEAN/HARNESS_ERROR/vacuous inputs, AND run ONE real OFFLINE deep-hunt
#     --composable-lens over fixtures/deep-hunt/ through the --invariant-fixture + --agentis stub seam (no LLM /
#     forge / network) to prove the plumbing end to end. This is what colony-lint exercises.
#   --live (operator, by hand): clone the selected --id(s) via ../corpus-bench/fetch-corpus.sh, run
#     run-zone-hunt.sh --deep-hunt --composable-lens over each with the real backend, tabulate, and check the
#     M4 gate. NEVER run on CI. The real measurement is this path; the RESULTS table in BENCH.md is filled from it.
#
# Usage:
#   run-composable-lens-bench.sh [--self-test]
#   run-composable-lens-bench.sh --live --id <id> --id <id> [--work <dir>] [--backend <flat-cyborg|claude|mock>]
#                                [--corpus <corpus.tsv>] [--agentis <bin>] [--jobs <N>] [--json]
# Options:
#   --self-test       Offline deterministic acceptance (default when no mode flag is given).
#   --live            Real measurement: clone + hunt + tabulate. Requires >=2 --id (the transfer gate needs 2).
#   --id <id>         Corpus row to select (repeatable). corpus.tsv id (dodo, yieldoor, ...).
#   --work <dir>      Work dir for clones + zone-hunt output (default: ./composable-lens-bench-work).
#   --backend <b>     LLM backend for run-zone-hunt.sh (default: flat-cyborg, the federation default; ../../CLAUDE.md).
#   --corpus <file>   corpus.tsv manifest (default: ../corpus-bench/corpus.tsv).
#   --agentis <bin>   agentis binary (default: `agentis` on PATH).
#   --jobs <N>        run-zone-hunt.sh intra-zone concurrency (default 1).
#   --json            Print the machine-readable summary JSON (also always written to <work>/summary.json).
#   -h, --help        This help.
# Exit: 0 = self-test held / live gate MET ; 1 = self-test regressed / live gate UNMET ; 2 = bad args ;
#       3 = missing prerequisite / clone failed.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
DF="$(cd "$HERE/../.." && pwd)"                         # dark-factory/
ZONEHUNT="$DF/run-zone-hunt.sh"
TABULATE="$HERE/composable-lens-tabulate.py"
CORPUS_BENCH="$(cd "$HERE/../corpus-bench" && pwd)"
FETCHCORPUS="$CORPUS_BENCH/fetch-corpus.sh"
CORPUS="$CORPUS_BENCH/corpus.tsv"
FIX="$CORPUS_BENCH/fixtures/deep-hunt"

MODE="self-test"
IDS=""
WORK=""
BACKEND="flat-cyborg"
AGENTIS="agentis"
JOBS="1"
JSON=0
ID_ARGS=()

nv() { [ "$1" -ge 2 ] || { echo "run-composable-lens-bench.sh: missing value for the preceding flag" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --self-test) MODE="self-test"; shift;;
  --live)      MODE="live"; shift;;
  --id)        nv "$#" "$1"; IDS="$IDS $2"; ID_ARGS+=(--id "$2"); shift 2;;
  --work)      nv "$#" "$1"; WORK="$2"; shift 2;;
  --backend)   nv "$#" "$1"; BACKEND="$2"; shift 2;;
  --corpus)    nv "$#" "$1"; CORPUS="$2"; shift 2;;
  --agentis)   nv "$#" "$1"; AGENTIS="$2"; shift 2;;
  --jobs)      nv "$#" "$1"; JOBS="$2"; shift 2;;
  --json)      JSON=1; shift;;
  -h|--help)   sed -n '30,52p' "$0"; exit 0;;
  *) echo "run-composable-lens-bench.sh: unknown arg: $1" >&2; exit 2;;
esac; done

say() { echo "run-composable-lens-bench.sh: $*" >&2; }

command -v python3 >/dev/null 2>&1 || { say "python3 not installed"; exit 3; }
[ -f "$TABULATE" ] || { say "scoring core not found: $TABULATE"; exit 3; }

# ==========================================================================================================
# --live — the real measurement (operator, by hand; NEVER on CI).
# ==========================================================================================================
if [ "$MODE" = "live" ]; then
  [ -x "$ZONEHUNT" ] || { say "run-zone-hunt.sh not found/executable: $ZONEHUNT"; exit 3; }
  [ -x "$FETCHCORPUS" ] || { say "fetch-corpus.sh not found/executable: $FETCHCORPUS"; exit 3; }
  [ -f "$CORPUS" ] || { say "corpus manifest not found: $CORPUS"; exit 3; }
  # The transfer gate needs >=2 distinct targets — refuse a live run that cannot possibly meet it.
  n_ids="$(printf '%s\n' $IDS | grep -c . || true)"
  [ "$n_ids" -ge 2 ] || { say "--live needs >=2 --id (the transfer gate is >=2 DISTINCT catch targets); got $n_ids"; exit 2; }

  [ -n "$WORK" ] || WORK="$PWD/composable-lens-bench-work"
  mkdir -p "$WORK"; WORK="$(cd "$WORK" && pwd)"
  RECORDS="$WORK/records"; mkdir -p "$RECORDS"

  say "cloning selected corpus targets via fetch-corpus.sh ..."
  bash "$FETCHCORPUS" --out "$WORK" --corpus "$CORPUS" "${ID_ARGS[@]}" \
    || { say "fetch-corpus.sh failed"; exit 3; }

  while IFS=$'\t' read -r id _code _judging project_subdir scope_hint; do
    case "$id" in ""|\#*) continue;; esac
    if [ -n "$IDS" ]; then case " $IDS " in *" $id "*) : ;; *) continue;; esac; fi
    [ -n "$project_subdir" ] || { say "[$id] corpus.tsv row has no project_subdir; skipping"; continue; }
    code_dir="$WORK/$id/code/$project_subdir"
    [ -d "$code_dir" ] || { say "[$id] no cloned code at $code_dir"; continue; }
    out="$WORK/$id/zone-hunt-out"
    say "[$id] run-zone-hunt.sh --deep-hunt --composable-lens --backend $BACKEND over $code_dir ..."
    "$ZONEHUNT" --repo "$code_dir" --out "$out" --backend "$BACKEND" --jobs "$JOBS" \
      --agentis "$AGENTIS" --deep-hunt --composable-lens \
      ${scope_hint:+--scope-hint "$scope_hint"} \
      || say "  [$id] run-zone-hunt.sh exited non-zero; tabulating whatever it produced"
    python3 "$TABULATE" eval-target --id "$id" --out "$out" --out-record "$RECORDS/$id.json" \
      || say "  [$id] eval-target failed"
  done < "$CORPUS"

  SUMMARY_JSON="$WORK/summary.json"
  python3 "$TABULATE" summarize --records-dir "$RECORDS" --json > "$SUMMARY_JSON"
  python3 "$TABULATE" summarize --records-dir "$RECORDS"; GATE_RC=$?
  [ "$JSON" -eq 1 ] && cat "$SUMMARY_JSON"
  say "summary JSON: $SUMMARY_JSON"
  say "M4 gate: $([ "$GATE_RC" -eq 0 ] && echo MET || echo 'NOT MET') (>=2 distinct catch targets)"
  exit "$GATE_RC"
fi

# ==========================================================================================================
# --self-test (default) — offline, deterministic. Drives the scoring core over synthetic inputs, then runs ONE
# real OFFLINE deep-hunt --composable-lens over the fixture through the --invariant-fixture + --agentis stub seam.
# ==========================================================================================================
FAILS=0
ok()  { echo "  [PASS] $*"; }
bad() { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/composable-lens-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
# Isolate the hunt registry so this bench never writes into a live operator's
# ~/.dark-factory/hunts (run-zone-hunt.sh only registers when the dir exists).
export DARK_FACTORY_DIR="$WORK"

# --- synthetic out-dir builders ---------------------------------------------------------------------------
# A minimal M3 lens-surface-matrix with ONE general-solvency surface at $verd, plus one narrow surface (which
# must NOT be counted — only general-solvency surfaces carry a verdict).
write_matrix() {  # $1 = out dir, $2 = FINDING|CLEAN|HARNESS_ERROR
  mkdir -p "$1/coverage"
  cat > "$1/coverage/lens-surface-matrix.json" <<JSON
{
  "schema": "lens-surface-matrix/v1",
  "repo": "synthetic",
  "commit": "0000000",
  "surfaces": [
    {"id": "src", "name": "src", "value_custody": true, "composition": true, "order": 1, "lens_depth": "general-solvency", "verdict": "$2"},
    {"id": "periphery", "name": "periphery", "value_custody": false, "composition": true, "order": 2, "lens_depth": "narrow-per-class", "verdict": null}
  ]
}
JSON
}

# A generated composable test source that DRIVES the adversary path (a real non-address(0) Handler actor).
write_driven_source() {  # $1 = out dir
  mkdir -p "$1/deep-hunt/src-SYS-solvency/run"
  cat > "$1/deep-hunt/src-SYS-solvency/run/Composable.t.sol" <<'SOL'
// synthetic composable-fresh test with a real adversarial actor.
contract AdversaryHook { function beforeSettle() external {} }
contract SysInvariantTest {
    function setUp() public {
        AdversaryHook h = new AdversaryHook();
        _target(address(h));
    }
    function _target(address a) internal {}
    function invariant_no_free_value() public view {}
}
SOL
}

# A generated composable test source that is VACUOUS: the hook is wired to address(0) (no adversary drives the seam).
write_vacuous_source() {  # $1 = out dir
  mkdir -p "$1/deep-hunt/src-SYS-solvency/run"
  cat > "$1/deep-hunt/src-SYS-solvency/run/Composable.t.sol" <<'SOL'
// synthetic composable-fresh test that never drove the adversary path: hook = address(0).
interface IHook { function beforeSettle() external; }
contract SysInvariantTest {
    IHook hook = IHook(address(0));
    function setUp() public {}
    function invariant_no_free_value() public view {}
}
SOL
}

emit_record() {  # $1 = id, $2 = out dir, $3 = record dir
  python3 "$TABULATE" eval-target --id "$1" --out "$2" --out-record "$3/$1.json"
}

# ----------------------------------------------------------------------------------------------------------
# (1) TABULATION — per-target verdict counts, HARNESS_ERROR distinct from CLEAN.
# ----------------------------------------------------------------------------------------------------------
TA="$WORK/target-a"; write_matrix "$TA" FINDING; write_driven_source "$TA"
TB="$WORK/target-b"; write_matrix "$TB" FINDING; write_driven_source "$TB"
TC="$WORK/target-clean"; write_matrix "$TC" CLEAN; write_driven_source "$TC"
THE="$WORK/target-he"; write_matrix "$THE" HARNESS_ERROR; write_driven_source "$THE"
TV="$WORK/target-vacuous"; write_matrix "$TV" FINDING; write_vacuous_source "$TV"

REC="$WORK/records"; mkdir -p "$REC"
for pair in "target-a=$TA" "target-b=$TB" "target-clean=$TC" "target-he=$THE" "target-vacuous=$TV"; do
  id="${pair%%=*}"; dir="${pair#*=}"
  emit_record "$id" "$dir" "$REC" || bad "eval-target failed for $id"
done

# target-a: a driven FINDING is a CATCH; verdict source is the matrix.
if python3 - "$REC/target-a.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdicts"] == {"FINDING": 1, "CLEAN": 0, "HARNESS_ERROR": 0}, r["verdicts"]
assert r["catch"] is True and r["meaningful"] is True, r
assert r["verdict_source"] == "lens-surface-matrix", r["verdict_source"]
assert r["adversary_path"]["driven"] is True and r["adversary_path"]["actor"] == "AdversaryHook", r["adversary_path"]
PY
then ok "(1) matrix tabulation: a driven FINDING target is a CATCH (actor parsed, source=matrix)"
else bad "(1) driven FINDING target should be a CATCH"
fi

# target-clean: a driven CLEAN is meaningful but NOT a catch.
if python3 - "$REC/target-clean.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdicts"]["CLEAN"] == 1 and r["verdicts"]["FINDING"] == 0, r["verdicts"]
assert r["catch"] is False and r["meaningful"] is True, r
assert r["harness_error"] is False, r
PY
then ok "(1) matrix tabulation: a driven CLEAN is a rigorous NEGATIVE, not a catch"
else bad "(1) driven CLEAN mis-tabulated"
fi

# target-he: HARNESS_ERROR is counted DISTINCTLY from CLEAN and never as a catch.
if python3 - "$REC/target-he.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdicts"] == {"FINDING": 0, "CLEAN": 0, "HARNESS_ERROR": 1}, r["verdicts"]
assert r["harness_error"] is True and r["catch"] is False, r
PY
then ok "(1) HARNESS_ERROR is tabulated DISTINCTLY from CLEAN (a GAP, not a clean negative), never a catch"
else bad "(1) HARNESS_ERROR not distinct from CLEAN"
fi

# ----------------------------------------------------------------------------------------------------------
# (2) ADVERSARY-PATH — a FINDING from a vacuous (address(0)-hook) run is NOT a meaningful catch.
# ----------------------------------------------------------------------------------------------------------
if python3 - "$REC/target-vacuous.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdicts"]["FINDING"] == 1, r["verdicts"]
assert r["adversary_path"]["driven"] is False, r["adversary_path"]
assert r["adversary_path"]["zero_hook_seen"] is True, r["adversary_path"]
assert r["meaningful"] is False and r["catch"] is False, r
PY
then ok "(2) adversary-path: a FINDING from an address(0)-hook run is FLAGGED vacuous, NOT counted as a catch"
else bad "(2) vacuous adversary path counted as a catch"
fi

# adversary-scan standalone on the SHIPPED fixture handler (a real `new Handler(...)` actor) -> driven.
FIXSCAN="$WORK/fixscan"; mkdir -p "$FIXSCAN"
[ -f "$FIX/handler-fixture.t.sol" ] && cp "$FIX/handler-fixture.t.sol" "$FIXSCAN/handler.t.sol"
if [ -f "$FIXSCAN/handler.t.sol" ]; then
  python3 "$TABULATE" adversary-scan --dir "$FIXSCAN" --json > "$WORK/fixscan.json"
  if python3 - "$WORK/fixscan.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["driven"] is True, r
assert r["actor"] == "Handler", r
PY
  then ok "(2) adversary-scan: the shipped deep-hunt fixture handler DRIVES the adversary path (actor=Handler)"
  else bad "(2) adversary-scan mis-scored the shipped fixture handler"
  fi
else
  echo "  [SKIP] deep-hunt fixture handler not present at $FIX"
fi

# (2) QA #1924 regression: the Yul/assembly-style `hook := address(0)` wiring (two-char `:=`, NOT a bare `=`)
# alongside a real `new Handler(...)` MUST be FLAGGED vacuous — a `[=:(]` class silently missed `:=`, so this
# exact source was mis-scored a driven catch. A FINDING over it must therefore NOT count as a catch.
TQA="$WORK/target-qa-assign"; write_matrix "$TQA" FINDING
mkdir -p "$TQA/deep-hunt/src-SYS-solvency/run"
cat > "$TQA/deep-hunt/src-SYS-solvency/run/Composable.t.sol" <<'SOL'
// QA #1924 repro: a real adversarial actor is instantiated, but its hook is nulled with the assembly-style
// `:=` assignment — a vacuous run the `[=:(]` class let slip through as a false catch.
contract Handler { function attack() external {} }
contract SysInvariantTest {
    address hook;
    function setUp() public {
        Handler h = new Handler();
        assembly { sstore(hook.slot, 0) }
        hook := address(0);
    }
    function invariant_no_free_value() public view {}
}
SOL
python3 "$TABULATE" eval-target --id target-qa-assign --out "$TQA" --out-record "$WORK/target-qa-assign.json"
if python3 - "$WORK/target-qa-assign.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdicts"]["FINDING"] == 1, r["verdicts"]
assert r["adversary_path"]["zero_hook_seen"] is True, r["adversary_path"]      # the `:=` form is now detected
assert r["adversary_path"]["driven"] is False, r["adversary_path"]
assert r["meaningful"] is False and r["catch"] is False, r                     # vacuous => NOT a catch
PY
then ok "(2) QA #1924: a FINDING over 'new Handler(...) + hook := address(0)' is FLAGGED vacuous, NOT a catch (:= assembly-assignment form now detected)"
else bad "(2) QA #1924 assembly-assignment ':=' zero-hook slipped through as a false catch"
fi

# ----------------------------------------------------------------------------------------------------------
# (3) CATCH-COUNTING + the M4 gate (>=2 distinct catch targets).
# ----------------------------------------------------------------------------------------------------------
# Gate MET: two driven-FINDING targets.
REC_MET="$WORK/rec-met"; mkdir -p "$REC_MET"
cp "$REC/target-a.json" "$REC/target-b.json" "$REC_MET/"
python3 "$TABULATE" summarize --records-dir "$REC_MET" >/dev/null; MET_RC=$?
[ "$MET_RC" -eq 0 ] && ok "(3) gate MET on 2 distinct catch targets => exit 0" || bad "(3) gate should be MET on 2 catch targets (exit $MET_RC)"

# Gate UNMET: one catch + one clean (only 1 distinct catch target).
REC_UNMET="$WORK/rec-unmet"; mkdir -p "$REC_UNMET"
cp "$REC/target-a.json" "$REC/target-clean.json" "$REC_UNMET/"
python3 "$TABULATE" summarize --records-dir "$REC_UNMET" >/dev/null; UNMET_RC=$?
[ "$UNMET_RC" -eq 1 ] && ok "(3) gate UNMET on 1 catch target => exit 1 (unambiguous live pass/fail)" || bad "(3) gate should be UNMET on 1 catch target (exit $UNMET_RC)"

# The summary JSON records HARNESS_ERROR + vacuous targets distinctly and the catch set.
python3 "$TABULATE" summarize --records-dir "$REC" --json > "$WORK/summary-all.json" || true
if python3 - "$WORK/summary-all.json" <<'PY'
import sys, json
s = json.load(open(sys.argv[1]))
assert set(s["catch_targets"]) == {"target-a", "target-b"}, s["catch_targets"]
assert s["catch_target_count"] == 2 and s["gate_met"] is True, s
assert "target-he" in s["harness_error_targets"], s["harness_error_targets"]
assert "target-vacuous" in s["vacuous_targets"], s["vacuous_targets"]
PY
then ok "(3) summary JSON: catch set + HARNESS_ERROR + vacuous targets recorded distinctly"
else bad "(3) summary JSON did not record the categories distinctly"
fi

# ----------------------------------------------------------------------------------------------------------
# (4) LOG-FALLBACK — a run with NO matrix falls back to raw invariant_*.log, filtering per-candidate _c<N>.log.
# ----------------------------------------------------------------------------------------------------------
TL="$WORK/target-log"; mkdir -p "$TL/deep-hunt/src-SYS-solvency/run"; write_driven_source "$TL"
printf 'INVARIANT|src/Vault.sol:deposit|FINDING\n' > "$TL/deep-hunt/src-SYS-solvency/run/invariant_Vault.log"
# a per-candidate CLEAN log that MUST be ignored (the #1780 adapter's own filter).
printf 'INVARIANT|src/Vault.sol:deposit|CLEAN\n' > "$TL/deep-hunt/src-SYS-solvency/run/invariant_Vault_c1.log"
python3 "$TABULATE" eval-target --id target-log --out "$TL" --out-record "$WORK/target-log.json"
if python3 - "$WORK/target-log.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
assert r["verdict_source"] == "invariant-logs", r["verdict_source"]
assert r["verdicts"]["FINDING"] == 1 and r["verdicts"]["CLEAN"] == 0, r["verdicts"]
assert r["catch"] is True, r
PY
then ok "(4) log fallback: no-matrix run reads invariant_*.log (aggregate only, per-candidate _c<N>.log ignored)"
else bad "(4) log-fallback tabulation regressed"
fi

# ----------------------------------------------------------------------------------------------------------
# (5) END-TO-END OFFLINE — one real deep-hunt --composable-lens over the shipped fixture through the
# --invariant-fixture + --agentis stub seam (no LLM / forge / network), then tabulate its REAL artifacts.
# ----------------------------------------------------------------------------------------------------------
e2e_ok=1
if [ ! -x "$ZONEHUNT" ]; then echo "  [SKIP] run-zone-hunt.sh not executable: $ZONEHUNT"; e2e_ok=0; fi
command -v git >/dev/null 2>&1 || { echo "  [SKIP] git not installed — end-to-end offline block"; e2e_ok=0; }
for f in foundry.toml zones.fixture.txt briefs.fixture.txt handler-fixture.t.sol agentis-stub.sh; do
  [ -f "$FIX/$f" ] || { echo "  [SKIP] deep-hunt fixture missing: $FIX/$f"; e2e_ok=0; break; }
done
if [ "$e2e_ok" -eq 1 ]; then
  REPO="$WORK/e2e-target"; mkdir -p "$REPO"
  cp "$FIX/foundry.toml" "$REPO/foundry.toml"
  cp -R "$FIX/src" "$REPO/src"
  # A co-system contract in the SAME zone dir so the value-custody zone holds two .sol and the SYS-solvency row
  # can carry an aux (composable-fresh needs a co-system contract).
  cat > "$REPO/src/Strategy.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Co-system contract of the value-custody zone (never compiled here — the --agentis stub short-circuits
// generation); it exists so the zone holds a second .sol and the SYS-solvency row threads it as --aux.
contract Strategy { uint256 public deployed; function report(uint256 g) external { deployed += g; } }
SOL
  git -C "$REPO" init -q
  git -C "$REPO" config user.email demo@example.invalid
  git -C "$REPO" config user.name "demo"
  git -C "$REPO" add -A
  git -C "$REPO" commit -qm "composable-lens-bench e2e fixture target"

  STUB="$WORK/agentis-stub"; cp "$FIX/agentis-stub.sh" "$STUB"; chmod +x "$STUB"
  E2E_OUT="$WORK/e2e-out"
  "$ZONEHUNT" --repo "$REPO" --out "$E2E_OUT" --drop-dir "$E2E_OUT/drop" --scope-hint src \
    --backend mock --agentis "$STUB" \
    --map-fixture "$FIX/zones.fixture.txt" --brief-fixture "$FIX/briefs.fixture.txt" \
    --pass-fixture "scope=payable;devise=residual;poc=finding;impact=substantiated;dup=low;report=drafted" \
    --in-scope "the whole in-scope program" \
    --deep-hunt --composable-lens --invariant-fixture "$FIX/handler-fixture.t.sol" \
    >"$WORK/e2e.log" 2>&1
  E2E_RC=$?
  if [ "$E2E_RC" -ne 0 ]; then
    bad "(5) offline deep-hunt --composable-lens run exited $E2E_RC"
    tail -20 "$WORK/e2e.log" | sed 's/^/        /' >&2
  elif [ ! -f "$E2E_OUT/coverage/lens-surface-matrix.json" ]; then
    bad "(5) offline run produced no lens-surface-matrix.json"
  else
    E2E_REC="$WORK/e2e-rec"; mkdir -p "$E2E_REC"
    python3 "$TABULATE" eval-target --id e2e --out "$E2E_OUT" --out-record "$E2E_REC/e2e.json"
    if python3 - "$E2E_REC/e2e.json" <<'PY'
import sys, json
r = json.load(open(sys.argv[1]))
# The fixture stub's invariant-prover emits INVARIANT|src/Vault.sol:deposit|FINDING, so the SYS-solvency surface
# is a FINDING; the shipped handler-fixture instantiates a real `new Handler(...)` -> adversary-driven -> catch.
assert r["verdict_source"] == "lens-surface-matrix", r["verdict_source"]
assert r["verdicts"]["FINDING"] >= 1, r["verdicts"]
assert r["adversary_path"]["driven"] is True, r["adversary_path"]
assert r["catch"] is True, r
PY
    then ok "(5) end-to-end offline: real deep-hunt --composable-lens over the fixture -> a driven SYS-solvency FINDING (catch), tabulated from the real matrix"
    else bad "(5) end-to-end offline tabulation of the real matrix regressed"
    fi
  fi
fi

echo ""
if [ "$FAILS" -gt 0 ]; then
  echo "composable-lens-bench --self-test: $FAILS assertion(s) FAILED"
  exit 1
fi
echo "composable-lens-bench --self-test: all assertions held"
exit 0
