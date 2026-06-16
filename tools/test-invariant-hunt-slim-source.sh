#!/usr/bin/env bash
# tools/test-invariant-hunt-slim-source.sh -- deterministic regression guard
# for #1079 (dark-factory). On a real autonomous sweep every cross-contract
# pair (two full contract sources in ONE generation prompt) and one complex
# single-contract target hit the per-run timeout: flat-cyborg->claude hung on a
# SINGLE gen call for ~712 s because the prompt embedded the FULL source of each
# contract (a pair was ~90 KB of Solidity). The OUTPUT ask is already bounded
# (#1067); the fix slims the INPUT. run-invariant-hunt.sh now stages the target
# source (CODE_PATH) and each --aux source through a Solidity-source SLIMMER
# (`slim_sol_source`) instead of a flat copy: it drops `//`/`///` line comments
# (full-line + safe trailing), `/* ... */` block comments INCLUDING multi-line
# NatSpec `/** ... */`, `import ...;` and `pragma ...;` lines, and squeezes
# runs of blank lines to one -- while KEEPING the `contract` decl, state vars,
# every function signature AND body, and structs/enums/events/errors.
#
# This test FEEDS a fixture .sol through the live `slim_sol_source` function
# (extracted verbatim from the runner) and asserts the slim contract, plus
# pins that the runner WIRES the slimmer into both the target and the --aux
# staging (so a pre-change flat `cp` staging fails). Pure bash/awk/grep over
# the runner -- no agentis runtime, no LLM, no forge required. Auto-discovered
# and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) The runner defines a `slim_sol_source()` function AND wires it into the
#       target (CODE_PATH) staging and the --aux staging (not a flat `cp`).
#   (b) Run over a fixture, the slimmer REMOVES: full-line `//`/`///` comments,
#       multi-line `/** ... */` NatSpec blocks, inline `/* ... */` blocks,
#       `import ...;` lines, `pragma ...;` lines, and squeezes blank-line runs.
#   (c) The slimmer KEEPS the real code intact: the `contract <Name> is ...`
#       declaration, a state-variable line, every function signature, and a
#       struct/event/error line all survive.
#   (d) Conservative trailing-comment handling: a `//` INSIDE a string literal
#       is NEVER stripped (the code line carrying it survives verbatim), so the
#       staged Solidity is never corrupted.
#   (e) Empty-output fallback: a pathological all-comments/all-import source
#       (which slims to only blank lines) falls back to the ORIGINAL verbatim,
#       so CODE_PATH is never empty / truncated.
#
# Usage: bash tools/test-invariant-hunt-slim-source.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER="$REPO_ROOT/dark-factory/run-invariant-hunt.sh"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

summary_exit() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
    exit 0
}

if [ ! -f "$RUNNER" ]; then
    fail "runner exists" "$RUNNER not found"
    summary_exit
fi

run_src="$(cat "$RUNNER")"

# (a) The runner defines slim_sol_source AND wires it into both stagings (a
# pre-change flat `cp "$CODE" .../target-code.sol` / `cp "$_aabs" .../aux-code`
# staging fails here).
a_fail=""
printf '%s\n' "$run_src" | grep -Eq '^slim_sol_source\(\) \{' \
    || a_fail="${a_fail} no-slim-fn"
# shellcheck disable=SC2016  # matching the literal staging line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'slim_sol_source "$CODE" "$RUN/target-code.sol"' \
    || a_fail="${a_fail} target-not-slimmed"
# shellcheck disable=SC2016  # matching the literal staging line, $ must not expand
printf '%s\n' "$run_src" | grep -Fq 'slim_sol_source "$_aabs" "$_aux_in_run"' \
    || a_fail="${a_fail} aux-not-slimmed"

if [ -z "$a_fail" ]; then
    pass "(a) runner defines slim_sol_source and wires it into the target + --aux staging"
else
    fail "(a) runner slims both stagings via slim_sol_source" \
         "missing piece(s):$a_fail"
fi

# Extract the live slim_sol_source function verbatim so the behavioural
# assertions exercise the SAME code the runner ships (not a re-implementation).
SLIM_FN="$(awk '/^slim_sol_source\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$RUNNER")"

if [ -z "$SLIM_FN" ]; then
    fail "slim_sol_source extracted" "no 'slim_sol_source() { ... }' block in the runner"
    summary_exit
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Run the extracted slimmer in a child shell over a given src -> dst.
slim() {  # $1 = src, $2 = dst
    { printf '%s\n' "$SLIM_FN"; printf 'slim_sol_source %s %s\n' "$1" "$2"; } | bash
}

# --- Fixture with EVERY noise class + real code to keep ---
FIX="$WORK/Vault.sol"
cat > "$FIX" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title A vault
/// @notice keeps funds
/**
 * @dev multi-line NatSpec
 *      block comment
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Other.sol";

contract Vault is IERC20 {
    uint256 public totalAssets; // trailing comment on code


    mapping(address => uint256) public shares;
    struct Position { uint256 amount; uint256 since; }
    event Deposit(address indexed who, uint256 amt);
    error NotEnough();

    // a full-line comment between functions
    function deposit(uint256 amt) external {
        string memory note = "use // not a comment"; // real trailing
        totalAssets += amt; /* inline block */ shares[msg.sender] += amt;
    }

    function withdraw(uint256 amt) external {
        require(shares[msg.sender] >= amt, "x");
        totalAssets -= amt;
    }
}
SOL

OUT="$WORK/Vault.slim.sol"
slim "$FIX" "$OUT"

if [ ! -s "$OUT" ]; then
    fail "slimmer produced output" "slim_sol_source wrote an empty file"
    summary_exit
fi

# (b) Noise removed.
b_fail=""
grep -Fq 'SPDX-License-Identifier' "$OUT" \
    && b_fail="${b_fail} spdx-line-comment-kept"
grep -Fq '@title A vault' "$OUT" \
    && b_fail="${b_fail} triple-slash-comment-kept"
grep -Fq 'multi-line NatSpec' "$OUT" \
    && b_fail="${b_fail} multiline-natspec-kept"
grep -Fq 'block comment' "$OUT" \
    && b_fail="${b_fail} natspec-body-kept"
grep -Fq 'inline block' "$OUT" \
    && b_fail="${b_fail} inline-block-kept"
grep -Fq 'trailing comment on code' "$OUT" \
    && b_fail="${b_fail} trailing-comment-kept"
grep -Fq 'a full-line comment between functions' "$OUT" \
    && b_fail="${b_fail} fullline-between-fns-kept"
grep -Eq '^[[:space:]]*import[[:space:](]' "$OUT" \
    && b_fail="${b_fail} import-kept"
grep -Eq '^[[:space:]]*pragma[[:space:]]' "$OUT" \
    && b_fail="${b_fail} pragma-kept"
# No run of two consecutive blank lines survives (blank-squeeze). NR>1 guards
# against the uninitialized `prev` matching a leading blank line on the 1st row.
if awk 'NR>1 && prev=="" && $0=="" {bad=1} {prev=$0} END{exit bad?0:1}' "$OUT"; then
    b_fail="${b_fail} blank-run-kept"
fi

if [ -z "$b_fail" ]; then
    pass "(b) slimmer removes //, ///, /** */ NatSpec, inline /* */, import, pragma, and blank-line runs"
else
    fail "(b) slimmer removes comment/import/pragma/blank noise" \
         "still present:$b_fail"
fi

# (c) Real code kept intact.
c_fail=""
grep -Fq 'contract Vault is IERC20 {' "$OUT" \
    || c_fail="${c_fail} contract-decl-lost"
grep -Fq 'uint256 public totalAssets;' "$OUT" \
    || c_fail="${c_fail} state-var-lost"
grep -Fq 'mapping(address => uint256) public shares;' "$OUT" \
    || c_fail="${c_fail} mapping-state-var-lost"
grep -Fq 'function deposit(uint256 amt) external {' "$OUT" \
    || c_fail="${c_fail} deposit-sig-lost"
grep -Fq 'function withdraw(uint256 amt) external {' "$OUT" \
    || c_fail="${c_fail} withdraw-sig-lost"
grep -Fq 'struct Position { uint256 amount; uint256 since; }' "$OUT" \
    || c_fail="${c_fail} struct-lost"
grep -Fq 'event Deposit(address indexed who, uint256 amt);' "$OUT" \
    || c_fail="${c_fail} event-lost"
grep -Fq 'error NotEnough();' "$OUT" \
    || c_fail="${c_fail} error-lost"
# A body statement survives (function bodies are kept, not just signatures).
grep -Fq 'require(shares[msg.sender] >= amt, "x");' "$OUT" \
    || c_fail="${c_fail} body-stmt-lost"

if [ -z "$c_fail" ]; then
    pass "(c) slimmer keeps the contract decl, state vars, function signatures + bodies, struct/event/error"
else
    fail "(c) slimmer keeps the real callable surface + logic" \
         "lost:$c_fail"
fi

# (d) Conservative: a // inside a string literal is never stripped -> the line
# carrying it survives VERBATIM (the string content is intact and uncorrupted).
if grep -Fq 'string memory note = "use // not a comment";' "$OUT"; then
    pass "(d) a // inside a string literal is preserved (string-literal line not corrupted)"
else
    fail "(d) string-literal // preserved" \
         "the 'use // not a comment' string literal was corrupted or dropped"
fi

# (e) Empty-output fallback: an all-comments / all-import source slims to only
# blank lines, so the slimmer falls back to the ORIGINAL verbatim.
PATHO="$WORK/AllComments.sol"
cat > "$PATHO" <<'SOL'
// only comments
/// more
/** block
    spanning lines */
import "x";
pragma solidity ^0.8.0;
SOL
PATHO_OUT="$WORK/AllComments.slim.sol"
slim "$PATHO" "$PATHO_OUT"

if [ -s "$PATHO_OUT" ] && cmp -s "$PATHO" "$PATHO_OUT"; then
    pass "(e) a pathological all-comments source falls back to the original verbatim (never empty CODE_PATH)"
else
    fail "(e) empty-output fallback to the original" \
         "all-comments source did not fall back to the original (would ship an empty/blank CODE_PATH)"
fi

summary_exit
