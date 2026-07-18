#!/usr/bin/env bash
# demo-invariant-repair.sh — proof of the #1720 harness-gen SCAFFOLD + widened solc error-context wiring on the
# invariant-hunt generation/repair path.
#
# The problem (#1716 A/B): the deep-hunt path spent its 4 repair rounds and still returned HARNESS_ERROR too
# often. Two structural fixes make each of the (unchanged) 4 rounds more effective, without touching the fuzzer
# (still the sole verdict source):
#   1) a CANONICAL COMPILING SKELETON (`harness_skeleton` -> `sharedScaffold`) injected into the FIRST prompt AND
#      re-injected on EVERY compile-repair round, so a round re-anchors to the same boilerplate instead of
#      drifting off it. The skeleton is boilerplate-only (generic `InvariantTest`/`Handler`, never a contract of
#      the target's name) so it can never trip the #1471 target-linkage/shadow gate.
#   2) a WIDENED `error_excerpt`: the repair prompt now keeps the solc source-context lines (the `-->` pointer,
#      the numbered gutter lines, the caret-underline lines) — not just the error TEXT — so the model can locate
#      the offending SOURCE, plus a higher line/byte cap to fit that context.
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis): it asserts the wiring is present in
# `auditor/agents/invariant-prover.ag`, and — for the excerpt filter — proves the widened grep pattern actually
# keeps the `-->`/gutter/caret context by running it over a canned multi-line solc error block. A refactor that
# drops the skeleton, un-threads the scaffold from the repair chain, or narrows the error filter is caught here.
#
# Usage:  dark-factory/demo-invariant-repair.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"

FAILS=0
note() { echo "demo-invariant-repair.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) SKELETON / SCAFFOLD — the harness_skeleton helper + the shared scaffold exist and the FIRST prompt uses it.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1720 harness-gen scaffold ..."

if grep -q 'fn harness_skeleton(' "$PROVER" \
   && grep -q 'abstract contract InvBase' "$PROVER" \
   && grep -q 'function targetContracts() public view returns' "$PROVER" \
   && grep -q '_bound(uint256 x, uint256 lo, uint256 hi)' "$PROVER"; then
  ok "harness_skeleton emits the InvBase/targetContracts/_bound compiling boilerplate"
else
  bad "harness_skeleton missing the InvBase/targetContracts/_bound boilerplate"
fi

# Boilerplate-only: the skeleton must NOT declare a contract of the target's name (would trip the #1471 gate).
# It uses the generic test-contract name `InvariantTest` and the actor `Handler`.
if grep -q 'contract InvariantTest is InvBase' "$PROVER"; then
  ok "skeleton uses a generic test contract (InvariantTest) — cannot shadow the target (#1471-safe)"
else
  bad "skeleton test contract name changed — verify it never shadows the target"
fi

if grep -q 'let sharedScaffold' "$PROVER" \
   && grep -q 'harness_skeleton(invMatch, deployName, importLine, auxImportLines)' "$PROVER"; then
  ok "sharedScaffold is built from harness_skeleton + the static requirements"
else
  bad "sharedScaffold missing or not built from harness_skeleton"
fi

if grep -q '+ sharedScaffold;' "$PROVER"; then
  ok "generate_test appends sharedScaffold to the per-run seeds"
else
  bad "generate_test does not append sharedScaffold"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) REPAIR CHAIN — the scaffold is threaded through the compile-repair chain and re-injected every round.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1720 repair-chain scaffold threading ..."

if grep -q 'fn repair_instruction(excerpt: string, prevSrc: string, scaffold: string)' "$PROVER" \
   && grep -q 'fn repair_test(excerpt: string, prevSrc: string, scaffold: string)' "$PROVER"; then
  ok "repair_instruction / repair_test carry the scaffold param"
else
  bad "repair_instruction / repair_test missing the scaffold param"
fi

if grep -q 'fn repair_step(' "$PROVER" && grep -q 'fn repair_step(.*names: list<string>, scaffold: string) -> string' "$PROVER" \
   && grep -q 'repair_test(error_excerpt(prevOut), prevSrc, scaffold)' "$PROVER"; then
  ok "repair_step carries scaffold and forwards it into the compile-error repair_test"
else
  bad "repair_step does not thread scaffold into repair_test"
fi

if grep -q 'fn repair_loop(.*names: list<string>, scaffold: string) -> string' "$PROVER" \
   && grep -q 'repair_step(acc, gateSh, repo, out, matchPrefix, budgetArgs, forkArgs, composeFresh, names, scaffold)' "$PROVER"; then
  ok "repair_loop carries scaffold and forwards it into repair_step"
else
  bad "repair_loop does not thread scaffold into repair_step"
fi

if grep -q 'repair_loop(initState, repairRounds,.*requiredNames, sharedScaffold)' "$PROVER"; then
  ok "the repair_loop call site passes sharedScaffold (re-inject every round)"
else
  bad "the repair_loop call site does not pass sharedScaffold"
fi

# The both-real repair path (#1077) must stay UNCHANGED — still keyed on matchPrefix, not scaffold.
if grep -q 'fn repair_instruction_bothreal(missing: string, prevSrc: string, matchPrefix: string)' "$PROVER"; then
  ok "the #1077 both-real repair path is untouched (matchPrefix-keyed)"
else
  bad "the #1077 both-real repair signature changed unexpectedly"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) ERROR EXCERPT — the widened grep is present AND actually keeps the -->/gutter/caret context.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1720 widened error_excerpt ..."

# The .ag runs the filter with the widened alternation and raised caps.
if grep -Fq '[[:space:]]*[0-9]*[[:space:]]*' "$PROVER" \
   && grep -Fq 'head -n 160' "$PROVER" \
   && grep -Fq '> 6000' "$PROVER"; then
  ok "error_excerpt uses the widened alternation + raised line (160) / byte (6000) caps"
else
  bad "error_excerpt missing the widened alternation or the raised caps"
fi

# Prove the widened pattern (the shell-level ERE the .ag runs) keeps the solc source context. This is the exact
# ERE after .ag string-unescaping: Error|error\[|[-][-]>|Compiler | numbered gutter | caret underline.
PAT='Error|error\[|[-][-]>|Compiler|^[[:space:]]*[0-9]*[[:space:]]*\||\^'
SOLC_BLOCK="$(printf '%s\n' \
  'Compiling 1 files with Solc 0.8.20' \
  'Error (7576): Undeclared identifier.' \
  '  --> test/Foo.t.sol:12:9:' \
  '   |' \
  '12 |         foo(bar);' \
  '   |         ^^^^^^^^' \
  'some unrelated build chatter that should be dropped')"
FILTERED="$(printf '%s\n' "$SOLC_BLOCK" | grep -E "$PAT" || true)"

if printf '%s\n' "$FILTERED" | grep -Fq -- '-->'; then
  ok "widened filter keeps the '-->' source-pointer line"
else
  bad "widened filter dropped the '-->' source-pointer line"
fi
if printf '%s\n' "$FILTERED" | grep -Fq '12 |         foo(bar);'; then
  ok "widened filter keeps the numbered gutter (source) line"
else
  bad "widened filter dropped the numbered gutter (source) line"
fi
if printf '%s\n' "$FILTERED" | grep -Fq '^^^^^^^^'; then
  ok "widened filter keeps the caret-underline line"
else
  bad "widened filter dropped the caret-underline line"
fi
if printf '%s\n' "$FILTERED" | grep -Fq 'unrelated build chatter'; then
  bad "widened filter leaked unrelated build chatter (pattern too broad)"
else
  ok "widened filter still drops unrelated build chatter"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the #1720 compiling skeleton is injected into the first prompt AND re-injected on every compile-"
  note "      repair round (scaffold threaded through repair_instruction/repair_test/repair_step/repair_loop),"
  note "      and error_excerpt keeps the solc -->/gutter/caret source context so repairs can locate the fault."
  exit 0
fi
note "DEMO FAILED — a #1720 harness-gen/repair scaffold assertion did not hold" >&2
exit 1
