#!/usr/bin/env bash
# run-autoharness.sh — AUTONOMOUS harness generation + bug hunt. Given a target recon spec (deployed
# addresses + the relevant function signatures + chain/fork-block + a hunt goal), the LLM ($0 flat-cyborg
# backend) GENERATES a complete Foundry fork-fuzz harness on its own; a compile-repair loop fixes errors
# via the LLM; then the fuzzer hunts a deep solvency / no-free-value invariant against the REAL forked
# protocol. No human writes the harness. Proven: the LLM-generated harness reproducibly rediscovers the
# real Euler $197M audit-surviving bug on a fork at the pre-exploit block (and reports CLEAN on safe vaults).
#
# Usage: run-autoharness.sh --spec <recon.txt> --rpc <archive-rpc> --block <n> [--repairs N] [--runs N] [--out <dir>]
#   --spec : a text file describing the target (addresses, function signatures, the deep invariant to assert).
# Requires: a flat-cyborg LLM backend wrapper on PATH (LLM_WRAP env or ./flat-cyborg-claude.sh), forge, an
# ARCHIVE RPC (forge fork execution at a historical block needs a true archive node).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WRAP="${LLM_WRAP:-$HERE/flat-cyborg-claude.sh}"
SPEC="" ; RPC="" ; BLK="" ; REPAIRS=6 ; RUNS=400 ; OUT=""
while [ $# -gt 0 ]; do case "$1" in
  --spec) SPEC="$2"; shift 2;; --rpc) RPC="$2"; shift 2;; --block) BLK="$2"; shift 2;;
  --repairs) REPAIRS="$2"; shift 2;; --runs) RUNS="$2"; shift 2;; --out) OUT="$2"; shift 2;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;; *) echo "run-autoharness.sh: unknown arg $1" >&2; exit 2;; esac; done
[ -f "$SPEC" ] || { echo "run-autoharness.sh: --spec <file> required" >&2; exit 2; }
[ -n "$RPC" ] && [ -n "$BLK" ] || { echo "run-autoharness.sh: --rpc and --block required" >&2; exit 2; }
command -v forge >/dev/null || { echo "[SKIP] forge not installed" >&2; exit 0; }
[ -x "$WRAP" ] || { echo "[SKIP] LLM backend wrapper not found ($WRAP); set LLM_WRAP" >&2; exit 0; }
WORK="${OUT:-$(mktemp -d "${TMPDIR:-/tmp}/autoharness.XXXXXX")}"; mkdir -p "$WORK/test"
printf '[profile.default]\ntest = "test"\nsolc = "0.8.24"\nevm_version = "cancun"\n' > "$WORK/foundry.toml"
PROMPT="$WORK/prompt.txt"
{ echo "You are an autonomous smart-contract bug-hunting harness generator. Output ONLY a single Solidity file (no markdown, no prose): a forge-std-FREE Foundry test, contract name AutoHarness, pragma ^0.8.24. Use the cheatcode interface at 0x7109709ECfa91a80626fF3989D68f67F5b1DD12D (createSelectFork(string,uint256), envString, envUint, store, load). Fund the test contract by storage-slot scan + approve. Expose the protocol's primitive operations as fuzzable try/catch actions. Add a FUZZ test function testFuzz_hunt(uint256 seed) that derives a SEQUENCE of ops from the seed, executes them on the REAL forked protocol, then require()s the deep invariant. Fork via env ETH_RPC + the block below.";
  echo "=== TARGET RECON ==="; cat "$SPEC"; } > "$PROMPT"
ATT=0
"$WRAP" < "$PROMPT" 2>/dev/null | sed -e 's/```[a-zA-Z]*//g' | awk 'f||/\/\/ SPDX|pragma/{f=1; print}' > "$WORK/test/AutoHarness.t.sol"
while : ; do
  ERR="$( cd "$WORK" && forge build 2>&1 )"
  echo "$ERR" | grep -q 'Compiler run successful' && { echo "run-autoharness: harness COMPILES (attempt $ATT)"; break; }
  ATT=$((ATT+1)); [ "$ATT" -gt "$REPAIRS" ] && { echo "run-autoharness: gave up after $REPAIRS repair attempts" >&2; exit 1; }
  { echo "Fix the Solidity compile error(s). Output ONLY the corrected complete .sol (no markdown), contract AutoHarness, pragma ^0.8.24, forge-std-free.";
    echo "--- ERRORS ---"; echo "$ERR" | grep -iE 'error|-->' | head -20; echo "--- FILE ---"; cat "$WORK/test/AutoHarness.t.sol"; } > "$WORK/repair.txt"
  "$WRAP" < "$WORK/repair.txt" 2>/dev/null | sed -e 's/```[a-zA-Z]*//g' | awk 'f||/\/\/ SPDX|pragma/{f=1; print}' > "$WORK/test/AutoHarness.t.sol"
done
FN="$(grep -oE 'function (testFuzz|test)[A-Za-z_]*' "$WORK/test/AutoHarness.t.sol" | head -1 | sed 's/function //')"
echo "run-autoharness: hunting via $FN (fork $RPC @ $BLK) ..."
( cd "$WORK" && ETH_RPC="$RPC" FORK_BLK="$BLK" FOUNDRY_FUZZ_RUNS="$RUNS" forge test --mt "$FN" --fork-url "$RPC" --fork-block-number "$BLK" 2>&1 ) | grep -iE '\[PASS\]|\[FAIL\]|VIOLAT|counterexample|Suite result'
