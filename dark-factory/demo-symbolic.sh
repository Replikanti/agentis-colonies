#!/usr/bin/env bash
# demo-symbolic.sh — reproducible proof of the #1015 M2 GENERATE-AND-VERIFY loop: a candidate is turned
# into a Halmos property spec and HALMOS (not the LLM) returns the SOUND verdict.
#
# This drives the FULL candidate -> spec -> halmos -> verdict loop through the substrate via
# `run-symbolic.sh` + `auditor/agents/symbolic-prover.ag`, using a FIXTURE spec (the offline/deterministic
# path — NO LLM, mock backend) and a REAL Halmos run. Two candidates exercise both sound verdicts:
#   - a candidate whose invariant Halmos PROVES         -> verdict PROVED         (lead refuted by a proof / safe)
#   - a candidate Halmos REFUTES with a counterexample  -> verdict COUNTEREXAMPLE (a real bug, CONFIRMED)
# The verdict is HALMOS's exit code, never the LLM's opinion — that is the whole point of M2. The loop is
# also run TWICE and the two reports diffed, so the offline path is deterministic.
#
# It reuses the M1 example contracts (`evm-harness/halmos-specs/`): the honest `transferSafe` invariant
# (Halmos PROVES) and the same invariant against the buggy `transferBuggy` (Halmos REFUTES). The fixtures
# ARE those M1 specs, fed to symbolic-prover.ag as SPEC_FIXTUREs so no LLM is needed for a sound, repeatable
# proof of the loop.
#
# CI has neither halmos nor forge, so if EITHER is missing this prints a single [SKIP] line and exits 0
# (mirroring demo-halmos.sh / the colony-lint skip convention) instead of failing. Install the toolchain to
# run it for real:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge
#   uv tool install halmos                                      # halmos (bundles z3)
#
# Usage:  dark-factory/demo-symbolic.sh
# Exit: 0 = both verdicts correct + deterministic (or tools absent -> SKIP) ; non-zero = a verdict was wrong.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-symbolic.sh"
SPECS="$HERE/evm-harness/halmos-specs"

FAILS=0
note() { echo "demo-symbolic.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# Skip EARLY (before any work) when the toolchain is missing, so CI without halmos/forge reports a clean
# [SKIP] + exit 0 rather than a harness error. agentis is required to drive the substrate loop.
if ! command -v forge >/dev/null 2>&1 || ! command -v halmos >/dev/null 2>&1; then
  skip "forge and/or halmos not on PATH — install foundryup + 'uv tool install halmos' to run this demo"
  exit 0
fi
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to drive the substrate generate-and-verify loop"
  exit 0
fi

[ -x "$RUNNER" ] || { note "runner not found / not executable: $RUNNER" >&2; exit 3; }
[ -d "$SPECS" ] || { note "specs dir not found: $SPECS" >&2; exit 3; }
[ -f "$SPECS/foundry.toml" ] || { note "specs dir is not a foundry project: $SPECS" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Stage the two M1 example specs as FIXTURES (the offline path: symbolic-prover uses them verbatim, no LLM)
# and build a candidate manifest: one PROVED candidate, one COUNTEREXAMPLE candidate.
cp "$SPECS/test/LedgerProved.t.sol" "$WORK/proved.t.sol"
cp "$SPECS/test/LedgerCounterexample.t.sol" "$WORK/counterexample.t.sol"
cat > "$WORK/candidates.tsv" <<'EOF'
# file:fn | class | invariant | code-file | spec-fixture
Ledger.sol:transferSafe  | C-acct | total value is conserved across a transfer | | proved.t.sol
Ledger.sol:transferBuggy | C-acct | total value is conserved across a transfer | | counterexample.t.sol
EOF

# Run the full substrate loop (mock backend = no LLM; the FIXTURE drives the spec, real Halmos judges).
# $1 = output dir.
run_loop() {
  "$RUNNER" --candidates "$WORK/candidates.tsv" --repo "$SPECS" \
            --code-dir "$WORK" --backend mock --out "$1" >"$1.log" 2>&1
}

note "driving candidate -> fixture-spec -> REAL Halmos -> verdict through the substrate (mock backend, no LLM) ..."
run_loop "$WORK/out1"; RC1=$?
REPORT1="$WORK/out1/symbolic-report.md"
if [ "$RC1" -ne 0 ] || [ ! -f "$REPORT1" ]; then
  bad "run-symbolic.sh did not complete (exit $RC1); log:"
  sed 's/^/        | /' "$WORK/out1.log" 2>/dev/null
  note "DEMO FAILED — the generate-and-verify loop did not run" >&2
  exit 1
fi

# Assert the per-candidate verdict in the report table. $1 = candidate file:fn, $2 = expected verdict.
assert_verdict() {
  _cand="$1"; _want="$2"
  _row="$(grep -F "| $_cand " "$REPORT1" | tail -1 || true)"
  _got="$(printf '%s' "$_row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}')"
  if [ "$_got" = "$_want" ]; then
    ok "$_cand -> $_want (Halmos's sound verdict, not the LLM's)"
  else
    bad "$_cand expected $_want, got '${_got:-<no row>}'"
  fi
}

assert_verdict "Ledger.sol:transferSafe" "PROVED"
assert_verdict "Ledger.sol:transferBuggy" "COUNTEREXAMPLE"

# Determinism: a second run of the offline path must produce a byte-identical verdict table.
run_loop "$WORK/out2" >/dev/null 2>&1
REPORT2="$WORK/out2/symbolic-report.md"
if [ -f "$REPORT2" ] && diff -q "$REPORT1" "$REPORT2" >/dev/null 2>&1; then
  ok "re-run is byte-identical (the offline fixture path is deterministic)"
else
  bad "re-run differs — the offline path is not deterministic"
  diff "$REPORT1" "$REPORT2" 2>/dev/null | sed 's/^/        | /'
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the LLM-as-generator / Halmos-as-judge loop PROVED the honest candidate's invariant (safe) and"
  note "      REFUTED the buggy one with a concrete counterexample (confirmed bug) — verdict is Halmos's, sound,"
  note "      and deterministic; generation used a fixture spec so no LLM was involved (#1015 M2)"
  exit 0
fi
note "DEMO FAILED — a verdict did not match the contract" >&2
exit 1
