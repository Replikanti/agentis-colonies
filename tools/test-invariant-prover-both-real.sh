#!/usr/bin/env bash
# tools/test-invariant-prover-both-real.sh -- deterministic regression guard
# for #1077 (dark-factory, FM2). In composable-fresh mode (#1075, INV_AUX
# non-empty) the prover was supposed to deploy + wire the target AND each aux
# contract REAL. Validation on two real pairs showed it instead deployed only
# the EASIER contract real and mocked/omitted the harder one (e.g.
# `--target dreUSDs --aux dreRewardsDistributor` -> real distributor + a
# `RewardVaultMock`; `--target dreUSDManager --aux dreUSDOracle` -> real oracle,
# manager never imported). A CLEAN on a harness that mocked the unit-under-test
# is a FALSE verdict.
#
# #1077 ENFORCES both-real via validation + targeted repair (reusing the #1073
# loop), NOT a Solidity-parsing deploy scaffold. Only active in composable-fresh
# mode (INV_AUX non-empty); the single-target (#1070-B1) and offline
# (HANDLER_FIXTURE) paths are byte-identical / untouched. The defence:
#   1. `missing_real_deploys(testSrc, names)` reports each required contract
#      name ({target} U {each aux}) that is MISSING a `new <name>(` deploy marker
#      (covers plain `new` and the `new ERC1967Proxy(address(new <name>()...` proxy
#      form; the trailing `(` anchors the name so `new <name>Mock(` never matches)
#      -- i.e. dropped or mocked. (A canonical `import {<name>}` is NOT required:
#      it false-positived on legal grouped/spaced/aliased imports.)
#   2. The #1073 repair trigger is EXTENDED: a round also fires when
#      composable-fresh AND missing_real_deploys is non-empty, with a POINTED
#      repair prompt naming the missing contracts.
#   3. After the repair budget is exhausted, a RESIDUAL both-real violation
#      (composable-fresh + still missing) FORCES the emitted verdict to
#      HARNESS_ERROR -- a partial CLEAN/FINDING never leaks as a real verdict.
#
# This test pins all of that so it cannot silently regress. Pure grep/awk over
# the .ag source -- no agentis runtime, no LLM, no forge required.
# Auto-discovered and run by tools/colony-lint.sh's `tools/test-*.sh` loop.
#
# Assertions:
#   (a) The both-real check exists: a `missing_real_deploys()` helper backed by
#       a `has_real_deploy()` that requires the `new <name>(` deploy marker (the
#       sole marker per name), built over the {target} U {aux} `requiredNames` set.
#   (b) It gates an EXTRA repair trigger in composable-fresh mode: a both-real-
#       aware `stop_flag_both()` keeps the loop going on a terminal verdict that
#       still has missing real deploys (composable-fresh only), and
#       `repair_step` drives the round on that violation.
#   (c) The pointed repair message names the missing contracts: a
#       `repair_instruction_bothreal()` carrying the "did NOT deploy these
#       REQUIRED real contracts" framing + the missing list, routed through
#       `prompt()` via `repair_test_bothreal()`.
#   (d) A RESIDUAL both-real violation after the repair budget FORCES
#       HARNESS_ERROR: the final-verdict computation overrides verdict_of(rc)
#       to HARNESS_ERROR when composable-fresh AND missing_real_deploys still
#       non-empty.
#   (e) The single-target / fixture paths are NOT subject to enforcement: the
#       both-real check + override are gated behind `composableFresh` (so
#       requiredNames/missing collapse to inert when INV_AUX is empty), and the
#       fixture-excluded-from-repair seed (#1073) survives.
#
# Usage: bash tools/test-invariant-prover-both-real.sh

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

# Whole-file source (the enforcement spans several helpers + the driver).
src="$(cat "$AG")"

# (a) The both-real check exists: missing_real_deploys() over has_real_deploy(),
# which requires BOTH markers per name; the requiredNames set is {target} U
# {aux names}, dropping empty names.
a_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+missing_real_deploys\(' \
    || a_fail="${a_fail} no-missing_real_deploys"
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+has_real_deploy\(' \
    || a_fail="${a_fail} no-has_real_deploy"
# The NEW (deploy) marker per name covers plain `new <name>(` and the proxy form
# `new ERC1967Proxy(address(new <name>()...`, both of which contain `new <name>(`.
# The trailing `(` anchors the name (so `new <name>Mock(` never matches). This is
# the SOLE marker: a canonical `import {<name>}` is deliberately NOT required (it
# false-positived on legal grouped/spaced/aliased imports and could suppress a
# genuine finding to HARNESS_ERROR); a `new <name>(` the gate compiles is in scope.
printf '%s\n' "$src" | grep -Fq 'index_of(testSrc, "new " + name + "(")' \
    || a_fail="${a_fail} no-new-marker"
# requiredNames is {target} U {aux names}.
printf '%s\n' "$src" | grep -Fq 'let requiredNames = reduce(auxEntries' \
    || a_fail="${a_fail} no-requiredNames"
printf '%s\n' "$src" | grep -Fq 'if len(targetName) > 0 { [targetName] } else { [] }' \
    || a_fail="${a_fail} no-target-in-set"

if [ -z "$a_fail" ]; then
    pass "(a) missing_real_deploys()/has_real_deploy() require the new-deploy marker over the {target} U {aux} set"
else
    fail "(a) the both-real check exists with the import+new markers" \
         "missing piece(s):$a_fail"
fi

# (b) It gates an EXTRA repair trigger in composable-fresh mode: a both-real-
# aware stop_flag_both() that keeps the loop going on a terminal verdict with
# missing real deploys (composable-fresh only), and repair_step drives the
# round on the violation.
b_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+stop_flag_both\(' \
    || b_fail="${b_fail} no-stop_flag_both"
# Outside composable-fresh stop_flag_both is byte-identical to stop_flag (only
# the rc decides) -- the inactive short-circuit.
awk '/^fn stop_flag_both\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if !composeFresh { return "1"; }' \
    || b_fail="${b_fail} no-inactive-passthrough"
# In composable-fresh, a residual missing list keeps the loop going.
awk '/^fn stop_flag_both\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if len(missing_real_deploys(testSrc, names)) > 0 { return "0"; }' \
    || b_fail="${b_fail} no-keep-going-on-violation"
# repair_step computes the violation and chooses the both-real repair path.
awk '/^fn repair_step\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'let bothRealViolation = if stop_flag(prevRc) == "1" { len(missing) > 0 } else { false };' \
    || b_fail="${b_fail} no-violation-detect"
# The loop + first-attempt stop are both-real aware (threaded composeFresh/names). The gate-args slot carries
# `gateExtra` (fork + the #1471 target-linkage args) since #1471 — previously the bare `fork`. Since #1720 the
# loop also carries the re-injected generation scaffold as the trailing arg (`sharedScaffold`); since #1939 M2
# (FM-B symbol grounding) that trailing arg is `sharedScaffold + symbolInventorySeed`, so every repair round is
# grounded against the real symbol inventory too (empty seed => `+ ""` => byte-identical).
printf '%s\n' "$src" | grep -Fq 'let firstStop = stop_flag_both(rc_of(firstOut), test, composableFresh, requiredNames);' \
    || b_fail="${b_fail} no-bothreal-first-stop"
printf '%s\n' "$src" | grep -Fq 'repair_loop(initState, repairRounds, gate, invRepo, invOut, invMatch, budget, gateExtra, composableFresh, requiredNames, sharedScaffold + symbolInventorySeed)' \
    || b_fail="${b_fail} no-threaded-loop"

if [ -z "$b_fail" ]; then
    pass "(b) composable-fresh adds an extra repair trigger via stop_flag_both() + the repair_step violation detect"
else
    fail "(b) composable-fresh gates an extra repair trigger" \
         "missing piece(s):$b_fail"
fi

# (c) The pointed repair message names the missing contracts: a
# repair_instruction_bothreal() carrying the "did NOT deploy these REQUIRED
# real contracts" framing + the missing list, routed through prompt() via
# repair_test_bothreal().
c_fail=""
printf '%s\n' "$src" | grep -Eq 'fn[[:space:]]+repair_instruction_bothreal\(' \
    || c_fail="${c_fail} no-repair_instruction_bothreal"
printf '%s\n' "$src" | grep -Fq 'did NOT deploy these REQUIRED real contracts (you mocked or omitted them):' \
    || c_fail="${c_fail} no-pointed-framing"
# The instruction must inject the missing-contracts list (concatenated right
# after the "...): " framing) AND the prior source.
awk '/^fn repair_instruction_bothreal\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'them): " + missing' \
    || c_fail="${c_fail} no-missing-list"
awk '/^fn repair_instruction_bothreal\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq '+ prevSrc' \
    || c_fail="${c_fail} no-prior-source"
# It must tell the model to keep the already-real ones.
printf '%s\n' "$src" | grep -Fq 'Keep the ones you already deployed real.' \
    || c_fail="${c_fail} no-keep-real"
# repair_test_bothreal() routes the pointed instruction through prompt().
awk '/^fn repair_test_bothreal\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'prompt(repair_instruction_bothreal(' \
    || c_fail="${c_fail} no-bothreal-prompt"

if [ -z "$c_fail" ]; then
    pass "(c) the pointed both-real repair message names the missing contracts + is routed through prompt()"
else
    fail "(c) the pointed repair message names the missing contracts" \
         "missing piece(s):$c_fail"
fi

# (d) A RESIDUAL both-real violation after the repair budget FORCES
# HARNESS_ERROR: the final-verdict computation overrides verdict_of(rc) to
# HARNESS_ERROR when composable-fresh AND missing_real_deploys still non-empty.
d_fail=""
# The residual missing list is computed from the FINAL harness, gated on
# composable-fresh.
printf '%s\n' "$src" | grep -Fq 'let bothRealMissing = if composableFresh { if usedFixture { "" } else { missing_real_deploys(finalSrc, requiredNames) } } else { "" };' \
    || d_fail="${d_fail} no-residual-compute"
printf '%s\n' "$src" | grep -Fq 'let bothRealViolated = len(bothRealMissing) > 0;' \
    || d_fail="${d_fail} no-residual-flag"
# final_verdict() forces HARNESS_ERROR on the violation, else verdict_of(rc).
awk '/^fn final_verdict\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if violated { return "HARNESS_ERROR"; }' \
    || d_fail="${d_fail} no-force-harness-error"
printf '%s\n' "$src" | grep -Fq 'let verdict = final_verdict(rc, bothRealViolated);' \
    || d_fail="${d_fail} no-override-binding"
# A clear stderr/marker reason is surfaced on the override.
printf '%s\n' "$src" | grep -Fq 'harness mocked/omitted required real contract(s):' \
    || d_fail="${d_fail} no-stderr-reason"

if [ -z "$d_fail" ]; then
    pass "(d) a residual both-real violation forces the emitted verdict to HARNESS_ERROR (no partial CLEAN leak)"
else
    fail "(d) a residual both-real violation forces HARNESS_ERROR" \
         "missing piece(s):$d_fail"
fi

# (e) The single-target / fixture paths are NOT subject to enforcement: the
# both-real check + override are gated behind composableFresh (so they collapse
# to inert when INV_AUX is empty), and the fixture-excluded-from-repair seed
# (#1073) survives.
e_fail=""
# The residual override is gated behind composableFresh (the trailing `else { "" }`
# makes it inert on the single-target path) AND, within composable-fresh, behind
# NOT usedFixture (an operator HANDLER_FIXTURE run with --aux is never force-
# overridden — it is already never repaired).
printf '%s\n' "$src" | grep -Fq 'if composableFresh { if usedFixture { "" } else { missing_real_deploys(finalSrc, requiredNames) } } else { "" }' \
    || e_fail="${e_fail} no-singletarget-inert"
# stop_flag_both is byte-identical to stop_flag outside composable-fresh.
awk '/^fn stop_flag_both\(/{f=1} f{print} f&&/^}/{exit}' "$AG" \
    | grep -Fq 'if !composeFresh { return "1"; }' \
    || e_fail="${e_fail} no-singletarget-stop"
# The #1073 fixture-excluded-from-repair seed must survive (the offline fixture
# path is never repaired, so it is never both-real-enforced either).
printf '%s\n' "$src" | grep -Fq 'let initStopped = if usedFixture { "1" } else { firstStop };' \
    || e_fail="${e_fail} no-fixture-seed"

if [ -z "$e_fail" ]; then
    pass "(e) the single-target + fixture paths are NOT subject to both-real enforcement (composableFresh-gated; fixture seed survives)"
else
    fail "(e) the single-target / fixture paths are unaffected" \
         "missing piece(s):$e_fail"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
