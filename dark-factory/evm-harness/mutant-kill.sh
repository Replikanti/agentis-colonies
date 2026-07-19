#!/usr/bin/env bash
# mutant-kill.sh — the MUTATION-GUIDED invariant-quality harness for the stateful-invariant discovery
# track (#1724). It measures whether an invariant is any GOOD by the only standard that matters for a
# fuzzer: does it KILL a known-buggy mutant (the fuzzer breaks it) while SURVIVING the clean twin?
#
# The verdict is NEVER an LLM opinion — every fixture is driven through the SAME stateful-fuzzing gate the
# discovery track uses (evm-harness/forge-invariant.sh), and the gate's EXIT CODE is mapped straight to a
# kill result:
#     forge-invariant.sh exit 1 = FINDING       -> KILLED    (the invariant broke on this contract)
#     forge-invariant.sh exit 0 = CLEAN         -> SURVIVED  (the invariant held across every sequence)
#     forge-invariant.sh exit 2 = HARNESS_ERROR -> ERROR     (compile/setup problem — not a verdict)
#
# forge-invariant.sh is UNTOUCHED by this harness (same exit-code + `INVARIANT|` marker contract, same
# #1471 target-linkage discipline) — we only CALL it, reusing its identical verdict machinery. We call it
# directly (not through run-invariant-hunt.sh) so this harness has NO agentis dependency.
#
# CI has no forge, so if it is missing this prints a single [SKIP] line and exits 0 (mirroring
# demo-invariant-hunt.sh / the colony-lint skip convention) instead of failing. Install the toolchain:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge (built-in stateful invariant fuzzing)
#
# Two modes:
#   --self-test
#       Iterate mutants/manifest.tsv. For each row, stage a throwaway foundry project (canonical
#       foundry.toml with an [invariant] runs/depth block + fail_on_revert=false, the contract fixture as
#       src/Target.sol, the invariant fixture as test/Inv.t.sol), run forge-invariant.sh with a FIXED seed,
#       map the exit to KILLED/SURVIVED/ERROR, and assert it equals the row's `expected` column. Prints a
#       per-row line + a summary matrix; exits non-zero on ANY mismatch or ERROR.
#
#   --class <c> --invariant <path>
#       Offline QUALITY METRIC (the acceptance-gate seam, use-a). Run the given invariant against EVERY
#       mutant in class <c> (mutants/<c>/*.mutant-*.sol), print KILLED/SURVIVED per mutant + the kill ratio.
#
# Usage:
#   mutant-kill.sh --self-test [--runs N] [--depth D] [--seed S]
#   mutant-kill.sh --class <TARGET_CLASS> --invariant <Invariant.t.sol> [--runs N] [--depth D] [--seed S]
#
# Exit: 0 = SKIP (no forge) OR (self-test) every row matched expected OR (class metric) ran to completion ;
#       non-zero = a self-test row mismatched/errored, or a usage/harness error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/forge-invariant.sh"
MUTANTS_DIR="$HERE/mutants"
MANIFEST="$MUTANTS_DIR/manifest.tsv"

MODE=""
CLASS=""
INVARIANT=""
SEED="1"          # FIXED seed keeps every run reproducible (the discovery track pins one too)
RUNS="256"
DEPTH="64"

note() { echo "mutant-kill.sh: $*"; }
skip() { echo "  [SKIP] $*"; }

usage() { sed -n '31,45p' "$0" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) MODE="self-test"; shift ;;
    --class)     MODE="class"; CLASS="${2:-}"; shift 2 ;;
    --invariant) INVARIANT="${2:-}"; shift 2 ;;
    --seed)      SEED="${2:-}"; shift 2 ;;
    --runs)      RUNS="${2:-}"; shift 2 ;;
    --depth)     DEPTH="${2:-}"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) note "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

[ -n "$MODE" ] || { note "one of --self-test | --class <c> --invariant <path> is required" >&2; usage; exit 2; }
[ -f "$GATE" ] || { note "gate not found: $GATE" >&2; exit 2; }

# --- SKIP EARLY (before any work) when the toolchain is missing ---------------------------------
# CI without forge reports a clean [SKIP] + exit 0 rather than a harness error, exactly like
# demo-invariant-hunt.sh. This is the operator's live self-test step; source-guards run without forge.
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the mutant kill-set"
  exit 0
fi

# --- run one (contract fixture, invariant fixture) pair through the gate -------------------------
# Stages a throwaway foundry project and returns the mapped verdict in $VERDICT and the gate output in
# $GATE_OUT. Every dynamic value is passed as a DISTINCT argv element — never concatenated into a flag —
# so no path content can mangle a forge-invariant.sh option (the repo's exec-sh safety idiom, in shell).
VERDICT=""
GATE_OUT=""
run_pair() {
  _cf="$1"; _if="$2"
  VERDICT=""; GATE_OUT=""
  if [ ! -f "$_cf" ]; then GATE_OUT="missing contract fixture: $_cf"; VERDICT=ERROR; return; fi
  if [ ! -f "$_if" ]; then GATE_OUT="missing invariant fixture: $_if"; VERDICT=ERROR; return; fi
  _tmp="$(mktemp -d "${TMPDIR:-/tmp}/mutant-kill.XXXXXX")" || { GATE_OUT="cannot create temp dir"; VERDICT=ERROR; return; }
  mkdir -p "$_tmp/src" "$_tmp/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = %s\ndepth = %s\nfail_on_revert = false\n' \
    "$RUNS" "$DEPTH" > "$_tmp/foundry.toml"
  cp "$_cf" "$_tmp/src/Target.sol"
  cp "$_if" "$_tmp/test/Inv.t.sol"
  GATE_OUT="$(sh "$GATE" --repo "$_tmp" --target "$_tmp/test/Inv.t.sol" --match invariant \
               --seed "$SEED" --runs "$RUNS" --depth "$DEPTH" 2>&1)"
  _rc=$?
  case "$_rc" in
    1) VERDICT=KILLED ;;     # FINDING       -> the invariant broke on this contract
    0) VERDICT=SURVIVED ;;   # CLEAN         -> the invariant held
    *) VERDICT=ERROR ;;      # HARNESS_ERROR -> compile/setup problem, not a verdict
  esac
  rm -rf "$_tmp"
}

# ================================================================================================
# MODE: --self-test — iterate the manifest, assert each row's verdict matches its `expected` column.
# ================================================================================================
if [ "$MODE" = "self-test" ]; then
  [ -f "$MANIFEST" ] || { note "manifest not found: $MANIFEST" >&2; exit 2; }
  note "mutant kill-set self-test (gate=$(basename "$GATE"), seed=$SEED, runs=$RUNS, depth=$DEPTH)"
  echo

  FAILS=0; ROWS=0
  MATRIX=""
  while IFS="$(printf '\t')" read -r cls cf iff exp rest || [ -n "$cls" ]; do
    case "$cls" in ''|'#'*) continue ;; esac
    [ -n "$cf" ] && [ -n "$iff" ] && [ -n "$exp" ] || { note "malformed manifest row: $cls" >&2; FAILS=$((FAILS+1)); continue; }
    ROWS=$((ROWS+1))
    run_pair "$MUTANTS_DIR/$cls/$cf" "$MUTANTS_DIR/$cls/$iff"
    if [ "$VERDICT" = "$exp" ]; then
      printf '  [OK]   %-13s %-30s x %-28s -> %-8s (expected %s)\n' "$cls" "$cf" "$iff" "$VERDICT" "$exp"
      MATRIX="${MATRIX}  PASS  ${cls}  ${cf} x ${iff}  ${VERDICT}
"
    else
      printf '  [FAIL] %-13s %-30s x %-28s -> %-8s (expected %s)\n' "$cls" "$cf" "$iff" "$VERDICT" "$exp"
      printf '%s\n' "$GATE_OUT" | sed 's/^/         | /' | tail -6
      MATRIX="${MATRIX}  FAIL  ${cls}  ${cf} x ${iff}  ${VERDICT} (want ${exp})
"
      FAILS=$((FAILS+1))
    fi
  done < "$MANIFEST"

  echo
  note "summary matrix ($ROWS rows):"
  printf '%s' "$MATRIX"
  echo
  if [ "$FAILS" -eq 0 ] && [ "$ROWS" -gt 0 ]; then
    note "PASS: every mutant kill-set row matched its expected verdict — the good invariants KILL their"
    note "      mutants and SURVIVE the clean twins, and the toothless controls MISS the mutants (real"
    note "      discrimination, judged by the forge-invariant.sh fuzzer, not an LLM)."
    exit 0
  fi
  note "SELF-TEST FAILED — $FAILS mismatch(es)/error(s) across $ROWS rows" >&2
  exit 1
fi

# ================================================================================================
# MODE: --class <c> --invariant <path> — offline QUALITY METRIC (the deferred acceptance-gate seam).
# Run the given invariant against EVERY mutant in the class; report KILLED/SURVIVED + the kill ratio.
# ================================================================================================
if [ "$MODE" = "class" ]; then
  [ -n "$CLASS" ] || { note "--class requires a class name" >&2; exit 2; }
  [ -n "$INVARIANT" ] || { note "--class mode requires --invariant <path>" >&2; exit 2; }
  CLASS_DIR="$MUTANTS_DIR/$CLASS"
  [ -d "$CLASS_DIR" ] || { note "no such class dir: $CLASS_DIR" >&2; exit 2; }
  if [ -f "$INVARIANT" ]; then INV_PATH="$INVARIANT"; elif [ -f "$CLASS_DIR/$INVARIANT" ]; then INV_PATH="$CLASS_DIR/$INVARIANT"; else
    note "invariant fixture not found: $INVARIANT" >&2; exit 2; fi

  note "class kill-ratio: $CLASS x $(basename "$INV_PATH") (seed=$SEED, runs=$RUNS, depth=$DEPTH)"
  echo

  MUTS=0; KILLED=0; ERRORS=0
  for _m in "$CLASS_DIR"/*.mutant-*.sol; do
    [ -f "$_m" ] || continue    # no-mutant class: the glob stays literal, skip it
    MUTS=$((MUTS+1))
    run_pair "$_m" "$INV_PATH"
    printf '  %-34s -> %s\n' "$(basename "$_m")" "$VERDICT"
    [ "$VERDICT" = "KILLED" ] && KILLED=$((KILLED+1))
    [ "$VERDICT" = "ERROR" ] && ERRORS=$((ERRORS+1))
  done

  echo
  if [ "$MUTS" -eq 0 ]; then
    note "no mutants found in $CLASS_DIR (expected <Name>.mutant-*.sol)" >&2
    exit 2
  fi
  _errnote=""
  [ "$ERRORS" -gt 0 ] && _errnote=" ($ERRORS harness error(s))"
  note "kill ratio: $KILLED / $MUTS killed$_errnote"
  exit 0
fi

usage; exit 2
