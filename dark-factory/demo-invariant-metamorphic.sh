#!/usr/bin/env bash
# demo-invariant-metamorphic.sh — proof of the #1726 (M1) METAMORPHIC-RELATION prompt lever on the deep-hunt
# path.
#
# The #1716 A/B showed the fuzzer often reaches a plausible ABSOLUTE-predicate invariant but never the harder-to-
# state property where the rare Highs live (rounding-direction / value-leak / inflation). #1726 M1 adds a flat
# string builder metamorphic_relation_prompt(klass) to invariant-prover.ag, keyed off the SAME TARGET_CLASS via
# the existing class_to_keyword(to_lower(klass)) normalizer + anchored class_is (no new env var), and appends a
# `=== METAMORPHIC RELATIONS (alternative property shape) ===` block to sharedScaffold — framing the ONE deep
# invariant as an OPTIONAL round-trip / commutativity / monotonicity relation (an ALTERNATIVE shape for the SAME
# single invariant, never a second property). Per-class menus: vault/ERC4626, lending/CDP, staking, AMM,
# reentrancy, plus a generic default.
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis, no forge, no LLM): it asserts the prover
# wiring is present, each per-class metamorphic menu is textually present, the verdict/marker/#1471 gate is
# unchanged, and no new env var was added to run-invariant-hunt.sh's exec.env_passthrough allowlist.
#
# Usage:  dark-factory/demo-invariant-metamorphic.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-metamorphic.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) WIRING — metamorphic_relation_prompt() is defined, normalizes through the SAME class_to_keyword(to_lower())
#    normalizer (not bare to_lower), and sharedScaffold carries the header + the call on targetClass.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1726 (M1) metamorphic-relation wiring ..."

if grep -q 'fn metamorphic_relation_prompt(klass: string) -> string' "$PROVER"; then
  ok "metamorphic_relation_prompt() is defined on the prover"
else
  bad "metamorphic_relation_prompt() missing from the prover"
fi

if grep -q 'class_to_keyword(to_lower(klass))' "$PROVER"; then
  ok "metamorphic_relation_prompt() normalizes via class_to_keyword(to_lower(klass)) (the production BARE-code path)"
else
  bad "metamorphic_relation_prompt() does not normalize the bare taxonomy code (regressed to raw label)"
fi

if grep -q 'METAMORPHIC RELATIONS (alternative property shape)' "$PROVER"; then
  ok "sharedScaffold carries the METAMORPHIC RELATIONS header"
else
  bad "sharedScaffold missing the METAMORPHIC RELATIONS header"
fi

if grep -q 'metamorphic_relation_prompt(targetClass)' "$PROVER"; then
  ok "sharedScaffold calls metamorphic_relation_prompt(targetClass)"
else
  bad "sharedScaffold does not call metamorphic_relation_prompt(targetClass)"
fi

if grep -q 'ALTERNATIVE SHAPE for the SAME single' "$PROVER"; then
  ok "the block frames the relation as an ALTERNATIVE shape for the SAME single invariant (not a second property)"
else
  bad "the block does not frame the relation as an alternative shape for the single invariant"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) PER-CLASS COVERAGE — each of the 5 classes (plus the generic default) has its distinguishing metamorphic
#    relation text present, and the round-trip / commutativity / monotonicity vocabulary is used.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1726 (M1) per-class metamorphic coverage ..."

if grep -q 'redeem(deposit(x)) <= x' "$PROVER"; then
  ok "vault/ERC4626 metamorphic relation present (redeem(deposit(x)) <= x round-trip)"
else
  bad "vault/ERC4626 metamorphic relation missing (redeem(deposit round-trip)"
fi

if grep -q 'borrow then immediately repay' "$PROVER"; then
  ok "lending/CDP metamorphic relation present (borrow -> repay round-trip)"
else
  bad "lending/CDP metamorphic relation missing (borrow -> repay)"
fi

if grep -q 'stake then unstake' "$PROVER"; then
  ok "staking metamorphic relation present (stake -> unstake round-trip)"
else
  bad "staking metamorphic relation missing (stake -> unstake)"
fi

if grep -q 'a swap A->B->A must NOT increase' "$PROVER"; then
  ok "AMM metamorphic relation present (swap A->B->A round-trip yields no free value)"
else
  bad "AMM metamorphic relation missing (swap A->B->A round-trip)"
fi

if grep -q 'reentrant path grants no' "$PROVER"; then
  ok "reentrancy metamorphic relation present (reentrant o outer == sequential)"
else
  bad "reentrancy metamorphic relation missing (reentrant/sequential commutativity)"
fi

if grep -q 'any put/take (deposit/withdraw) round-trip' "$PROVER"; then
  ok "generic default metamorphic relation present (put/take round-trip)"
else
  bad "generic default metamorphic relation missing (put/take round-trip)"
fi

if grep -q 'commut' "$PROVER" && grep -q 'monoton' "$PROVER"; then
  ok "the round-trip / commutativity / monotonicity vocabulary is present"
else
  bad "the commutativity/monotonicity vocabulary is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) VERDICT CONTRACT UNTOUCHED — the INVARIANT| marker + the #1471 target-linkage gate strings are still there,
#    byte-identical. The metamorphic block is prompt steering only; it must NEVER become a second gate.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the #1726 (M1) change left the verdict/marker/linkage contract intact ..."

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the INVARIANT|<target>|<verdict> marker emission is unchanged (fuzzer stays the sole verdict)"
else
  bad "the INVARIANT| marker emission changed unexpectedly"
fi

if grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 --require-import/--require-contract target-linkage gate strings are intact"
else
  bad "the #1471 target-linkage gate strings changed unexpectedly"
fi

# The #1725 handler-action normalizer count must stay EXACTLY 2 (M1 uses a distinct `mk` var so it does not
# inflate that count — it still normalizes through the same helper).
if [ "$(grep -c 'let k = class_to_keyword(to_lower(klass));' "$PROVER")" -eq 2 ]; then
  ok "the #1725 handler-action normalizer count is still exactly 2 (M1 did not collide with it)"
else
  bad "the #1725 handler-action normalizer count changed (M1 collided with action_checklist_* wiring)"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) NO NEW ENV — the metamorphic lever reused the existing TARGET_CLASS; run-invariant-hunt.sh's
#    exec.env_passthrough allowlist got no new entry.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1726 (M1) added no new env surface ..."

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT' "$RUNNER"; then
  ok "exec.env_passthrough allowlist in run-invariant-hunt.sh is unchanged (no new var appended)"
else
  bad "exec.env_passthrough allowlist in run-invariant-hunt.sh changed unexpectedly"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1726 (M1) metamorphic-relation prompt lever is wired — metamorphic_relation_prompt() is defined,"
  note "      normalizes through class_to_keyword(to_lower()), threaded into sharedScaffold as an ALTERNATIVE"
  note "      shape for the SAME single invariant; all 5 per-class relation menus plus the generic default are"
  note "      present; the INVARIANT| marker + #1471 linkage gate are untouched; and no new env var was added."
  exit 0
fi
note "DEMO FAILED — a #1726 (M1) metamorphic-relation wiring assertion did not hold" >&2
exit 1
