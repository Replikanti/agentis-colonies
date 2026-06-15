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
ATT=0
"$WRAP" < "$PROMPT" 2>/dev/null | sed -e 's/```[a-zA-Z]*//g' | awk 'f||/\/\/ SPDX|pragma/{f=1; print}' > "$WORK/test/AutoHarness.t.sol"
while : ; do
  ERR="$( cd "$WORK" && forge build 2>&1 )"
  # forge build trivially "succeeds" on an empty dir, so also require a real contract in the generated file
  # (guards against a truncated/empty LLM response being mistaken for a clean compile).
  if echo "$ERR" | grep -q 'Compiler run successful' && grep -q 'contract[[:space:]]\+AutoHarness' "$WORK/test/AutoHarness.t.sol"; then
    echo "run-autoharness: harness COMPILES (attempt $ATT)"; break
  fi
  ATT=$((ATT+1)); [ "$ATT" -gt "$REPAIRS" ] && { echo "run-autoharness: gave up after $REPAIRS repair attempts" >&2; exit 1; }
  { echo "Fix the Solidity compile error(s). Output ONLY the corrected complete .sol (no markdown), contract AutoHarness, pragma ^0.8.24, forge-std-free.";
    echo "--- ERRORS ---"; echo "$ERR" | grep -iE 'error|-->' | head -20; echo "--- FILE ---"; cat "$WORK/test/AutoHarness.t.sol"; } > "$WORK/repair.txt"
  "$WRAP" < "$WORK/repair.txt" 2>/dev/null | sed -e 's/```[a-zA-Z]*//g' | awk 'f||/\/\/ SPDX|pragma/{f=1; print}' > "$WORK/test/AutoHarness.t.sol"
done
FN="$(grep -oE 'function (testFuzz|test)[A-Za-z_]*' "$WORK/test/AutoHarness.t.sol" | head -1 | sed 's/function //')"
[ -n "$FN" ] || { echo "run-autoharness: no test/testFuzz function in generated harness (empty/truncated LLM output?)" >&2; exit 1; }
echo "run-autoharness: hunting via $FN (fork $RPC @ $BLK) ..."
( cd "$WORK" && ETH_RPC="$RPC" FORK_BLK="$BLK" FOUNDRY_FUZZ_RUNS="$RUNS" forge test --mt "$FN" --fork-url "$RPC" --fork-block-number "$BLK" 2>&1 ) | grep -iE '\[PASS\]|\[FAIL\]|VIOLAT|counterexample|Suite result'
