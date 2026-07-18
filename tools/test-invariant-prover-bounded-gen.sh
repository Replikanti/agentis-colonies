#!/usr/bin/env bash
# tools/test-invariant-prover-bounded-gen.sh -- deterministic regression
# guard for #1067 (dark-factory). The dark-factory invariant-prover used to
# ask the model, in ONE completion, for a full Handler + abstract InvBase +
# a test contract asserting FIVE deep invariants (value-conservation,
# no-depositor-loss, solvency-under-any-sequence, no-free-value-extraction,
# share-price-monotonicity). On a realistically-sized contract that single
# generation is too large to return within the LLM timeout, so the engine
# degraded to HARNESS_ERROR (no verdict). The fix bounds the ask to ONE
# lens-driven invariant + a MINIMAL handler under an explicit ~120-line
# budget, which returns reliably and compiles.
#
# This test pins that bounded ask in `generate_test()` so it cannot silently
# regress to the five-invariant enumeration. Pure grep/awk over the .ag
# source — no agentis runtime, no LLM, no forge required. Auto-discovered
# and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions over the `generate_test()` instruction text:
#   (a) It does NOT enumerate the old five invariants (no
#       "no-depositor-loss" / "solvency-under-any-sequence" /
#       "share-price-monotonicity" enumeration in the instruction body).
#   (b) It requests EXACTLY ONE deep invariant driven by the bug-class lens
#       (an "EXACTLY ONE" + lens-driven phrasing).
#   (c) It carries an explicit line budget ("under ~120 lines").
#   (d) The hard constraints are still present: `pragma solidity ^0.8.20;`,
#       no forge-std import, the StdInvariant `targetContracts()` ABI, and
#       the "Output ONLY the Solidity source" / "no markdown fences"
#       instruction.
#
# Usage: bash tools/test-invariant-prover-bounded-gen.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AG="$REPO_ROOT/dark-factory/auditor/agents/invariant-prover.ag"

PASS=0
FAIL=0

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1: $2"; FAIL=$((FAIL + 1)); }

if [ ! -f "$AG" ]; then
    fail "ag exists" "$AG not found"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Extract the STATIC generation instruction. Since #1720 it is factored out of
# generate_test() into the module-level `harness_skeleton()` (the canonical
# compiling skeleton) + the `sharedScaffold` string (the requirement paragraphs
# + bug-class lens + answer contract); generate_test appends sharedScaffold and
# the compile-repair chain re-injects it. Capture BOTH blocks so the assertions
# scope to that instruction text and never to doc comments or other agents.
gen_body="$(awk '/^fn harness_skeleton\(/{f=1} f{print} f&&/^}/{f=0}' "$AG"; awk '/^let sharedScaffold/{f=1} f{print} f&&/;[[:space:]]*$/{f=0}' "$AG")"

if [ -z "$gen_body" ]; then
    fail "generate_test body found" "no 'fn generate_test(...)' block in $AG"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# (a) The instruction must NOT enumerate the old five invariants. The
# bounded ask names AT MOST one example per lens, never the full list.
if printf '%s\n' "$gen_body" | grep -Eq 'no-depositor-loss|solvency-under-any-sequence'; then
    fail "(a) no five-invariant enumeration in generate_test" \
         "found the old enumeration (no-depositor-loss / solvency-under-any-sequence) in the instruction"
else
    pass "(a) generate_test no longer enumerates the old five invariants"
fi

# (b) It must request EXACTLY ONE deep invariant, driven by the bug-class
# lens (the prompt already injects "=== BUG CLASS (lens) ===").
if printf '%s\n' "$gen_body" | grep -Eq 'EXACTLY ONE' \
   && printf '%s\n' "$gen_body" | grep -Eiq 'lens'; then
    pass "(b) generate_test requests EXACTLY ONE lens-driven invariant"
else
    fail "(b) generate_test requests EXACTLY ONE lens-driven invariant" \
         "missing an 'EXACTLY ONE' + lens-driven single-invariant ask"
fi

# (c) It must carry an explicit line budget.
if printf '%s\n' "$gen_body" | grep -Eq 'under ~?120 lines'; then
    pass "(c) generate_test carries an explicit ~120-line budget"
else
    fail "(c) generate_test carries an explicit ~120-line budget" \
         "no 'under ~120 lines' size budget in the instruction"
fi

# (d) The hard constraints must survive the change.
hd_fail=""
printf '%s\n' "$gen_body" | grep -Fq 'pragma solidity ^0.8.20;' \
    || hd_fail="${hd_fail} pragma-solidity"
printf '%s\n' "$gen_body" | grep -Fq 'Do NOT import forge-std' \
    || hd_fail="${hd_fail} no-forge-std"
printf '%s\n' "$gen_body" | grep -Fq 'targetContracts()' \
    || hd_fail="${hd_fail} targetContracts-ABI"
printf '%s\n' "$gen_body" | grep -Fq 'Output ONLY the Solidity source' \
    || hd_fail="${hd_fail} output-only-solidity"
printf '%s\n' "$gen_body" | grep -Fq 'no markdown fences' \
    || hd_fail="${hd_fail} no-markdown-fences"

if [ -z "$hd_fail" ]; then
    pass "(d) generate_test keeps all hard constraints (pragma, no forge-std, StdInvariant ABI, output-only)"
else
    fail "(d) generate_test keeps all hard constraints" \
         "missing constraint(s):$hd_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
