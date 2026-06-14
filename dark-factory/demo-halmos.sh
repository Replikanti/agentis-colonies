#!/usr/bin/env bash
# demo-halmos.sh — reproducible proof that the #1015 Halmos symbolic-execution gate returns the right
# SOUND verdict on a known-good and a known-bad spec.
#
# Halmos is a deterministic solver (symbolic execution + z3), so a real run IS the deterministic proof —
# there is no mock and no sampling. The demo runs evm-harness/halmos-verify.sh against the two example
# specs under evm-harness/halmos-specs/ and asserts the contract:
#   - test/LedgerProved.t.sol         -> PROVED         (exit 0): the conservation invariant holds for ALL inputs
#   - test/LedgerCounterexample.t.sol -> COUNTEREXAMPLE (exit 1): a concrete input mints value (a planted bug)
#
# CI has neither halmos nor forge, so if EITHER is missing this prints a single [SKIP] line and exits 0
# (mirroring the colony-lint skip convention) instead of failing. Install the toolchain to run it for real:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge
#   uv tool install halmos                                      # halmos (bundles z3)
#
# Usage:  dark-factory/demo-halmos.sh
# Exit: 0 = both verdicts correct (or tools absent -> SKIP) ; non-zero = a verdict was wrong.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/evm-harness/halmos-verify.sh"
SPECS="$HERE/evm-harness/halmos-specs"

FAILS=0
note() { echo "demo-halmos.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# The gate itself exits 2 when the toolchain is missing, but we skip EARLY (before invoking it) so CI
# without halmos/forge reports a clean [SKIP] + exit 0 rather than a harness error.
if ! command -v forge >/dev/null 2>&1 || ! command -v halmos >/dev/null 2>&1; then
  skip "forge and/or halmos not on PATH — install foundryup + 'uv tool install halmos' to run this demo"
  exit 0
fi

[ -x "$GATE" ] || { note "gate not found / not executable: $GATE" >&2; exit 3; }
[ -d "$SPECS" ] || { note "specs dir not found: $SPECS" >&2; exit 3; }

# Run the gate and assert BOTH the verdict banner and the exit code. $1 = label, $2 = target spec,
# $3 = expected verdict token (PROVED|COUNTEREXAMPLE), $4 = expected exit code.
assert_verdict() {
  _label="$1"; _target="$2"; _want_verdict="$3"; _want_exit="$4"
  _out="$("$GATE" --repo "$SPECS" --target "$_target" 2>&1)"; _rc=$?
  _banner="$(printf '%s\n' "$_out" | grep -E 'HALMOS-VERIFY:' | tail -1 || true)"
  if [ "$_rc" -eq "$_want_exit" ] && printf '%s' "$_banner" | grep -q "HALMOS-VERIFY: ${_want_verdict}"; then
    ok "$_label -> $_want_verdict (exit $_rc)"
  else
    bad "$_label expected $_want_verdict / exit $_want_exit, got exit $_rc"
    printf '%s\n' "$_out" | sed 's/^/        | /'
  fi
}

note "running halmos-verify.sh against the two example specs (real solver, deterministic) ..."
assert_verdict "true invariant (transferSafe conserves value)" \
  "test/LedgerProved.t.sol" "PROVED" 0
assert_verdict "planted bug (transferBuggy mints value)" \
  "test/LedgerCounterexample.t.sol" "COUNTEREXAMPLE" 1
# Soundness guard: an under-unrolled loop must NOT pass as PROVED. Halmos reports `0 failed` but warns
# the loop was not fully explored, so the gate must return INCONCLUSIVE (exit 3), never a false proof.
assert_verdict "under-unrolled loop (true invariant, incomplete exploration)" \
  "test/LedgerInconclusive.t.sol" "INCONCLUSIVE" 3

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: Halmos PROVED the honest spec, REFUTED the buggy one with a concrete counterexample, and the"
  note "      gate refused to over-claim PROVED on an under-unrolled loop (returned INCONCLUSIVE) (#1015)"
  exit 0
fi
note "DEMO FAILED — a verdict did not match the contract" >&2
exit 1
