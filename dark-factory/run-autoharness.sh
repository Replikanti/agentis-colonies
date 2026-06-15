#!/usr/bin/env bash
# run-autoharness.sh — AUTONOMOUS harness generation + bug hunt. Given a target recon spec (deployed
# addresses + the relevant function signatures + chain/fork-block + a hunt goal), the LLM ($0 flat-cyborg
# backend) GENERATES a complete Foundry fork-fuzz harness on its own; a compile-repair loop fixes errors
# via the LLM; then the fuzzer hunts a deep solvency / no-free-value invariant against the REAL forked
# protocol. No human writes the harness. Proven: the LLM-generated harness reproducibly rediscovers the
# real Euler $197M audit-surviving bug on a fork at the pre-exploit block (and reports CLEAN on safe vaults).
#
# Usage: run-autoharness.sh (--spec <recon.txt> | --address <0x..> [--chain <id>]) --rpc <archive-rpc> --block <n>
#                           [--invariant "<text>"] [--repairs N] [--runs N] [--out <dir>]
#   --spec    : a text file describing the target (addresses, function signatures, the deep invariant).
#   --address : instead of a hand-written spec, auto-fetch the verified ABI keyless from Sourcify (no API key)
#               and build the recon spec from it — full chain: address -> recon -> harness -> hunt, no human.
# Requires: a flat-cyborg LLM backend wrapper on PATH (LLM_WRAP env or ./flat-cyborg-claude.sh), forge, an
# ARCHIVE RPC (forge fork execution at a historical block needs a true archive node).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAP="${LLM_WRAP:-$HERE/flat-cyborg-claude.sh}"
SPEC="" ; ADDR="" ; CHAIN="1" ; INV="" ; RPC="" ; BLK="" ; REPAIRS=6 ; RUNS=400 ; OUT=""
# nv: a value-taking flag must be followed by a value; under `set -u` a bare trailing flag would otherwise
# crash on $2 (unbound) instead of the promised exit 2. $1 = remaining argc ($#), $2 = the flag name.
nv() { [ "$1" -ge 2 ] || { echo "run-autoharness.sh: $2 requires a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do case "$1" in
  --spec) nv "$#" "$1"; SPEC="$2"; shift 2;; --address) nv "$#" "$1"; ADDR="$2"; shift 2;; --chain) nv "$#" "$1"; CHAIN="$2"; shift 2;;
  --invariant) nv "$#" "$1"; INV="$2"; shift 2;; --rpc) nv "$#" "$1"; RPC="$2"; shift 2;; --block) nv "$#" "$1"; BLK="$2"; shift 2;;
  --repairs) nv "$#" "$1"; REPAIRS="$2"; shift 2;; --runs) nv "$#" "$1"; RUNS="$2"; shift 2;; --out) nv "$#" "$1"; OUT="$2"; shift 2;;
  -h|--help) sed -n '2,14p' "$0"; exit 0;; *) echo "run-autoharness.sh: unknown arg $1" >&2; exit 2;; esac; done
[ -n "$RPC" ] && [ -n "$BLK" ] || { echo "run-autoharness.sh: --rpc and --block required" >&2; exit 2; }
command -v forge >/dev/null || { echo "[SKIP] forge not installed" >&2; exit 0; }
[ -x "$WRAP" ] || { echo "[SKIP] LLM backend wrapper not found ($WRAP); set LLM_WRAP" >&2; exit 0; }
WORK="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/autoharness.XXXXXX")}"; mkdir -p "$WORK/test"
# Auto-recon: --address with no --spec -> fetch ABI keyless from Sourcify and synthesize the recon spec.
if [ -z "$SPEC" ] && [ -n "$ADDR" ]; then
  SPEC="$WORK/recon.txt"
  "$HERE/recon-from-address.sh" --address "$ADDR" --chain "$CHAIN" ${INV:+--invariant "$INV"} --out "$SPEC" \
    || { echo "run-autoharness.sh: auto-recon failed for $ADDR" >&2; exit 1; }
  [ -s "$SPEC" ] || { echo "[SKIP] auto-recon produced no spec for $ADDR (not on Sourcify?); supply --spec" >&2; exit 0; }
fi
# -r (readable), not -f, so a piped spec works too — e.g. `recon-from-address.sh ... | run-autoharness --spec /dev/stdin`.
[ -r "$SPEC" ] || { echo "run-autoharness.sh: --spec <file> or --address <0x..> required" >&2; exit 2; }
printf '[profile.default]\ntest = "test"\nsolc = "0.8.24"\nevm_version = "cancun"\n' > "$WORK/foundry.toml"
PROMPT="$WORK/prompt.txt"
{ echo "You are an autonomous smart-contract bug-hunting harness generator. Output ONLY a single Solidity file (no markdown, no prose): a forge-std-FREE Foundry test, contract name AutoHarness, pragma ^0.8.24. Use the cheatcode interface at 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D (createSelectFork(string,uint256), envString, envUint, store, load). Fund the test contract by storage-slot scan + approve. Expose the protocol's primitive operations as fuzzable try/catch actions. Add a FUZZ test function testFuzz_hunt(uint256 seed) that derives a SEQUENCE of ops from the seed, executes them on the REAL forked protocol, then require()s the deep invariant. Fork via env ETH_RPC + the block below.";
  echo "=== TARGET RECON ==="; cat "$SPEC"; } > "$PROMPT"
SOL="$WORK/test/AutoHarness.t.sol"
# A REAL fork-fuzz harness — not a trivial compiling stub — must FORK the chain, expose a seed-derived FUZZ
# function, and assert a deep invariant. A bare `test_sanity()` that asserts `1+1==2` compiles cleanly but
# proves NOTHING, so the compile gate alone is not enough: a degenerate stub would otherwise yield a vacuous
# "CLEAN" verdict. Require the three structural markers before accepting the harness; absent any, keep
# repairing (and tell the LLM exactly what a real harness needs), then give up rather than hunt a stub.
real_harness() {
  grep -q 'createSelectFork' "$SOL" \
    && grep -qE 'function +testFuzz[A-Za-z_]*\([^)]*uint256' "$SOL" \
    && grep -q 'require(' "$SOL"
}
# Generate a harness with the flat-cyborg LLM backend ($WRAP), then strip any
# markdown fences and keep from the first SPDX/pragma line onward.
#
# flat-cyborg >=0.10.0 (set up in flat-cyborg-claude.sh with --wrap-input) makes
# delivery reliable at the source: it folds the long single-line instruction block
# so it no longer overflows claude's editor, and gates --extract on the reply
# sentinel so a slow first reply (the model emits chrome / thinks before answering)
# is no longer captured as empty. So no shell-side fold or retry is needed here; a
# rare empty extraction is already handled by the compile/real_harness repair loop
# below, which re-generates against a sharper prompt.
gen() {
  "$WRAP" < "$1" 2>/dev/null | sed -e 's/```[a-zA-Z]*//g' | awk 'f||/\/\/ SPDX|pragma/{f=1; print}'
}
ATT=0
gen "$PROMPT" > "$SOL"
while : ; do
  ERR="$( cd "$WORK" && forge build 2>&1 )"
  # forge build trivially "succeeds" on an empty dir, so also require a real AutoHarness contract AND the
  # fork-fuzz structure (real_harness) — a stub that compiles is rejected, not mistaken for a ready harness.
  if echo "$ERR" | grep -q 'Compiler run successful' && grep -q 'contract[[:space:]]\+AutoHarness' "$SOL" && real_harness; then
    echo "run-autoharness: real fork-fuzz harness COMPILES (attempt $ATT)"; break
  fi
  ATT=$((ATT+1)); [ "$ATT" -gt "$REPAIRS" ] && { echo "run-autoharness: gave up after $REPAIRS attempts — no real fork-fuzz harness (only a stub / non-compiling output)" >&2; exit 1; }
  # Re-state the FULL structural requirement (not just 'fix the compile error') + the recon spec, so the LLM
  # repairs toward a real fork-fuzz harness instead of degenerating into a trivial constant-asserting stub.
  { echo "Your previous Solidity output is REJECTED. Output ONLY one complete .sol file (no markdown, no prose): contract AutoHarness, pragma ^0.8.24, forge-std-FREE. It MUST be a REAL fork-fuzz harness, NOT a sanity test:";
    echo "  1. createSelectFork(envString(\"ETH_RPC\"), <FORK_BLOCK>) — fork the REAL chain at the block.";
    echo "  2. Expose each TARGET state-changing op below as a try/catch action against the real deployed address.";
    echo "  3. function testFuzz_hunt(uint256 seed): derive a SEQUENCE of those ops from seed, run them on the fork, then require() the deep solvency / no-free-value invariant.";
    echo "  A test that only asserts constants (e.g. 1+1==2) or omits the fork / the fuzz fn / the require() is WRONG and will be rejected again.";
    echo "--- COMPILE ERRORS (if any) ---"; echo "$ERR" | grep -iE 'error|-->' | head -20;
    echo "--- TARGET RECON ---"; cat "$SPEC";
    echo "--- YOUR REJECTED FILE ---"; cat "$SOL"; } > "$WORK/repair.txt"
  gen "$WORK/repair.txt" > "$SOL"
done
# Prefer the seed-derived testFuzz_ function (the real hunt) over any plain test_ helper the harness may also
# carry — real_harness() already guarantees a testFuzz fn exists, so this never falls back to a sanity test.
FN="$(grep -oE 'function +testFuzz[A-Za-z_]*' "$SOL" | head -1 | sed 's/function *//')"
[ -n "$FN" ] || FN="$(grep -oE 'function +test[A-Za-z_]*' "$SOL" | head -1 | sed 's/function *//')"
[ -n "$FN" ] || { echo "run-autoharness: no test/testFuzz function in generated harness (empty/truncated LLM output?)" >&2; exit 1; }
echo "run-autoharness: hunting via $FN (fork $RPC @ $BLK) ..."
HUNT="$( cd "$WORK" && ETH_RPC="$RPC" FORK_BLK="$BLK" FOUNDRY_FUZZ_RUNS="$RUNS" forge test --mt "$FN" --fork-url "$RPC" --fork-block-number "$BLK" 2>&1 )"
echo "$HUNT" | grep -iE '\[PASS\]|\[FAIL\]|VIOLAT|counterexample|Suite result'
# Structured verdict so this doubles as a SOUND coordinator gate (the verdict is the FUZZER's, never an LLM).
# A fuzzer can only CONFIRM a bug (it has a counterexample) or come up dry — it can NEVER prove safety, so a
# clean run is `dry` (exit 3), NOT a refutation. exit 1 = FINDING (counterexample), 3 = clean (no witness), 2 = no verdict.
if echo "$HUNT" | grep -qiE '\[FAIL\]|VIOLAT|counterexample'; then
  echo "run-autoharness: FINDING — invariant violated, the autonomous harness has a counterexample"; exit 1
elif echo "$HUNT" | grep -qi '\[PASS\]'; then
  echo "run-autoharness: CLEAN — no counterexample (fuzzing is unsound; this is NOT a proof of safety)"; exit 3
else
  echo "run-autoharness: NO VERDICT — harness/fork error, treated as non-productive"; exit 2
fi
