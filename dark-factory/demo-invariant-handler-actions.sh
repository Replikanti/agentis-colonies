#!/usr/bin/env bash
# demo-invariant-handler-actions.sh — proof of the #1725 ADVERSARIAL/MULTI-ACTOR Handler action checklist on the
# deep-hunt path.
#
# The #1716 A/B isolated a DELTA gap: the LLM names a plausible deep invariant but the Handler it writes never
# gives the fuzzer the ADVERSARIAL action space needed to actually break it (no direct-donation action, only one
# actor, no liquidation/sandwich/reentrancy sequence) — the fuzzer can only search sequences over the actions the
# Handler exposes. #1725 adds two flat string-building functions to invariant-prover.ag, keyed off the SAME
# TARGET_CLASS already threaded through the module (no new env var): action_checklist_hint() (a one-line hint
# woven into the Handler's Solidity comment) and action_checklist_prompt() (the fuller MUST-include checklist
# appended to the generation prompt). Five protocol-CLASS branches (vault/ERC4626, lending/CDP, staking, AMM,
# reentrancy) plus a generic multi-actor+perturbation default so an unclassified target still benefits.
#
# This is a SOURCE-GUARD demo (always CI-safe, no toolchain, no agentis, no forge, no LLM): it asserts the prover
# wiring is present, each per-class checklist (plus the default) is textually present, the verdict/marker/#1471
# gate contract is unchanged, and TARGET_CLASS plumbing (the exec.env_passthrough allowlist) got no new entries.
#
# Usage:  dark-factory/demo-invariant-handler-actions.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-handler-actions.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) WIRING — both new functions exist, harness_skeleton takes actionHint, the call site passes
#    action_checklist_hint(targetClass), and sharedScaffold carries the checklist header + call.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1725 prover wiring ..."

if grep -q 'fn action_checklist_hint(klass: string) -> string' "$PROVER"; then
  ok "action_checklist_hint() is defined on the prover"
else
  bad "action_checklist_hint() missing from the prover"
fi

if grep -q 'fn action_checklist_prompt(klass: string) -> string' "$PROVER"; then
  ok "action_checklist_prompt() is defined on the prover"
else
  bad "action_checklist_prompt() missing from the prover"
fi

if grep -q 'actionHint: string' "$PROVER"; then
  ok "harness_skeleton() takes the new actionHint parameter"
else
  bad "harness_skeleton() missing the actionHint parameter"
fi

if grep -q 'ADVERSARIAL ACTION HINT: ' "$PROVER"; then
  ok "harness_skeleton() weaves the ADVERSARIAL ACTION HINT comment line into the Handler block"
else
  bad "harness_skeleton() missing the ADVERSARIAL ACTION HINT comment line"
fi

if grep -q 'harness_skeleton(invMatch, deployName, importLine, auxImportLines, action_checklist_hint(targetClass))' "$PROVER"; then
  ok "the harness_skeleton() call site passes action_checklist_hint(targetClass)"
else
  bad "the harness_skeleton() call site does not pass action_checklist_hint(targetClass)"
fi

if grep -q 'ADVERSARIAL ACTION CHECKLIST' "$PROVER"; then
  ok "sharedScaffold carries the ADVERSARIAL ACTION CHECKLIST header"
else
  bad "sharedScaffold missing the ADVERSARIAL ACTION CHECKLIST header"
fi

if grep -q 'action_checklist_prompt(targetClass)' "$PROVER"; then
  ok "sharedScaffold calls action_checklist_prompt(targetClass)"
else
  bad "sharedScaffold does not call action_checklist_prompt(targetClass)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) PER-CLASS COVERAGE — each of the 5 classes (plus the generic default) has its distinguishing checklist
#    text present in the prover source.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1725 per-class checklist coverage ..."

if grep -q 'direct-donation' "$PROVER" && grep -q 'first-depositor' "$PROVER"; then
  ok "vault/ERC4626 checklist present (direct-donation + first-depositor)"
else
  bad "vault/ERC4626 checklist missing (direct-donation / first-depositor)"
fi

if grep -q '>=2 borrower' "$PROVER" && grep -q 'liquidation sequence' "$PROVER"; then
  ok "lending/CDP checklist present (>=2 borrower + liquidation sequence)"
else
  bad "lending/CDP checklist missing (>=2 borrower / liquidation sequence)"
fi

if grep -q 'staker addresses' "$PROVER" && grep -q 'reward-timing' "$PROVER"; then
  ok "staking checklist present (staker addresses + reward-timing)"
else
  bad "staking checklist missing (staker addresses / reward-timing)"
fi

if grep -q 'sandwich' "$PROVER"; then
  ok "AMM checklist present (sandwich)"
else
  bad "AMM checklist missing (sandwich)"
fi

if grep -q 'reentrancy-actor' "$PROVER"; then
  ok "reentrancy checklist present (reentrancy-actor)"
else
  bad "reentrancy checklist missing (reentrancy-actor)"
fi

if grep -q 'direct external-perturbation action' "$PROVER"; then
  ok "generic default fallback checklist present (direct external-perturbation action)"
else
  bad "generic default fallback checklist missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) VERDICT CONTRACT UNTOUCHED — the INVARIANT| marker + the #1471 target-linkage gate strings are still there,
#    byte-identical.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that the #1725 change left the verdict/marker/linkage contract intact ..."

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

# ----------------------------------------------------------------------------------------------------------
# 4) NO NEW ENV — TARGET_CLASS was already on the exec.env_passthrough allowlist; the enrichment reused it and
#    did not append a new env var to run-invariant-hunt.sh's passthrough list.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1725 added no new env surface ..."

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT' "$RUNNER"; then
  ok "exec.env_passthrough allowlist in run-invariant-hunt.sh is unchanged (no new var appended)"
else
  bad "exec.env_passthrough allowlist in run-invariant-hunt.sh changed unexpectedly"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1725 adversarial/multi-actor Handler action checklist is wired — action_checklist_hint()/"
  note "      action_checklist_prompt() are defined, threaded through harness_skeleton() and sharedScaffold,"
  note "      keyed off the existing TARGET_CLASS; all 5 per-class checklists plus the generic default are"
  note "      present; the INVARIANT| marker + #1471 linkage gate are untouched; and no new env var was added."
  exit 0
fi
note "DEMO FAILED — a #1725 handler-action-checklist wiring assertion did not hold" >&2
exit 1
