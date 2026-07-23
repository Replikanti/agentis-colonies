#!/usr/bin/env bash
# demo-harness-mocks.sh — proof of the #1794 SHARED HARNESS-MOCK LIBRARY on the deep-hunt generation path.
#
# The prover used to hand-author EVERY external-dependency mock inside each generated harness. On complex targets
# that is exactly where generation failed: an LP oracle needing Curve/Balancer-style pricing reads, or a modular
# vault needing a share-vault dependency, produced a test that did not compile — a HARNESS_ERROR, i.e. NO verdict
# (and, on the observed runs, a retry-forever loop). #1794 replaces the per-run re-derivation with a small library
# of pre-written, pre-compiled mocks (`auditor/harness-mocks/`) that run-invariant-hunt.sh STAGES into the
# generated harness project at `<repo>/test/mocks/` before the prover writes/compiles, plus an additive prover
# directive telling the model to IMPORT them instead of authoring another copy.
#
# This is a SOURCE-GUARD + BEHAVIOURAL demo (CI-safe: no agentis, no forge, no LLM, no network). It asserts:
#   1) the library exists and honours its contract — dependency-free, `pragma >=0.8.0`, unique top-level names,
#      and INERT for test discovery (no test contract, no `test*`/`invariant_*` function);
#   2) the staging step is wired into run-invariant-hunt.sh, runs BEFORE the prover is launched, and — executed
#      for real against a fixture repo — copies ONLY into `test/mocks/`, never clobbering a repo's own mock and
#      never touching foundry.toml / src/ / existing tests (the "inert when unused" contract);
#   3) the prover prompt references the staged library with the exact import paths, re-injected on every
#      compile-repair round via sharedScaffold;
#   4) #1794 left the verdict/marker/linkage contract and the #1725 normalizer count untouched.
#
# Usage:  dark-factory/demo-harness-mocks.sh
# Exit: 0 = all assertions hold ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MOCKS="$HERE/auditor/harness-mocks"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-harness-mocks.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }

for f in "$PROVER" "$RUNNER"; do
  [ -f "$f" ] || { note "required file not found: $f" >&2; exit 3; }
done
[ -d "$MOCKS" ] || { note "harness-mock library not found: $MOCKS" >&2; exit 3; }

MOCK_FILES="MockAggregatorV3.sol MockERC20.sol MockVault4626.sol MockPool.sol"

# ----------------------------------------------------------------------------------------------------------
# 1) THE LIBRARY AND ITS CONTRACT — the four dependency shapes that broke the runs are present, each file is
#    dependency-free (a single `import` would break compilation in a bare Foundry project with no remappings),
#    carries the deliberately-wide `pragma solidity >=0.8.0`, and declares no test surface.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1794 harness-mock library ..."

for m in $MOCK_FILES; do
  if [ -f "$MOCKS/$m" ]; then
    ok "$m is present in auditor/harness-mocks/"
  else
    bad "$m is missing from auditor/harness-mocks/ (the dependency shape it covers regresses to hand-authoring)"
  fi
done

# DEPENDENCY-FREE: not one `import` statement anywhere in the library. This is the load-bearing property — the
# staged project has ZERO remappings, so any import (OpenZeppelin, solmate, forge-std, even a sibling mock)
# would fail to compile and turn EVERY run into a HARNESS_ERROR instead of fixing the ones that were failing.
_imports="$(grep -lE '^[[:space:]]*import[[:space:]]' "$MOCKS"/*.sol 2>/dev/null)"
if [ -z "$_imports" ]; then
  ok "every mock is dependency-free (no import statement anywhere in the library)"
else
  bad "a mock carries an import — it will not compile in a bare Foundry project: $(echo "$_imports" | tr '\n' ' ')"
fi

# WIDE PRAGMA: the mock must compile under whatever 0.8.x the STAGED TARGET project pins, not only under the
# harness's own ^0.8.20. Verified against solc 0.8.0 and the current default at authoring time.
_bad_pragma=""
for f in "$MOCKS"/*.sol; do
  grep -q '^pragma solidity >=0\.8\.0;' "$f" || _bad_pragma="$_bad_pragma $(basename "$f")"
done
if [ -z "$_bad_pragma" ]; then
  ok "every mock pins the wide 'pragma solidity >=0.8.0;' (compiles under the target project's own 0.8.x)"
else
  bad "a mock narrowed its pragma (it will not compile in an older-0.8.x project):$_bad_pragma"
fi

# UNIQUE TOP-LEVEL NAMES: a harness may import all four into ONE file, so no two files may declare the same
# contract/interface/library name ("Identifier already declared" otherwise).
_dupes="$(grep -hoE '^(contract|interface|library)[[:space:]]+[A-Za-z0-9_]+' "$MOCKS"/*.sol \
          | awk '{print $2}' | sort | uniq -d)"
if [ -z "$_dupes" ]; then
  ok "top-level contract/interface names are unique across the library (all four import into one file)"
else
  bad "duplicate top-level name(s) across the library — a multi-mock import will not compile: $_dupes"
fi

# INERT FOR TEST DISCOVERY: the library declares no `test*` / `invariant_*` function and no `*.t.sol`, so
# staging it adds nothing forge would run and cannot change any verdict.
_discoverable="$(grep -lE 'function[[:space:]]+(test|invariant_)' "$MOCKS"/*.sol 2>/dev/null)"
if [ -z "$_discoverable" ] && [ -z "$(find "$MOCKS" -name '*.t.sol' 2>/dev/null)" ]; then
  ok "the library declares no test*/invariant_* function and no *.t.sol (forge discovers nothing new)"
else
  bad "the library exposes a discoverable test surface — staging could change a verdict"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) STAGING WIRED IN THE RUNNER — HARNESS_MOCKS_SRC resolves the library, the copy lands in the harness
#    project's `test/mocks/`, and it happens BEFORE the prover is launched.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1794 staging step in run-invariant-hunt.sh ..."

if grep -q 'HARNESS_MOCKS_SRC="\$HERE/auditor/harness-mocks"' "$RUNNER"; then
  ok "the runner resolves HARNESS_MOCKS_SRC to auditor/harness-mocks"
else
  bad "the runner does not resolve HARNESS_MOCKS_SRC (the library would never be staged)"
fi

if grep -q 'mkdir -p "\$REPO_IN_RUN/test/mocks"' "$RUNNER"; then
  ok "the runner stages the library into the harness project's test/mocks/ (so ./mocks/<Name>.sol resolves)"
else
  bad "the runner does not create \$REPO_IN_RUN/test/mocks (a ./mocks/ import would not resolve)"
fi

# Never clobber a repo that ships its own test/mocks/<Name>.sol — the target project's copy is authoritative.
if grep -q '\[ -f "\$_mock_dst" \] || cp "\$_mock" "\$_mock_dst"' "$RUNNER"; then
  ok "staging never clobbers a repo's own test/mocks/<Name>.sol"
else
  bad "staging lost its no-clobber guard (a target project's own mock could be overwritten)"
fi

# ORDER: the staging must precede the prover launch, else the generated import would not resolve at compile time.
_stage_ln="$(grep -n 'mkdir -p "\$REPO_IN_RUN/test/mocks"' "$RUNNER" | head -1 | cut -d: -f1)"
_go_ln="$(grep -n 'go invariant-prover\.ag' "$RUNNER" | head -1 | cut -d: -f1)"
if [ -n "$_stage_ln" ] && [ -n "$_go_ln" ] && [ "$_stage_ln" -lt "$_go_ln" ]; then
  ok "staging happens BEFORE the prover is launched (line $_stage_ln < $_go_ln)"
else
  bad "staging no longer precedes the prover launch (the generated ./mocks/ import would not resolve)"
fi

# ----------------------------------------------------------------------------------------------------------
# 2b) BEHAVIOURAL — run the runner's OWN staging block against a fixture Foundry project and prove it is INERT:
#     it creates only `test/mocks/`, preserves a repo-owned mock of the same name, and leaves foundry.toml, the
#     src/ tree and existing tests byte-identical. Pure shell over the extracted block (no agentis, no forge).
# ----------------------------------------------------------------------------------------------------------
note "behaviourally checking that #1794 staging is INERT for everything but test/mocks/ ..."

_block="$(awk '/^if \[ -d "\$HARNESS_MOCKS_SRC" \]; then$/,/^fi$/' "$RUNNER")"
if [ -z "$_block" ]; then
  bad "could not extract the staging block from the runner (its shape changed)"
else
  _fix="$(mktemp -d)"
  mkdir -p "$_fix/repo/src" "$_fix/repo/test/mocks"
  printf '[profile.default]\nsrc = "src"\n' > "$_fix/repo/foundry.toml"
  printf '// SPDX-License-Identifier: MIT\ncontract Target {}\n' > "$_fix/repo/src/Target.sol"
  printf '// SPDX-License-Identifier: MIT\ncontract Existing {}\n' > "$_fix/repo/test/Existing.t.sol"
  printf 'REPO-OWNED MockERC20\n' > "$_fix/repo/test/mocks/MockERC20.sol"
  # Fingerprint everything that is NOT a file this staging step may create.
  _before="$(find "$_fix/repo" -type f ! -path "*/test/mocks/*" -exec sha256sum {} + | sort)"

  # Execute the runner's OWN block with the two variables it reads.
  HARNESS_MOCKS_SRC="$MOCKS" REPO_IN_RUN="$_fix/repo" bash -c '
    set -eu
    HARNESS_MOCKS_SRC="$HARNESS_MOCKS_SRC"
    REPO_IN_RUN="$REPO_IN_RUN"
    '"$_block"'
  '
  _rc=$?

  _after="$(find "$_fix/repo" -type f ! -path "*/test/mocks/*" -exec sha256sum {} + | sort)"

  if [ "$_rc" -eq 0 ]; then
    ok "the staging block runs cleanly against a fixture Foundry project"
  else
    bad "the staging block exited $_rc against a fixture Foundry project"
  fi

  if [ "$_before" = "$_after" ]; then
    ok "staging left foundry.toml, src/ and existing tests byte-identical (inert when unused)"
  else
    bad "staging modified files outside test/mocks/ (it is no longer inert)"
  fi

  if [ "$(cat "$_fix/repo/test/mocks/MockERC20.sol")" = "REPO-OWNED MockERC20" ]; then
    ok "staging preserved the repo's OWN test/mocks/MockERC20.sol"
  else
    bad "staging clobbered the repo's own test/mocks/MockERC20.sol"
  fi

  _missing=""
  for m in $MOCK_FILES; do
    [ "$m" = "MockERC20.sol" ] && continue   # the repo-owned one, asserted above
    [ -f "$_fix/repo/test/mocks/$m" ] || _missing="$_missing $m"
  done
  if [ -z "$_missing" ]; then
    ok "staging placed every non-conflicting mock into test/mocks/"
  else
    bad "staging did not place:$_missing"
  fi

  rm -rf "$_fix"
fi

# ----------------------------------------------------------------------------------------------------------
# 3) PROVER DIRECTIVE — the generation prompt points at the staged library with the EXACT import paths, and it
#    is folded into sharedScaffold so every compile-repair round re-injects it (not just the first attempt).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1794 prover reuse directive ..."

if grep -q '^let stagedMockLibrary =' "$PROVER"; then
  ok "stagedMockLibrary is defined on the prover"
else
  bad "stagedMockLibrary is missing from the prover (the model would keep hand-authoring mocks)"
fi

if grep -q '^  + stagedMockLibrary$' "$PROVER"; then
  ok "sharedScaffold folds in stagedMockLibrary (re-injected on EVERY compile-repair round)"
else
  bad "sharedScaffold does not fold in stagedMockLibrary (the directive would be inert)"
fi

_missing_path=""
for m in $MOCK_FILES; do
  grep -q "./mocks/$m" "$PROVER" || _missing_path="$_missing_path $m"
done
if [ -z "$_missing_path" ]; then
  ok "the directive names the exact ./mocks/<Name>.sol import path of every staged mock"
else
  bad "the directive omits the import path for:$_missing_path"
fi

# The directive must keep bespoke authoring available for shapes the library does not cover.
if grep -q 'Author a bespoke mock ONLY for a dependency shape the library does not cover' "$PROVER"; then
  ok "the directive still allows a bespoke mock for an uncovered dependency shape"
else
  bad "the directive lost the bespoke-mock escape hatch for uncovered shapes"
fi

# It must NOT relax the #1720 MOCK-DEP FIDELITY rule it follows — decimals/units still come from the target.
if grep -q 'MOCK-DEP FIDELITY (false-positive guard)' "$PROVER" \
   && grep -q 'construct each with the decimals/units the TARGET' "$PROVER"; then
  ok "the MOCK-DEP FIDELITY rule survives and the directive defers to it for decimals/units"
else
  bad "the MOCK-DEP FIDELITY rule was weakened by the staged-library directive"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) CONTRACTS UNTOUCHED — #1794 is prompt + staging only. The fuzzer stays the sole verdict, the #1471
#    target-linkage gate is intact, and the #1725 handler-action normalizer count is still exactly 2 (i.e. the
#    class routing / ensemble wiring was not disturbed).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1794 left the verdict/routing contracts intact ..."

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the INVARIANT|<target>|<verdict> marker emission is unchanged (fuzzer stays the sole verdict)"
else
  bad "the INVARIANT| marker emission changed unexpectedly"
fi

if grep -q 'fn verdict_of(rc: int) -> string {' "$PROVER"; then
  ok "verdict_of(rc) is unchanged (the fuzzer exit code is still the sole verdict source)"
else
  bad "verdict_of() changed unexpectedly"
fi

if grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 --require-import/--require-contract target-linkage gate strings are intact"
else
  bad "the #1471 target-linkage gate strings changed unexpectedly"
fi

if [ "$(grep -c 'let k = class_to_keyword(to_lower(klass));' "$PROVER")" -eq 2 ]; then
  ok "the #1725 handler-action normalizer count is still exactly 2 (#1794 did not touch class routing)"
else
  bad "the #1725 handler-action normalizer count changed (#1794 collided with the class-routing wiring)"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1794 shared harness-mock library is wired — the four dependency mocks exist, are dependency-free"
  note "      / wide-pragma / uniquely-named / test-discovery-inert, run-invariant-hunt.sh stages them into the"
  note "      harness project's test/mocks/ BEFORE the prover runs (proven inert against a fixture repo: only"
  note "      test/mocks/ is written, a repo-owned mock is preserved), the prover directive names every exact"
  note "      ./mocks/<Name>.sol import path and is re-injected on every repair round, and the INVARIANT| marker,"
  note "      verdict_of, the #1471 linkage gate and the #1725 normalizer count are untouched."
  exit 0
fi
note "DEMO FAILED — a #1794 harness-mock-library assertion did not hold" >&2
exit 1
