#!/usr/bin/env bash
# demo-invariant-transient.sh — proof of the #2033 TRANSIENT-vs-GENUINE run-failure classification in
# evm-harness/forge-invariant.sh.
#
# The bug (#2033): under concurrent deep-hunt batch load (many cells + flat-cyborg sessions + forge builds
# competing for CPU/RAM) a VALID harness's forge invariant run gets STARVED — OOM-killed, SIGTERM'd, or timed
# out — producing NO parseable result. Today that collapses to HARNESS_ERROR (2), identical to a GENUINE compile
# error, so the operator records an "untestable zone" for a harness that deterministically PASSES when re-run
# alone (measured live on enzyme-onyx: 3/15 cells, 20%). The fix RETRIES the run when the failure lacks a
# deterministic compile-error signature AND the harness statically declares an invariant, and — if the retries
# are exhausted — returns a NEW exit code 3 = TRANSIENT_ERROR (a re-runnable verdict) instead of HARNESS_ERROR.
#
# This demo is FORGE-STUB based — it needs NO real forge/toolchain, so it runs on CI. A tiny `forge` shim on
# PATH simulates each failure/success mode; the gate is invoked WITHOUT --require-import so the #1471 linkage
# gate is inert and ONLY the run-classification is exercised. It has TWO parts:
#   1) LIVE STUB classification (always, CI-safe): five cases (a)-(e) pinning genuine-vs-transient telling-apart,
#      the retry-recovery (AC1), the no-invariant fast-fail, and the fork-mode regression guard.
#   2) SOURCE-GUARD (always): the verdict propagates through run-invariant-hunt.sh's allowlist + run-zone-hunt.sh's
#      lens matrix, and the --deep-hunt-resume terminal check still treats ONLY CLEAN|FINDING as terminal (so a
#      TRANSIENT_ERROR cell is non-terminal and re-runs on resume).
#
# Usage:  dark-factory/demo-invariant-transient.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
GATE="$HERE/evm-harness/forge-invariant.sh"
RIH="$HERE/run-invariant-hunt.sh"
RZH="$HERE/run-zone-hunt.sh"

FAILS=0
note() { echo "demo-invariant-transient.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$GATE" ] || { note "gate not found: $GATE" >&2; exit 3; }
[ -f "$RIH" ]  || { note "runner not found: $RIH" >&2; exit 3; }
[ -f "$RZH" ]  || { note "zone runner not found: $RZH" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --- forge STUB: no real toolchain. Behaviour is switched by $STUB_MODE on the --json run; the gate's second
# (no-json, human-readable) run is a harmless no-op here because the verdict is decided by the --json parse. ---
STUBDIR="$WORK/bin"
mkdir -p "$STUBDIR"
cat > "$STUBDIR/forge" <<'STUB'
#!/usr/bin/env bash
is_json=0
for a in "$@"; do [ "$a" = "--json" ] && is_json=1; done
# The human (no-json) re-run: verdict already decided by the --json parse — emit nothing, succeed.
[ "$is_json" -eq 0 ] && exit 0
case "${STUB_MODE:-}" in
  compile)
    # GENUINE compile error: a deterministic solc/forge signature on stderr, no stdout.
    printf '%s\n' 'Compiler run failed' >&2
    printf '%s\n' 'Error (7920): Identifier not found or not unique.' >&2
    exit 1 ;;
  transient)
    # STARVED run: no stdout (unparseable), NO compile-error signature.
    printf '%s\n' 'fuzzing interrupted under load — no result produced' >&2
    exit 1 ;;
  recover)
    # First --json attempt is starved; a later attempt returns a valid all-pass suite (AC1: retry recovers).
    n=0
    [ -f "$STUB_STATE" ] && n="$(cat "$STUB_STATE")"
    printf '%s' "$((n + 1))" > "$STUB_STATE"
    if [ "$n" -eq 0 ]; then
      printf '%s\n' 'fuzzing interrupted under load — no result produced' >&2
      exit 1
    fi
    printf '%s\n' '{"test/Inv.t.sol:InvTest":{"test_results":{"invariant_property()":{"status":"Success"}}}}'
    exit 0 ;;
  *)
    printf '%s\n' 'demo forge stub: STUB_MODE unset' >&2
    exit 2 ;;
esac
STUB
chmod +x "$STUBDIR/forge"

# A throwaway foundry project + two harnesses (one declares an invariant_, one does not).
printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 8\ndepth = 4\nfail_on_revert = false\n' > "$WORK/foundry.toml"
mkdir -p "$WORK/src" "$WORK/test"
cat > "$WORK/test/Inv.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract InvTest {
  function invariant_property() public pure { require(true, "x"); }
}
SOL
cat > "$WORK/test/NoInv.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract NoInvTest {
  function test_thing() public pure { require(true, "x"); }
}
SOL

# Run the gate with the stub on PATH; captures combined output + rc. Retries/backoff pinned to a fast, single
# extra attempt so the transient path is deterministic and the demo stays quick.
run_gate() { # <mode> <target> [extra gate args...]
  local mode="$1" target="$2"; shift 2
  STUB_MODE="$mode" STUB_STATE="$WORK/state" \
  FORGE_INVARIANT_RETRIES=1 FORGE_INVARIANT_RETRY_BACKOFF_S=0 \
  PATH="$STUBDIR:$PATH" \
    sh "$GATE" --repo "$WORK" --target "$target" --match invariant "$@" 2>&1
}

note "1) LIVE stub classification (no real forge) ..."

# (a) GENUINE compile error -> exit 2, NO retry (the compile-error signature short-circuits).
rm -f "$WORK/state"
out="$(run_gate compile test/Inv.t.sol)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'suspected transient starvation'; then
  ok "(a) genuine compile error -> HARNESS_ERROR (2), NOT retried (deterministic signature short-circuits)"
else
  bad "(a) compile error should be HARNESS_ERROR (2) with no retry, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/        | /' | tail -6
fi

# (b) STARVED run, harness declares an invariant, no signature -> retried, then exit 3 TRANSIENT_ERROR.
rm -f "$WORK/state"
out="$(run_gate transient test/Inv.t.sol)"; rc=$?
if [ "$rc" -eq 3 ] \
   && printf '%s' "$out" | grep -q 'suspected transient starvation' \
   && printf '%s' "$out" | grep -q 'TRANSIENT_ERROR'; then
  ok "(b) starved run (declares invariant, no compile signature) -> retried then TRANSIENT_ERROR (3)"
else
  bad "(b) starved run should retry then exit 3 TRANSIENT_ERROR, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/        | /' | tail -6
fi

# (c) STARVED once then a valid all-pass suite -> exit 0 CLEAN (AC1: the retry recovers a valid harness).
rm -f "$WORK/state"
out="$(run_gate recover test/Inv.t.sol)"; rc=$?
if [ "$rc" -eq 0 ] \
   && printf '%s' "$out" | grep -q 'suspected transient starvation' \
   && printf '%s' "$out" | grep -q 'CLEAN'; then
  ok "(c) starved-then-recovers -> CLEAN (0) after one retry (AC1: a valid harness is not lost to load)"
else
  bad "(c) starved-then-recovers should be CLEAN (0) after a retry, got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/        | /' | tail -6
fi

# (d) STARVED run but the harness declares NO invariant_ -> exit 2 (genuine: nothing to run, never retried).
rm -f "$WORK/state"
out="$(run_gate transient test/NoInv.t.sol)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'TRANSIENT_ERROR'; then
  ok "(d) no invariant_ declared -> HARNESS_ERROR (2), never TRANSIENT (a no-result with nothing to run is genuine)"
else
  bad "(d) no-invariant harness should be HARNESS_ERROR (2), got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/        | /' | tail -6
fi

# (e) FORK MODE regression guard: --fork-url excludes the transient path entirely -> exit 2, byte-identical to
#     today (protects demo-fork-hunt.sh's contract: a dead fork RPC is HARNESS_ERROR, never TRANSIENT).
rm -f "$WORK/state"
out="$(run_gate transient test/Inv.t.sol --fork-url http://127.0.0.1:1)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q 'TRANSIENT_ERROR'; then
  ok "(e) fork mode (--fork-url) stays HARNESS_ERROR (2) on a no-result — transient path excluded (byte-identical)"
else
  bad "(e) fork mode should stay HARNESS_ERROR (2), got rc=$rc"
  printf '%s\n' "$out" | sed 's/^/        | /' | tail -6
fi

note "2) SOURCE-GUARD: the verdict propagates through the runners + resume ..."

# run-invariant-hunt.sh's verdict allowlist (both the get_verdict case and the ensemble aggregation) accepts it.
if grep -Fq 'FINDING|CLEAN|HARNESS_ERROR|TRANSIENT_ERROR)' "$RIH" \
   && grep -q 'ENS_HAD_TRANSIENT' "$RIH"; then
  ok "run-invariant-hunt.sh allowlists TRANSIENT_ERROR + aggregates it with FINDING>TRANSIENT_ERROR>HARNESS_ERROR>CLEAN precedence"
else
  bad "run-invariant-hunt.sh does not carry TRANSIENT_ERROR through its allowlist / ensemble aggregation"
fi

# run-zone-hunt.sh's lens-matrix accepted set tabulates it distinctly from HARNESS_ERROR.
if grep -Fq '"FINDING", "CLEAN", "HARNESS_ERROR", "TRANSIENT_ERROR"' "$RZH"; then
  ok "run-zone-hunt.sh lens-matrix accepted set tabulates TRANSIENT_ERROR distinct from HARNESS_ERROR"
else
  bad "run-zone-hunt.sh lens-matrix accepted set does not include TRANSIENT_ERROR"
fi

# The --deep-hunt-resume terminal check must STILL treat only CLEAN|FINDING as terminal — so a TRANSIENT_ERROR
# cell is NON-terminal and re-runs on resume. Assert the terminal pattern is present AND unchanged (no TRANSIENT).
if grep -Fq '(CLEAN|FINDING)([[:space:]]|$)' "$RZH" \
   && ! grep -F '(CLEAN|FINDING' "$RZH" | grep -q 'TRANSIENT'; then
  ok "--deep-hunt-resume terminal check still matches ONLY CLEAN|FINDING -> a TRANSIENT_ERROR cell re-runs on resume"
else
  bad "--deep-hunt-resume terminal check changed — a TRANSIENT_ERROR cell must NOT be treated as terminal"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: forge-invariant.sh tells a starved/killed transient run (harness valid, RE-RUNNABLE -> TRANSIENT_ERROR 3)"
  note "      apart from a genuine compile error (HARNESS_ERROR 2), retries recover a valid harness, and the"
  note "      TRANSIENT_ERROR verdict propagates through the runners while staying non-terminal on resume."
  exit 0
fi
note "DEMO FAILED — a #2033 transient-classification assertion did not hold" >&2
exit 1
