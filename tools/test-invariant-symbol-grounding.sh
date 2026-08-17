#!/usr/bin/env bash
# tools/test-invariant-symbol-grounding.sh -- deterministic offline guard for the FM-B milestone
# (dark-factory, agentis-colonies#1939 M2): SYMBOL GROUNDING of the invariant harness generator.
#
# The composable-fresh multi-contract harness failed to compile with solc `Error (7920): Identifier not found or
# not unique` -- the generator referenced a contract/function name that does not exist in scope -- and survived
# all repair rounds. M2 grounds generation AND every repair round with the target + aux REAL symbol inventory,
# behind a default-OFF flag:
#   * evm-harness/extract-solidity-symbols.sh  -- a deterministic, network-free source parser: contract /
#     interface / library / struct / enum NAMES + external/public function signatures.
#   * run-invariant-hunt.sh --ground-symbols   -- stages the inventory to $RUN/symbol-inventory.txt (a FIXED
#     rundir-relative file, NOT a new exec.env_passthrough entry).
#   * invariant-prover.ag                      -- reads that file and folds a non-empty inventory into the first
#     generation prompt AND the repair-loop scaffold. Empty (file absent) => byte-identical prompts.
#
# Offline by construction: (a)/(b) are pure source-parsing / source-grep; (c) drives run-invariant-hunt.sh
# through the --handler-fixture (no-LLM) path with a 3-line --agentis stub. No LLM, no forge, no network.
# Auto-discovered and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) EXTRACTOR: the inventory CONTAINS every symbol in the fixture's truth.symbols.txt, is deterministic
#       (stable sort -- two runs byte-identical), and empty-input => empty output.
#   (b) PROVER SOURCE GUARD: invariant-prover.ag reads symbol-inventory.txt, folds a non-empty inventory into
#       generate_test's instruction, appends it to the repair_loop scaffold arg, and the empty-inventory branch
#       returns "" (the byte-identity contract).
#   (c) RUN-INVARIANT WIRING: --ground-symbols writes $RUN/symbol-inventory.txt; without the flag it is absent.
#
# Usage: bash tools/test-invariant-symbol-grounding.sh
# Exit: 0 = held, 1 = regressed, 3 = missing prerequisite.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DF="$REPO_ROOT/dark-factory"
EXTRACT="$DF/evm-harness/extract-solidity-symbols.sh"
INVHUNT="$DF/run-invariant-hunt.sh"
PROVER="$DF/auditor/agents/invariant-prover.ag"
FIX="$DF/fixtures/symbol-grounding"

PASS=0
FAIL=0
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -gt 0 ] && exit 1
    exit 0
}

[ -x "$EXTRACT" ] || { echo "[SKIP] extractor not found/executable: $EXTRACT" >&2; exit 3; }
[ -x "$INVHUNT" ] || { echo "[SKIP] run-invariant-hunt.sh not found/executable: $INVHUNT" >&2; exit 3; }
[ -f "$PROVER" ] || { echo "[SKIP] invariant-prover.ag not found: $PROVER" >&2; exit 3; }
[ -f "$FIX/truth.symbols.txt" ] || { echo "[SKIP] fixture missing: $FIX/truth.symbols.txt" >&2; exit 3; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/inv-symbol-grounding.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# (a) EXTRACTOR: containment of every truth symbol, determinism, empty-input => empty output.
# ----------------------------------------------------------------------------------------------------------
INV1="$WORK/inv1.txt"
INV2="$WORK/inv2.txt"
sh "$EXTRACT" "$FIX"/src/*.sol > "$INV1" 2>/dev/null
sh "$EXTRACT" "$FIX"/src/*.sol > "$INV2" 2>/dev/null

a_fail=""
# CONTAINMENT: every non-comment / non-blank truth line is present as a full line in the inventory.
missing=""
while IFS= read -r sym; do
    case "$sym" in ''|\#*) continue ;; esac
    grep -Fxq -- "$sym" "$INV1" || missing="${missing} [${sym}]"
done < "$FIX/truth.symbols.txt"
[ -z "$missing" ] || a_fail="${a_fail} missing-symbols:${missing}"
# DETERMINISM: two independent runs are byte-identical (the LC_ALL=C sort -u makes it stable).
diff -q "$INV1" "$INV2" >/dev/null 2>&1 || a_fail="${a_fail} non-deterministic-output"
# EMPTY INPUT => EMPTY OUTPUT (no args, and a non-existent file arg).
EMPTY_NOARG="$(sh "$EXTRACT" 2>/dev/null)"
EMPTY_MISSING="$(sh "$EXTRACT" "$WORK/does-not-exist.sol" 2>/dev/null)"
[ -z "$EMPTY_NOARG" ] || a_fail="${a_fail} no-arg-not-empty"
[ -z "$EMPTY_MISSING" ] || a_fail="${a_fail} missing-file-not-empty"
if [ -z "$a_fail" ]; then
    pass "(a) extractor CONTAINS every truth symbol, is deterministic, and empty-input => empty output"
else
    fail "(a) extract-solidity-symbols.sh inventory" "problem(s):$a_fail ; inventory: $(tr '\n' '|' < "$INV1")"
fi

# ----------------------------------------------------------------------------------------------------------
# (b) PROVER SOURCE GUARD: the .ag reads the file, grounds BOTH generate_test + repair_loop, and the empty
#     branch returns "" (byte-identity).
# ----------------------------------------------------------------------------------------------------------
b_fail=""
grep -q 'read_symbol_inventory("symbol-inventory.txt")' "$PROVER" || b_fail="${b_fail} not-reading-inventory-file"
# folded into generate_test's dynamic instruction (the `+ symbolInventorySeed` term in the seed chain).
grep -qE '^\s*\+ symbolInventorySeed$' "$PROVER" || b_fail="${b_fail} not-folded-into-generate_test-instruction"
# appended to the repair_loop scaffold argument (so all repair rounds are grounded too).
grep -q 'sharedScaffold + symbolInventorySeed' "$PROVER" || b_fail="${b_fail} not-appended-to-repair_loop-scaffold"
# the empty-inventory byte-identity contract: symbol_inventory_seed("") returns "".
grep -q 'fn symbol_inventory_seed(inv: string) -> string {' "$PROVER" || b_fail="${b_fail} no-seed-fn"
# the empty-guard must be the first statement of the seed fn (extract just that fn body's first line).
seed_guard="$(awk '/fn symbol_inventory_seed\(inv: string\) -> string \{/{f=1;next} f{print;exit}' "$PROVER")"
case "$seed_guard" in
    *'if len(inv) == 0 { return ""; }'*) ;;
    *) b_fail="${b_fail} no-empty-inventory-byte-identity-guard" ;;
esac
if [ -z "$b_fail" ]; then
    pass "(b) invariant-prover.ag reads symbol-inventory.txt, grounds generate_test + repair_loop, empty => byte-identical"
else
    fail "(b) prover source wiring" "missing piece(s):$b_fail"
fi

# ----------------------------------------------------------------------------------------------------------
# (c) RUN-INVARIANT WIRING (offline): a --handler-fixture run with a 3-line --agentis stub writes
#     $RUN/symbol-inventory.txt ONLY when --ground-symbols is given.
# ----------------------------------------------------------------------------------------------------------
REPO="$WORK/repo"
mkdir -p "$REPO/src" "$REPO/test"
cat > "$REPO/foundry.toml" <<'TOML'
[profile.default]
src = "src"
test = "test"
TOML
cp "$FIX/src/Singleton.sol" "$REPO/src/Singleton.sol"

FIXTURE="$WORK/handler-fixture.t.sol"
cat > "$FIXTURE" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// A verbatim handler fixture -- the offline (no-LLM) path. The --agentis stub short-circuits generation, so
// this is never compiled; it only has to exist so run-invariant-hunt.sh takes the FIXTURE branch.
contract InvFixture {
    function invariant_placeholder() public pure returns (bool) { return true; }
}
SOL

# 3-line --agentis stub: `init` makes .agentis/, `go invariant-prover.ag` emits the prover's one-line verdict
# contract (a CLEAN with no witness). run-invariant-hunt.sh writes symbol-inventory.txt BEFORE this stub runs,
# so the stub's verdict is irrelevant to the assertion -- the file's presence is decided entirely by the flag.
STUB="$WORK/agentis-stub.sh"
cat > "$STUB" <<'SH'
#!/bin/sh
set -u
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  go) [ "${2:-}" = "invariant-prover.ag" ] && echo "INVARIANT|Singleton.sol:Singleton|CLEAN"; exit 0 ;;
  *) exit 0 ;;
esac
SH
chmod +x "$STUB"

run_invhunt() {  # $1 = out dir, $2.. = extra flags
    _out="$1"; shift
    "$INVHUNT" --repo "$REPO" --target "Singleton.sol:Singleton" \
        --handler-fixture "$FIXTURE" --code "$FIX/src/Singleton.sol" \
        --backend mock --agentis "$STUB" --out "$_out" "$@" >"$_out.log" 2>&1
}

OUT_ON="$WORK/on"
run_invhunt "$OUT_ON" --ground-symbols
ON_RC=$?
OUT_OFF="$WORK/off"
run_invhunt "$OUT_OFF"
OFF_RC=$?

INV_ON="$OUT_ON/run/symbol-inventory.txt"
INV_OFF="$OUT_OFF/run/symbol-inventory.txt"

c_fail=""
[ "$ON_RC" -eq 0 ] || c_fail="${c_fail} ground-symbols-run-exit=${ON_RC}"
[ "$OFF_RC" -eq 0 ] || c_fail="${c_fail} default-run-exit=${OFF_RC}"
if [ ! -f "$INV_ON" ]; then
    c_fail="${c_fail} inventory-not-written-with-flag"
else
    # the grounded file must carry the target's real symbols (sanity that the wiring fed real sources through).
    grep -Fxq 'contract Singleton' "$INV_ON" || c_fail="${c_fail} inventory-missing-target-symbol"
fi
[ -f "$INV_OFF" ] && c_fail="${c_fail} inventory-written-WITHOUT-flag(byte-identity-broken)"
if [ -z "$c_fail" ]; then
    pass "(c) --ground-symbols writes \$RUN/symbol-inventory.txt (with target symbols); absent flag => file NOT written"
else
    fail "(c) run-invariant-hunt.sh --ground-symbols wiring" "problem(s):$c_fail"
    tail -15 "$OUT_ON.log" 2>/dev/null | sed 's/^/      /' >&2
fi

summary_exit
