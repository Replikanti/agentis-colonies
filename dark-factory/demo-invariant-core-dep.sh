#!/usr/bin/env bash
# demo-invariant-core-dep.sh — proof of the #1755 (M1) CORE-DEPENDENCY harness-gen lever on the deep-hunt path.
#
# The money-tier bug on yearn-v3 targets (first-depositor / share-inflation) is unfuzzable when the harness etches
# a zero-returning stub at the ERC4626 delegatecall singleton (BaseStrategy -> TokenizedStrategy @ 0xD377...9c):
# every deposit/mint/withdraw/redeem is then a no-op. #1755 M1 adds a default-off `--core-dep-harness` flag that,
# for a yearn-v3 target, threads the REAL TokenizedStrategy singleton (path:Name:addr, INV_CORE_DEP) into the
# prover, which generates a harness that DEPLOYS the real singleton and `vm.etch`es it at the constant address so
# the share path is genuinely fuzzed. Off / non-yearn target => INV_CORE_DEP="" => vaultRoute false => the prompt
# and the runner arg-construction are byte-identical to today.
#
# This is a SOURCE-GUARD demo (CI-safe, no agentis, no LLM, no network): it asserts the runner flag + INV_CORE_DEP
# thread + exec.env_passthrough membership + the yearn-v3 grep + lib-locate; the run-zone-hunt.sh DEEP_FWD
# pass-through; the prover getenv + contains_yearn_v3_signal + core_dep_seed carrying `vm.etch` and the 0xD377...9c
# address; the empty-INV_CORE_DEP -> "" byte-identical guard; and the verdict/marker/#1471 gate unchanged. When
# forge IS present it ALSO runs a distilled, yearn-lib-FREE fixture (a minimal ERC4626 share ledger behind a
# singleton-delegatecall) through the SAME etch recipe to prove real share accounting: non-zero shares minted,
# totalSupply moves, per-strategy storage lands at the strategy address, and the singleton's immutable FACTORY
# survives `vm.etch` — the M1.0 spike's KEY-RISK resolution, pinned offline.
#
# Usage:  dark-factory/demo-invariant-core-dep.sh
# Exit: 0 = all assertions hold (live etch check SKIPs cleanly when forge is absent) ; non-zero = a regression.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVER="$HERE/auditor/agents/invariant-prover.ag"
RUNNER="$HERE/run-invariant-hunt.sh"
ZONE="$HERE/run-zone-hunt.sh"
DETECT="$HERE/detect-core-dep.sh"

FAILS=0
note() { echo "demo-invariant-core-dep.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }
[ -f "$ZONE" ]   || { note "zone-hunt not found: $ZONE" >&2; exit 3; }
[ -f "$DETECT" ] || { note "detector not found: $DETECT" >&2; exit 3; }

# ----------------------------------------------------------------------------------------------------------
# 1) RUNNER WIRING — the default-off flag, the yearn-v3 detection + lib-locate, the INV_CORE_DEP thread, and the
#    exec.env_passthrough membership. The flag is a boolean (`shift`, not `shift 2`), mirroring --replay-corpus.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M1) run-invariant-hunt.sh wiring ..."

if grep -q 'CORE_DEP_HARNESS="" ' "$RUNNER"; then
  ok "CORE_DEP_HARNESS defaults to \"\" (flag OFF => byte-identical)"
else
  bad "CORE_DEP_HARNESS default-empty declaration missing"
fi

if grep -q -- '--core-dep-harness) CORE_DEP_HARNESS=1; shift ;;' "$RUNNER"; then
  ok "--core-dep-harness is a boolean flag (shift, not shift 2 — mirrors --replay-corpus)"
else
  bad "--core-dep-harness boolean arg case missing / not a bare shift"
fi

# #1763 G1 — the runner no longer inlines the yearn-only grep+locate; it DELEGATES to detect-core-dep.sh (the
# general, no-LLM detector) and splits its `<path>:<Name>:<addr>|<featureset>` output at `|` into INV_CORE_DEP
# (schema UNCHANGED) and the NEW INV_CORE_FEATURES. The detector-internal detection is source-guarded in section 3.
if grep -q '"\$HERE/detect-core-dep.sh" "\$CODE" "\$REPO_IN_RUN"' "$RUNNER"; then
  ok "the runner calls detect-core-dep.sh over the target source + the staged repo copy (no inline grep+locate)"
else
  bad "the runner does not delegate to detect-core-dep.sh"
fi

if grep -q 'INV_CORE_DEP="\${_det%%|\*}"' "$RUNNER" \
   && grep -q 'INV_CORE_FEATURES="\${_det##\*|}"' "$RUNNER"; then
  ok "the detector output is split at | into INV_CORE_DEP (<path>:Name:addr, schema UNCHANGED) and INV_CORE_FEATURES"
else
  bad "the detector-output split into INV_CORE_DEP / INV_CORE_FEATURES is missing / malformed"
fi

if grep -q 'INV_CORE_DEP="\$INV_CORE_DEP" \\' "$RUNNER"; then
  ok "INV_CORE_DEP is passed into the agentis go env block"
else
  bad "INV_CORE_DEP is not passed into the agentis go env block"
fi

if grep -q 'INV_CORE_FEATURES="\$INV_CORE_FEATURES" \\' "$RUNNER"; then
  ok "INV_CORE_FEATURES is passed into the agentis go env block beside INV_CORE_DEP"
else
  bad "INV_CORE_FEATURES is not passed into the agentis go env block"
fi

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT,MUTANT_KILL,INV_CORPUS,INV_CORE_DEP,INV_CORE_FEATURES' "$RUNNER"; then
  ok "INV_CORE_DEP + INV_CORE_FEATURES are on the exec.env_passthrough allowlist (else getenv() reads the sanitized env as \"\")"
else
  bad "INV_CORE_DEP / INV_CORE_FEATURES are NOT both on the exec.env_passthrough allowlist"
fi

# The skip log on a detector miss keeps the byte-identical contract observable in the run log.
if grep -q 'skipping (byte-identical)' "$RUNNER"; then
  ok "a detector miss logs a [core-dep] skip note (byte-identical on the miss)"
else
  bad "the [core-dep] skip-note on a miss is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 2) ZONE-HUNT PASS-THROUGH — run-zone-hunt.sh forwards --core-dep-harness verbatim into DEEP_FWD (both $INVHUNT
#    invocations); absent => DEEP_FWD unchanged => byte-identical.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M1) run-zone-hunt.sh pass-through ..."

if grep -q -- '--core-dep-harness) DEEP_FWD+=(--core-dep-harness); shift ;;' "$ZONE"; then
  ok "run-zone-hunt.sh forwards --core-dep-harness verbatim into DEEP_FWD"
else
  bad "run-zone-hunt.sh DEEP_FWD pass-through for --core-dep-harness is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 2b) #1763 G1 — the GENERAL detector detect-core-dep.sh. SOURCE-guard the branches (yearn registry entry,
#     EIP-1967 impl-slot literal, fallback/diamond, generic constant delegatecall, the no-guess safety), then
#     RUN it over A/B/C/D fixtures. HIGHEST-RISK is OVER-FIRE, so the load-bearing assertions are: the yearn
#     case resolves to the EXACT <path>:TokenizedStrategy:0xD377...9c|dcs, and every UNRESOLVABLE shape yields
#     EMPTY (no guessed address).
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1763 G1 detect-core-dep.sh general detector ..."

if grep -q '0xD377919FA87120584B21279a491F82D5265A139c' "$DETECT" \
   && grep -q 'lib/tokenized-strategy/src/TokenizedStrategy.sol' "$DETECT" \
   && grep -q 'find "\$ROOT"/lib -name TokenizedStrategy.sol -print -quit' "$DETECT"; then
  ok "(A) detector holds the yearn registry entry (TokenizedStrategy locate + 0xD377...9c, primary path + find fallback)"
else
  bad "the detector's yearn registry entry (TokenizedStrategy locate + 0xD377...9c) is missing"
fi

if grep -q '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc' "$DETECT"; then
  ok "(B) detector recognizes the EIP-1967 implementation-slot literal (reused from run-live-watch.sh's IMPL_SLOT)"
else
  bad "the detector does not recognize the EIP-1967 impl-slot literal"
fi

if grep -q 'fallback' "$DETECT" && grep -qE 'facet|diamond|selector' "$DETECT"; then
  ok "(C) detector recognizes the diamond/facets fallback-dispatch shape"
else
  bad "the detector does not recognize the diamond/facets shape"
fi

if grep -q 'delegatecall' "$DETECT" && grep -q 'generic-delegatecall' "$DETECT"; then
  ok "(D) detector recognizes the generic constant-address delegatecall shape"
else
  bad "the detector does not recognize the generic delegatecall shape"
fi

if grep -q 'no guessed address' "$DETECT" && grep -q 'no guess' "$DETECT"; then
  ok "the detector documents the OVER-FIRE mitigation (EMPTY on any unresolvable shape — never a guessed address)"
else
  bad "the detector does not carry the no-guessed-address safety note"
fi

# --- RUNTIME: run the detector over distilled A/B/C/D fixtures (mechanical, no LLM/forge/network). ---
note "running detect-core-dep.sh over distilled A/B/C/D fixtures ..."

DWORK="$(mktemp -d)"
trap 'rm -rf "$DWORK"' EXIT
mkdir -p "$DWORK/repo/lib/tokenized-strategy/src"
printf 'contract TokenizedStrategy {}\n' > "$DWORK/repo/lib/tokenized-strategy/src/TokenizedStrategy.sol"

# (A) yearn BaseStrategy target — resolves to the EXACT singleton line.
printf 'import "x"; contract Strat is BaseStrategy {}\n' > "$DWORK/yearn.sol"
# (B) EIP-1967 proxy — impl slot literal, impl address only at runtime (unresolvable) => EMPTY.
printf 'contract P { fallback() external { assembly { let i := sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc) let r := delegatecall(gas(), i, 0, 0, 0, 0) } } }\n' > "$DWORK/eip1967.sol"
# (C) diamond/facets — per-selector facet dispatch, no single singleton addr => EMPTY.
printf 'contract Diamond { mapping(bytes4=>address) facet; fallback() external { address f = facet[msg.sig]; assembly { let r := delegatecall(gas(), f, 0, 0, 0, 0) } } }\n' > "$DWORK/diamond.sol"
# (D) generic constant delegatecall to an UNKNOWN external address => EMPTY (no registry match, no guess).
printf 'contract G { address constant IMPL = 0x1111111111111111111111111111111111111111; function f() external { IMPL.delegatecall(msg.data); } }\n' > "$DWORK/generic.sol"
# (D-known) generic constant delegatecall to the KNOWN registry address (no yearn NAME signal) => resolves via
# the address registry, proving the general (non-yearn-named) path also resolves when the singleton is known.
printf 'contract G2 { address constant S = 0xD377919FA87120584B21279a491F82D5265A139c; function f() external { S.delegatecall(msg.data); } }\n' > "$DWORK/generic-known.sol"
# unrelated ERC20 — no delegatecall-singleton shape at all => EMPTY.
printf 'contract T { function transfer(address,uint256) external {} }\n' > "$DWORK/erc20.sol"

D_YEARN_EXPECT="$DWORK/repo/lib/tokenized-strategy/src/TokenizedStrategy.sol:TokenizedStrategy:0xD377919FA87120584B21279a491F82D5265A139c|dcs"

d_out() { sh "$DETECT" "$1" "$DWORK/repo" 2>/dev/null; }

if [ "$(d_out "$DWORK/yearn.sol")" = "$D_YEARN_EXPECT" ]; then
  ok "(A) yearn target resolves to EXACTLY <path>:TokenizedStrategy:0xD377...9c|dcs (featureset carries dcs)"
else
  bad "(A) yearn target did NOT resolve to the exact singleton line (got: '$(d_out "$DWORK/yearn.sol")')"
fi

if [ "$(d_out "$DWORK/generic-known.sol")" = "$D_YEARN_EXPECT" ]; then
  ok "(D) a generic constant-delegatecall to the KNOWN registry address resolves via the address registry (general, non-yearn-named path)"
else
  bad "(D) the registry-by-address general resolution did NOT fire (got: '$(d_out "$DWORK/generic-known.sol")')"
fi

for _f in eip1967 diamond generic erc20; do
  _o="$(d_out "$DWORK/$_f.sol")"
  if [ -z "$_o" ]; then
    ok "($_f) an unresolvable/ambiguous target yields EMPTY (no guessed address — the OVER-FIRE mitigation)"
  else
    bad "($_f) OVER-FIRE: an unresolvable target emitted a line ('$_o') instead of EMPTY"
  fi
done

# ----------------------------------------------------------------------------------------------------------
# 3) PROVER WIRING — INV_CORE_DEP getenv, the yearn-v3 signal classifier, the field splitter, vaultRoute gating,
#    and core_dep_seed carrying the etch directive (import the real singleton, `vm.etch` at 0xD377...9c, deploy
#    the target through the REAL share path, do NOT stub the singleton), woven into sharedScaffold on vaultRoute.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M1) invariant-prover.ag wiring ..."

if grep -q 'let coreDep = getenv("INV_CORE_DEP");' "$PROVER"; then
  ok "the prover reads INV_CORE_DEP via getenv"
else
  bad "the prover does not read INV_CORE_DEP"
fi

if grep -q 'fn contains_yearn_v3_signal(src: string) -> bool' "$PROVER" \
   && grep -q 'index_of(src, "TokenizedStrategy")' "$PROVER" \
   && grep -q 'index_of(src, "BaseStrategy")' "$PROVER"; then
  ok "contains_yearn_v3_signal() is a flat nested-if index_of on TokenizedStrategy/BaseStrategy (no || — single-assignment .ag)"
else
  bad "contains_yearn_v3_signal() flat-index_of classifier is missing"
fi

# #1763 G1 — the GENERAL core-dependency signal classifier. It MUST keep contains_yearn_v3_signal() as ONE
# explicit branch (yearn stays a named special case) and cover the general signals (delegatecall + the EIP-1967
# impl-slot literal). This is the signal SIDE of the vault_route AND-gate.
if grep -q 'fn contains_core_dep_signal(src: string) -> bool' "$PROVER" \
   && grep -q 'if contains_yearn_v3_signal(src) { return true; }' "$PROVER" \
   && grep -q 'index_of(src, "delegatecall")' "$PROVER" \
   && grep -q 'index_of(src, "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc")' "$PROVER"; then
  ok "contains_core_dep_signal() calls contains_yearn_v3_signal() as one explicit branch + covers delegatecall + the EIP-1967 slot"
else
  bad "contains_core_dep_signal() (general signal calling contains_yearn_v3_signal + delegatecall/EIP-1967) is missing"
fi

if grep -q 'return contains_core_dep_signal(src);' "$PROVER"; then
  ok "vault_route() gates on contains_core_dep_signal(src) (generalized from the yearn-only signal)"
else
  bad "vault_route() does not gate on contains_core_dep_signal(src)"
fi

if grep -q 'fn core_dep_field(entry: string, n: int) -> string' "$PROVER"; then
  ok "core_dep_field() splits <path>:<Name>:<addr> (the aux_field :-split idiom, applied twice)"
else
  bad "core_dep_field() splitter is missing"
fi

if grep -q 'let vaultRoute = vault_route(coreDep, code);' "$PROVER"; then
  ok "vaultRoute = len(coreDep)>0 AND contains_yearn_v3_signal(code) (nested-if conjunction)"
else
  bad "the vaultRoute gate is missing"
fi

if grep -q 'fn core_dep_seed(active: bool, name: string, rel: string, addr: string, targetName: string, targetRel: string) -> string' "$PROVER"; then
  ok "core_dep_seed(active, name, rel, addr, targetName, targetRel) is defined"
else
  bad "core_dep_seed() is missing"
fi

if grep -q 'vm.etch(' "$PROVER" && grep -q '0xD377919FA87120584B21279a491F82D5265A139c' "$PROVER"; then
  ok "core_dep_seed carries the vm.etch directive and the 0xD377...9c singleton address"
else
  bad "core_dep_seed is missing the vm.etch directive or the 0xD377...9c address"
fi

if grep -q 'do NOT mock it, do NOT etch a zero-returning fallback stub' "$PROVER"; then
  ok "the directive forbids mocking / zero-stubbing the singleton (deploy the REAL one)"
else
  bad "the directive does not forbid stubbing the singleton"
fi

# #1755 M5 / #1765 — TARGET IMPORT-PATH PIN. Two autonomous runs proved harness-gen import-path variance is the
# remaining blocker: the catching run imported the target from its real in-repo `../src/<Target>.sol`, a second run
# imported the pipeline's flattened staged copy `target-code.sol` (one dir above the repo, not compilable inside it)
# and failed with `Source "target-code.sol" not found` => HARNESS_ERROR. core_dep_seed must PIN the target to its
# in-repo path and FORBID target-code.sol so the catching shape is the reliable output. #1765 corrected the hint the
# model actually receives: the directive's `targetRel` is now the in-repo `../` + TARGET_FN file part
# (`vaultTargetRel`), NOT `relImport` (= rel_import_path(invOut, CODE_PATH), which resolves to the WRONG staged
# flat-copy basename `../../target-code.sol`).
if grep -q 'IMPORT THE TARGET' "$PROVER" \
   && grep -q 'in-repo source path' "$PROVER" \
   && grep -q 'NEVER import the target from the flattened staged copy `target-code.sol`' "$PROVER"; then
  ok "the directive pins the target import to its in-repo ../src/ path and forbids the flattened target-code.sol"
else
  bad "the directive does not pin the target import path / does not forbid target-code.sol (harness-gen variance unfixed)"
fi

# #1765 — the directive's `targetRel` hint MUST be the REAL in-repo target path (`../` + TARGET_FN file part =
# `../src/<Target>.sol`, basename `<Target>.sol`), derived from TARGET_FN via the same file-part idiom as targetFile
# — NOT the M5 `relImport` (which resolves to the staged flat-copy basename `../../target-code.sol`). Guard the
# derivation helper, its "../" + targetFile body, and that the core_dep_seed CALL SITE now threads vaultTargetRel
# (not relImport) as the sixth (targetRel) argument.
if grep -q 'fn vault_target_rel(file: string) -> string' "$PROVER" \
   && grep -q 'return "../" + file;' "$PROVER" \
   && grep -q 'let vaultTargetRel = vault_target_rel(targetFile);' "$PROVER"; then
  ok "vault_target_rel(targetFile) = \"../\" + the TARGET_FN file part (the in-repo ../src/<Target>.sol import path)"
else
  bad "vault_target_rel (../ + targetFile, the in-repo target-import path derivation) is missing"
fi

if grep -q 'core_dep_seed(vaultRoute, coreDepName, coreDepRel, coreDepAddr, deployName, vaultTargetRel)' "$PROVER"; then
  ok "core_dep_seed threads vaultTargetRel (the in-repo ../src/ path) as targetRel — NOT relImport/target-code.sol"
elif grep -q 'core_dep_seed(vaultRoute, coreDepName, coreDepRel, coreDepAddr, deployName, relImport)' "$PROVER"; then
  bad "core_dep_seed still threads relImport (= ../../target-code.sol basename) as targetRel — the #1765 hint bug is unfixed"
else
  bad "the core_dep_seed call site does not thread vaultTargetRel as targetRel"
fi

# #1755 M3 — the profit-limit health-check gate: BaseHealthCheck.report() reverts with reason `healthCheck` when a
# donation is realized as an outsized profit, so the donation-realizing report() reverts, totalAssets never
# inflates, and the first-depositor bug is unreachable. The directive must instruct the Handler (which is the
# strategy's management, being the deployer) to also call setDoHealthCheck(false) in setUp.
if grep -q 'setDoHealthCheck(false)' "$PROVER" && grep -q 'revert reason `healthCheck`' "$PROVER"; then
  ok "the directive tells the Handler to disable the profit-limit health check (setDoHealthCheck(false), healthCheck revert gate) so report() succeeds and totalAssets inflates"
else
  bad "the directive does not disable the profit-limit health check (setDoHealthCheck(false) + healthCheck gate) — first-depositor report() reverts, bug unreachable"
fi

# #1755 M4 — the missing management precondition: setProfitMaxUnlockTime(0). Even after setDoHealthCheck(false) a
# profit realized through report() is LOCKED and unlocks linearly over profitMaxUnlockTime, so totalAssets never
# inflates for share pricing and the CLEAN verdict persists. With profitMaxUnlockTime==0 the donation lands in
# totalAssets instantly: seed 1 wei + donate 1 wei + report -> totalAssets=2, totalSupply=1 (2x share price).
if grep -q 'setProfitMaxUnlockTime(0)' "$PROVER" && grep -q 'profit-unlock window' "$PROVER"; then
  ok "the directive tells the Handler (as management) to call setProfitMaxUnlockTime(0) so the donation is recognized in totalAssets instantly (not locked over the profit-unlock window)"
else
  bad "the directive does not add setProfitMaxUnlockTime(0) — the donated profit stays locked, totalAssets never inflates, verdict stays CLEAN"
fi

if grep -q 'totalAssets == 2, totalSupply == 1' "$PROVER"; then
  ok "the directive names the share-inflation boundary (seed 1 wei + donate 1 wei + report -> totalAssets==2, totalSupply==1, 2x share price)"
else
  bad "the directive does not name the totalAssets==2/totalSupply==1 share-inflation boundary the attack exploits"
fi

# #1755 M4 — wei-scale attack actions: the rounding theft bites at the totalAssets=2/totalSupply=1 boundary (a
# victim depositing 3 wei redeems only 2, 33% robbed) and vanishes at large scale, so the handler MUST fuzz tiny
# amounts IN ADDITION to realistic 1e15..1e21 sizes.
if grep -q 'TINY WEI-SCALE amounts' "$PROVER" && grep -q -- '\[1, 1000\]' "$PROVER"; then
  ok "the directive requires TINY WEI-SCALE attack amounts (bounded like [1, 1000]) in addition to realistic sizes"
else
  bad "the directive does not require wei-scale attack amounts — the fuzzer never drives the tiny-value regime where the rounding theft is reachable"
fi

if grep -q 'a victim depositing 3 wei redeems only 2, 33% ' "$PROVER"; then
  ok "the directive states the proven wei-scale theft (victim deposits 3 wei -> redeems 2, 33% robbed)"
else
  bad "the directive does not state the proven wei-scale theft magnitude"
fi

if grep -q 'interface Vm { function etch(address, bytes calldata) external;' "$PROVER"; then
  ok "core_dep_seed injects the forge-std-free minimal Vm interface (etch/deal/prank)"
else
  bad "the forge-std-free Vm interface is missing from core_dep_seed"
fi

if grep -q '0x7109709ECfa91a80626fF3989D68f67F5b1DD12D' "$PROVER"; then
  ok "the Vm handle uses the canonical 0x7109...12D address (the fork_seed convention)"
else
  bad "the canonical Vm address 0x7109...12D is missing"
fi

if grep -q 'core_dep_seed(vaultRoute, coreDepName, coreDepRel, coreDepAddr, deployName, vaultTargetRel)' "$PROVER"; then
  ok "core_dep_seed(vaultRoute, ...) is woven into sharedScaffold (re-injects each #1073 repair round)"
else
  bad "core_dep_seed is not woven into sharedScaffold"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) BYTE-IDENTICAL-WHEN-OFF — core_dep_seed early-returns "" when !active, so an off flag / non-yearn target /
#    empty INV_CORE_DEP leaves the generation prompt byte-identical.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M1) empty-INV_CORE_DEP -> \"\" byte-identical guard ..."

if grep -Pzoq 'fn core_dep_seed\(active: bool, name: string, rel: string, addr: string, targetName: string, targetRel: string\) -> string \{\n    if !active \{ return ""; \}' "$PROVER"; then
  ok "core_dep_seed(!active) returns \"\" as its FIRST statement (byte-identical when off)"
else
  bad "core_dep_seed does not early-return \"\" on !active (byte-identical guard broken)"
fi

if grep -q 'fn vault_route(cd: string, src: string) -> bool' "$PROVER" \
   && grep -q 'if len(cd) == 0 { return false; }' "$PROVER"; then
  ok "vault_route returns false on empty coreDep (flag off / signal absent => byte-identical)"
else
  bad "vault_route empty-coreDep guard is missing"
fi

# ----------------------------------------------------------------------------------------------------------
# 5) VERDICT CONTRACT UNTOUCHED — the fuzzer stays the SOLE verdict. The INVARIANT| marker, verdict_of, and the
#    #1471 target-linkage gate are byte-present + unchanged. M1 only adds a setUp() deploy DIRECTIVE.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding that #1755 (M1) left the verdict/marker/linkage contract intact ..."

if grep -q 'print("INVARIANT|" + targetFn + "|" + verdict);' "$PROVER"; then
  ok "the INVARIANT|<target>|<verdict> marker emission is unchanged (fuzzer stays the sole verdict)"
else
  bad "the INVARIANT| marker emission changed unexpectedly"
fi

if grep -q 'fn verdict_of(rc: int) -> string' "$PROVER"; then
  ok "verdict_of(rc) — the fuzzer-exit-code verdict source — is intact"
else
  bad "verdict_of(rc) changed unexpectedly"
fi

if grep -q -- '--require-import' "$PROVER" && grep -q -- '--require-contract' "$PROVER"; then
  ok "the #1471 --require-import/--require-contract target-linkage gate strings are intact"
else
  bad "the #1471 target-linkage gate strings changed unexpectedly"
fi

# ----------------------------------------------------------------------------------------------------------
# 5b) #1755 M6 — #1471 LINK GATE reconciled with M5's target-import pin. M5 makes the CATCHING harness import the
#     target from its REAL in-repo `../src/<Target>.sol` (basename e.g. Strategy.sol), NOT the staged
#     `target-code.sol`. The #1471 gate basenames --require-import and greps the harness for THAT basename, so the
#     pipeline's `--require-import <CODE_PATH>` (= target-code.sol) rejected the catching harness as HARNESS_ERROR
#     before any fuzzing. M6 arms --require-import with the in-repo target file path (targetFile) ON vaultRoute ONLY;
#     the non-core-dep path keeps arming with codePath (byte-identical). The gate LOGIC in forge-invariant.sh and
#     the safety property (a harness importing NEITHER real path still HARNESS_ERRORs) are untouched.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M6) #1471-link-gate reconciliation with M5's import pin ..."

if grep -q 'fn target_file(label: string) -> string' "$PROVER" \
   && grep -q 'let targetFile = target_file(targetFn);' "$PROVER"; then
  ok "target_file(targetFn) extracts the target's in-repo file path (before the first :) — basename is the pinned import basename"
else
  bad "target_file() / targetFile derivation is missing"
fi

if grep -q 'fn vault_target_import(route: bool, file: string) -> string' "$PROVER" \
   && grep -Pzoq 'fn vault_target_import\(route: bool, file: string\) -> string \{\n    if !route \{ return ""; \}' "$PROVER"; then
  ok "vault_target_import(!route) returns \"\" — the in-repo import override is core-dep/vaultRoute-scoped (byte-identical off)"
else
  bad "vault_target_import is missing / not gated on route (returns non-empty when off)"
fi

if grep -q 'let vaultTargetImport = vault_target_import(vaultRoute, targetFile);' "$PROVER"; then
  ok "vaultTargetImport = the in-repo target path ONLY on vaultRoute (\"\" otherwise)"
else
  bad "vaultTargetImport wiring (gated on vaultRoute) is missing"
fi

if grep -q 'fn link_args(fUrl: string, fTarget: string, fContext: string, cPath: string, tName: string, vaultImport: string) -> string' "$PROVER"; then
  ok "link_args now takes vaultImport (the core-dep in-repo target path)"
else
  bad "link_args signature does not carry vaultImport"
fi

# On vaultRoute (vaultImport non-empty) the gate is armed with vaultImport, NOT codePath/target-code.sol.
if grep -Pzoq 'if len\(vaultImport\) > 0 \{\n        return " --require-import " \+ shell_escape\(vaultImport\) \+ opt_flag\("--require-contract", tName\);\n    \}' "$PROVER"; then
  ok "on vaultRoute, --require-import is armed with the in-repo target path (vaultImport), not target-code.sol"
else
  bad "link_args does not arm --require-import with vaultImport on the core-dep path"
fi

# NON-core-dep path (vaultImport == "") keeps the ORIGINAL codePath arming, byte-identical to today.
if grep -Pzoq 'if len\(vaultImport\) > 0 \{[^}]*\}\n    if len\(cPath\) == 0 \{ return ""; \}\n    return " --require-import " \+ shell_escape\(cPath\) \+ opt_flag\("--require-contract", tName\);' "$PROVER"; then
  ok "non-core-dep path (empty vaultImport) still arms --require-import with codePath — byte-identical to today"
else
  bad "the non-core-dep codePath arming (byte-identical fall-through) changed unexpectedly"
fi

if grep -q 'let linkArgs = link_args(forkUrl, forkTarget, forkContext, codePath, targetName, vaultTargetImport);' "$PROVER"; then
  ok "the link_args call threads vaultTargetImport"
else
  bad "the link_args call does not thread vaultTargetImport"
fi

# The #1471 matcher LOGIC in forge-invariant.sh (basename REQ_IMPORT + grep) must be untouched — M6 changes only
# WHAT PATH is passed, never HOW the gate matches.
FORGEINV="$HERE/evm-harness/forge-invariant.sh"
if [ -f "$FORGEINV" ]; then
  if grep -q '_tgt_base="\$(basename "\$REQ_IMPORT")"' "$FORGEINV" \
     && grep -q 'the test does not import the in-scope target' "$FORGEINV"; then
    ok "forge-invariant.sh #1471 matcher logic (basename REQ_IMPORT + import grep) is untouched"
  else
    bad "the #1471 matcher logic in forge-invariant.sh changed unexpectedly"
  fi
else
  skip "forge-invariant.sh not found at $FORGEINV — matcher-logic guard skipped"
fi

# ----------------------------------------------------------------------------------------------------------
# 6) LIVE ETCH RECIPE (forge present) — run the distilled, yearn-lib-FREE fixture through the SAME etch recipe:
#    deploy a minimal ERC4626-ish singleton, vm.etch it at the constant address, deploy a base-strategy that
#    delegatecalls it in its constructor + fallback, then deposit -> non-zero shares, totalSupply moves,
#    per-strategy storage at the strategy address, and the singleton's immutable FACTORY survives the etch.
# ----------------------------------------------------------------------------------------------------------
note "live etch-recipe check on the distilled (yearn-lib-free) fixture ..."

if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run the live etch-recipe check"
else
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK" "$DWORK"' EXIT
  mkdir -p "$WORK/src" "$WORK/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n' > "$WORK/foundry.toml"
  cat > "$WORK/test/CoreDep.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Distilled, yearn-lib-FREE repro of the #1755 core-dependency etch recipe: a minimal ERC4626-ish share ledger
// whose logic lives in a delegatecall SINGLETON at a constant address (the BaseStrategy/TokenizedStrategy shape).
// Proves vm.etch of the REAL singleton runtime code (a) preserves the singleton's immutable FACTORY and (b) routes
// per-strategy share storage to the STRATEGY address under delegatecall — so deposit mints real shares.
interface Vm { function etch(address, bytes calldata) external; }
interface IStrat {
    function deposit(uint256, address) external returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function factoryOf() external view returns (address);
}
contract MiniTS {
    bytes32 internal constant SLOT = 0x00c0ffee00000000000000000000000000000000000000000000000000000001;
    struct S { address asset; uint256 totalSupply; mapping(address => uint256) bal; }
    function _s() internal pure returns (S storage s) { bytes32 sl = SLOT; assembly { s.slot := sl } }
    address public immutable FACTORY;
    constructor(address f) { FACTORY = f; }
    function initialize(address asset) external { _s().asset = asset; }
    function deposit(uint256 assets, address to) external returns (uint256 shares) {
        S storage s = _s();
        shares = assets; // 1:1 mint — the point is REAL storage written under delegatecall, not the pricing math
        s.bal[to] += shares; s.totalSupply += shares;
    }
    function totalSupply() external view returns (uint256) { return _s().totalSupply; }
    function balanceOf(address a) external view returns (uint256) { return _s().bal[a]; }
    function factoryOf() external view returns (address) { return FACTORY; }
}
abstract contract MiniBase {
    address internal constant SINGLETON = 0xD377919FA87120584B21279a491F82D5265A139c;
    constructor(address asset) {
        (bool ok, ) = SINGLETON.delegatecall(abi.encodeWithSignature("initialize(address)", asset));
        require(ok, "init");
    }
    fallback() external {
        address s = SINGLETON;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), s, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r case 0 { revert(0, returndatasize()) } default { return(0, returndatasize()) }
        }
    }
}
contract MiniStrategy is MiniBase {
    constructor(address asset) MiniBase(asset) {}
}
abstract contract InvBase {
    address[] private _t;
    function targetContracts() public view returns (address[] memory) { return _t; }
    function _target(address a) internal { _t.push(a); }
}
contract CoreDepFixture is InvBase {
    Vm constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);
    address constant SINGLETON = 0xD377919FA87120584B21279a491F82D5265A139c;
    MiniStrategy strat;
    address factoryMock = address(0xF00D);
    function setUp() public {
        // THE ETCH RECIPE: construct the real singleton (bakes FACTORY into runtime code), etch it, THEN deploy.
        MiniTS ts = new MiniTS(factoryMock);
        vm.etch(SINGLETON, address(ts).code);
        strat = new MiniStrategy(address(0xA55E7)); // constructor delegatecalls initialize on the etched code
        _target(address(strat));
    }
    function test_realSharesThroughEtchedSingleton() public {
        require(IStrat(address(strat)).totalSupply() == 0, "fresh supply");
        uint256 shares = IStrat(address(strat)).deposit(100, address(0xBEEF));
        require(shares == 100, "non-zero shares minted");
        require(IStrat(address(strat)).totalSupply() == 100, "totalSupply moved");
        require(IStrat(address(strat)).balanceOf(address(0xBEEF)) == 100, "per-strategy storage at strategy addr");
        // KEY RISK: the singleton's immutable FACTORY (baked into runtime code) survives vm.etch + delegatecall.
        require(IStrat(address(strat)).factoryOf() == factoryMock, "immutable FACTORY preserved through etch");
    }
}
SOL
  if ( cd "$WORK" && FOUNDRY_OFFLINE=true forge test --match-path test/CoreDep.t.sol ) >"$WORK/forge.out" 2>&1; then
    ok "the distilled fixture PASSES the etch recipe (real shares, totalSupply moves, storage at strategy, FACTORY survives etch)"
  else
    bad "the distilled etch-recipe fixture FAILED under forge:"
    sed 's/^/        /' "$WORK/forge.out" >&2
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: #1755 (M1) core-dependency harness-gen is wired — run-invariant-hunt.sh gains the default-off"
  note "      --core-dep-harness flag that detects the yearn-v3 signal, locates the real TokenizedStrategy in the"
  note "      staged repo, and threads INV_CORE_DEP (allowlisted); run-zone-hunt.sh forwards it; the prover reads"
  note "      it and, on vaultRoute, injects the vm.etch directive at 0xD377...9c into sharedScaffold. Off / a"
  note "      non-yearn target => \"\" => byte-identical; the INVARIANT| marker + verdict_of + #1471 gate are"
  note "      untouched; and the distilled fixture proves the etch recipe yields real share accounting."
  exit 0
fi
note "DEMO FAILED — a #1755 (M1) core-dependency harness-gen assertion did not hold" >&2
exit 1
