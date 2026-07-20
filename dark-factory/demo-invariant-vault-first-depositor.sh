#!/usr/bin/env bash
# demo-invariant-vault-first-depositor.sh — proof of the #1755 M2 VAULT-CLASS invariant + Handler routing on the
# deep-hunt path.
#
# The live-hunt pipeline (zone-mapper.ag -> run-zone-hunt.sh dominant_class() -> run-invariant-hunt.sh --class)
# COLLAPSES yearn's zone [C15,C10,C11,C2] to a single dominant code that resolves to C10 -> class_to_keyword("c10")
# == "lend", so the VAULT branches of the generation selectors never fire on the very target whose money-tier bug
# (the yearn-ybold H-1 first-depositor / share-inflation High) is a vault first-depositor. M1 already makes the
# harness deploy the REAL TokenizedStrategy singleton (so the ERC4626 share path is actually fuzzed); M2 routes the
# GENERATION to produce the vault first-depositor victim-fairness invariant + the 2-actor donation Handler for that
# target, so the harness catches H-1.
#
# M2 fixes the class collapse INSIDE the prover via an EFFECTIVE-CLASS override gated on M1's vaultRoute (leaving
# dominant_class() byte-identical): effective_class(targetClass, vaultRoute) returns "C11" on the vault route and
# feeds effClass into the GENERATION selectors ONLY — action_checklist_hint / action_checklist_prompt (the #1725
# direct-donation + first-depositor + >=2-actor checklist), metamorphic_relation_prompt (the #1726 round-trip /
# monotonicity relation), and recall_pattern (invpat:invented:C11, the #1733 first-depositor seed). A new
# victim_fairness_invariant_prompt() weaves the #1724 inv_victim_not_robbed SHAPE into sharedScaffold, gated on
# vaultRoute. The FUZZER stays the SOLE verdict: verdict_of, the INVARIANT| marker, emit/learn/persist_*, and the
# #1471 --require-import/--require-contract gate all keep targetClass — only the generation prompt uses effClass.
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis, no forge, no LLM): it asserts the prover
# wiring is present, the four generation selectors take effClass, the victim-fairness directive is present +
# vault-gated + returns "" when inactive, the verdict/marker/#1471/persist path is still keyed on targetClass, and
# the default-off byte-identical contract holds (no vaultRoute => effClass == targetClass => "" directive).
#
# Usage:  dark-factory/demo-invariant-vault-first-depositor.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-vault-first-depositor.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) EFFECTIVE-CLASS OVERRIDE — effective_class() forces C11 on the vault route, else returns the class
#    unchanged; effClass is computed from targetClass + M1's vaultRoute.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 M2 effective-class override ..."

if grep -q 'fn effective_class(klass: string, route: bool) -> string' "$PROVER"; then
  ok "effective_class() is defined on the prover"
else
  bad "effective_class() missing from the prover"
fi

if grep -q 'if route { return "C11"; }' "$PROVER" && grep -q 'let effClass = effective_class(targetClass, vaultRoute);' "$PROVER"; then
  ok "effective_class() forces C11 under vaultRoute and effClass reuses M1's vaultRoute"
else
  bad "effective_class() does not force C11 under vaultRoute / effClass not wired to targetClass + vaultRoute"
fi

# The default-off byte-identical hinge: with !route the override returns the class VERBATIM (effClass == targetClass
# when vaultRoute is false), so a non-vault run's generation prompt is unchanged.
if grep -q 'fn effective_class(klass: string, route: bool) -> string' "$PROVER" \
   && grep -qE '^[[:space:]]*return klass;' "$PROVER"; then
  ok "effective_class() returns klass verbatim when !route (default-off byte-identical: effClass == targetClass)"
else
  bad "effective_class() does not fall through to the unchanged class when !route"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) GENERATION SELECTORS TAKE effClass — the four selectors that steer the vault branches receive effClass, so
#    on the vault route the C11 vault menus fire despite dominant_class() collapsing the class to C10.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the GENERATION selectors receive effClass (not targetClass) ..."

if grep -q 'action_checklist_hint(effClass)' "$PROVER"; then
  ok "harness_skeleton() call site passes action_checklist_hint(effClass)"
else
  bad "action_checklist_hint() call site does not pass effClass"
fi

if grep -q 'action_checklist_prompt(effClass)' "$PROVER"; then
  ok "sharedScaffold calls action_checklist_prompt(effClass)"
else
  bad "sharedScaffold does not call action_checklist_prompt(effClass)"
fi

if grep -q 'metamorphic_relation_prompt(effClass)' "$PROVER"; then
  ok "sharedScaffold calls metamorphic_relation_prompt(effClass)"
else
  bad "sharedScaffold does not call metamorphic_relation_prompt(effClass)"
fi

if grep -q 'let prior = recall_pattern(effClass);' "$PROVER"; then
  ok "recall_pattern() is consulted on effClass (invpat:invented:C11, the #1733 first-depositor seed)"
else
  bad "recall_pattern() is not consulted on effClass"
fi

# The three GENERATION selectors must NOT have been left on targetClass at their sharedScaffold/skeleton call sites
# (that would defeat the C11 route). We assert the OLD targetClass call-forms are gone.
if grep -q 'action_checklist_hint(targetClass)' "$PROVER" \
   || grep -q 'action_checklist_prompt(targetClass)' "$PROVER" \
   || grep -q 'metamorphic_relation_prompt(targetClass)' "$PROVER"; then
  bad "a GENERATION selector is still called on targetClass (the vault route would never fire)"
else
  ok "no GENERATION selector call site is left on targetClass (all rerouted to effClass)"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) VICTIM-FAIRNESS INVARIANT — the #1724 inv_victim_not_robbed shape is present, carries the redeemable >=
#    deposited - dust property with a plain require(), is vault-gated (active), and returns "" when inactive.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 M2 vault victim-fairness invariant directive ..."

if grep -q 'fn victim_fairness_invariant_prompt(klass: string, active: bool) -> string' "$PROVER"; then
  ok "victim_fairness_invariant_prompt() is defined on the prover"
else
  bad "victim_fairness_invariant_prompt() missing from the prover"
fi

if grep -q 'VAULT VICTIM-FAIRNESS INVARIANT' "$PROVER"; then
  ok "the VAULT VICTIM-FAIRNESS INVARIANT block header is present"
else
  bad "the VAULT VICTIM-FAIRNESS INVARIANT block header is missing"
fi

if grep -q 'shares \* assetBalance / totalShares' "$PROVER"; then
  ok "the redeemable-value shape (shares * assetBalance / totalShares) is present"
else
  bad "the redeemable-value shape is missing"
fi

# #1755 M4 — RELATIVE tolerance (not absolute dust). The first-depositor / share-inflation theft is PROPORTIONAL and
# maximal at the wei-scale totalAssets=2/totalSupply=1 boundary, where an absolute +1e12 dust dwarfs the loss and
# never trips; a relative integer-math tolerance (redeemable * 10000 >= deposited * 9900, a 1% band) trips the
# proportional theft at ANY scale. The absolute-dust require() form must be GONE.
if grep -q 'require(redeemable \* 10000 >= deposited \* 9900)' "$PROVER"; then
  ok "the plain-require assertion is the RELATIVE integer-math tolerance (require(redeemable * 10000 >= deposited * 9900), a 1% band)"
else
  bad "the RELATIVE-tolerance plain-require assertion (redeemable * 10000 >= deposited * 9900) is missing"
fi

if grep -q 'require(redeemable + dust >= deposited)' "$PROVER"; then
  bad "the OLD absolute-dust require(redeemable + dust >= deposited) form is still present (a coarse dust never trips the wei-scale theft)"
else
  ok "the absolute-dust require() form is gone (replaced by the relative tolerance)"
fi

if grep -q 'a proportional epsilon' "$PROVER" && grep -q 'NOT an absolute rounding `dust`' "$PROVER"; then
  ok "the directive tells the model to use a RELATIVE (proportional epsilon) tolerance, not an absolute dust"
else
  bad "the RELATIVE-vs-absolute tolerance guidance is missing from the victim-fairness directive"
fi

if grep -q 'track each victim' "$PROVER"; then
  ok "the Handler is directed to track each victim's (deposited, shares)"
else
  bad "the per-victim (deposited, shares) tracking directive is missing"
fi

# Vault-gated: the FIRST statement of the function returns "" when !active (so a non-vault run adds NOTHING to the
# prompt), and sharedScaffold weaves the call gated on vaultRoute.
if grep -q 'if !active { return ""; }' "$PROVER"; then
  ok "victim_fairness_invariant_prompt() returns \"\" when inactive (!active early return)"
else
  bad "victim_fairness_invariant_prompt() is not gated on active (no !active early return)"
fi

if grep -q 'victim_fairness_invariant_prompt(effClass, vaultRoute)' "$PROVER"; then
  ok "sharedScaffold weaves victim_fairness_invariant_prompt gated on vaultRoute"
else
  bad "sharedScaffold does not weave victim_fairness_invariant_prompt gated on vaultRoute"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) VERDICT CONTRACT UNTOUCHED — effClass touches ONLY the generation prompt. The verdict path (INVARIANT|
#    marker, emit, learn, persist_*, teeth) and the #1471 linkage gate all stay keyed on targetClass.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the verdict/marker/#1471/persist path stays on targetClass ..."

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

if grep -q 'let teeth = measure_teeth(verdict, mutantKill, targetClass, invOut);' "$PROVER" \
   && grep -q 'let learnTags = learn_tags(targetClass, verdict, outcome, teeth);' "$PROVER" \
   && grep -q 'learn("invariant-prove", targetClass + ":" + targetFn' "$PROVER"; then
  ok "the teeth/learn path is still keyed on targetClass (NOT effClass)"
else
  bad "the teeth/learn path drifted off targetClass"
fi

if grep -q 'persist_pattern(verdict, targetClass, targetFn, invMatch);' "$PROVER" \
   && grep -q 'persist_teeth(verdict, teeth, targetClass, targetFn, invMatch);' "$PROVER" \
   && grep -q 'persist_corpus(corpusOn, verdict, targetClass, targetFn, invMatch);' "$PROVER"; then
  ok "persist_pattern/persist_teeth/persist_corpus are still keyed on targetClass (NOT effClass)"
else
  bad "a persist_* call drifted off targetClass"
fi

if grep -q '\\"class\\":\\"" + targetClass + "\\"' "$PROVER"; then
  ok "the emit() verdict event class field is still targetClass"
else
  bad "the emit() verdict event class field drifted off targetClass"
fi

# The BUG CLASS (lens) header the fuzzer verdict is reported under must also stay on targetClass — only the
# adversarial/metamorphic/victim-fairness GENERATION steering keys on effClass.
if grep -q '"=== BUG CLASS (lens) ===\\n" + targetClass + "\\n\\n"' "$PROVER"; then
  ok "the BUG CLASS (lens) header is still rendered from targetClass"
else
  bad "the BUG CLASS (lens) header drifted off targetClass"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) DEFAULT-OFF BYTE-IDENTICAL + NO NEW ENV — with the flag off vaultRoute is false, effClass == targetClass,
#    and victim_fairness_invariant_prompt returns "" => the generation prompt is byte-identical. M2 added no new
#    env var to run-invariant-hunt.sh's exec.env_passthrough allowlist (M1's INV_CORE_DEP already gates it).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the default-off byte-identical contract + no-new-env surface ..."

# vaultRoute is M1's gate: empty INV_CORE_DEP OR a non-yearn target => false. effClass == targetClass then, and the
# victim-fairness directive is "" — so the whole M2 addition is inert off the vault route.
if grep -q 'let vaultRoute = vault_route(coreDep, code);' "$PROVER"; then
  ok "effClass/victim-fairness are gated on M1's vaultRoute (empty INV_CORE_DEP or non-yearn => false => inert)"
else
  bad "vaultRoute (the M1 gate M2 reuses) is missing"
fi

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT' "$RUNNER"; then
  ok "M2 added no new env var to run-invariant-hunt.sh's exec.env_passthrough allowlist"
else
  bad "run-invariant-hunt.sh's exec.env_passthrough allowlist changed unexpectedly"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1755 M2 vault first-depositor victim-fairness routing is wired — effective_class() forces C11 on"
  note "      the vaultRoute, the four GENERATION selectors take effClass, victim_fairness_invariant_prompt()"
  note "      carries the redeemable->=-deposited-dust shape and is vault-gated (\"\" when inactive); the verdict/"
  note "      marker/#1471/persist path stays on targetClass; and default-off the prompt is byte-identical."
  exit 0
fi
note "DEMO FAILED — a #1755 M2 vault first-depositor victim-fairness wiring assertion did not hold" >&2
exit 1
