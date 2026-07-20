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

FAILS=0
note() { echo "demo-invariant-core-dep.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

[ -f "$PROVER" ] || { note "prover not found: $PROVER" >&2; exit 3; }
[ -f "$RUNNER" ] || { note "runner not found: $RUNNER" >&2; exit 3; }
[ -f "$ZONE" ]   || { note "zone-hunt not found: $ZONE" >&2; exit 3; }

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

if grep -q "grep -qE 'TokenizedStrategy|BaseStrategy'" "$RUNNER"; then
  ok "the yearn-v3 signal grep (TokenizedStrategy|BaseStrategy) gates the thread"
else
  bad "the yearn-v3 signal grep is missing"
fi

if grep -q 'lib/tokenized-strategy/src/TokenizedStrategy.sol' "$RUNNER" \
   && grep -q 'find "\$REPO_IN_RUN"/lib -name TokenizedStrategy.sol -print -quit' "$RUNNER"; then
  ok "the singleton is located in REPO_IN_RUN (primary path + find -print -quit fallback)"
else
  bad "the singleton lib-locate (primary + find fallback) is missing"
fi

if grep -q 'INV_CORE_DEP="\$_ts_in_run:TokenizedStrategy:0xD377919FA87120584B21279a491F82D5265A139c"' "$RUNNER"; then
  ok "INV_CORE_DEP is threaded as <path>:TokenizedStrategy:0xD377...9c"
else
  bad "the INV_CORE_DEP <path>:Name:addr thread is missing / malformed"
fi

if grep -q 'INV_CORE_DEP="\$INV_CORE_DEP" \\' "$RUNNER"; then
  ok "INV_CORE_DEP is passed into the agentis go env block"
else
  bad "INV_CORE_DEP is not passed into the agentis go env block"
fi

if grep -q 'exec.env_passthrough = TARGET_FN,TARGET_CLASS,INV_REPO,INV_OUT,INV_MATCH,HANDLER_FIXTURE,CODE_PATH,INV_RUNS,INV_DEPTH,INV_SEED,FORGE_INVARIANT,FORK_URL,FORK_BLOCK,FORK_TARGET,FORK_CONTEXT,INV_REPAIR_ROUNDS,INV_AUX,INV_AUDIT_CONTEXT,MUTANT_KILL,INV_CORPUS,INV_CORE_DEP' "$RUNNER"; then
  ok "INV_CORE_DEP is on the exec.env_passthrough allowlist (else getenv() reads the sanitized env as \"\")"
else
  bad "INV_CORE_DEP is NOT on the exec.env_passthrough allowlist"
fi

# The skip log on a miss keeps the byte-identical contract observable in the run log.
if grep -q 'skipping (byte-identical)' "$RUNNER"; then
  ok "a signal/lib miss logs a [core-dep] skip note (byte-identical on the miss)"
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

if grep -q 'fn core_dep_seed(active: bool, name: string, rel: string, addr: string) -> string' "$PROVER"; then
  ok "core_dep_seed(active, name, rel, addr) is defined"
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

if grep -q 'core_dep_seed(vaultRoute, coreDepName, coreDepRel, coreDepAddr)' "$PROVER"; then
  ok "core_dep_seed(vaultRoute, ...) is woven into sharedScaffold (re-injects each #1073 repair round)"
else
  bad "core_dep_seed is not woven into sharedScaffold"
fi

# ----------------------------------------------------------------------------------------------------------
# 4) BYTE-IDENTICAL-WHEN-OFF — core_dep_seed early-returns "" when !active, so an off flag / non-yearn target /
#    empty INV_CORE_DEP leaves the generation prompt byte-identical.
# ----------------------------------------------------------------------------------------------------------
note "source-guarding the #1755 (M1) empty-INV_CORE_DEP -> \"\" byte-identical guard ..."

if grep -Pzoq 'fn core_dep_seed\(active: bool, name: string, rel: string, addr: string\) -> string \{\n    if !active \{ return ""; \}' "$PROVER"; then
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
  trap 'rm -rf "$WORK"' EXIT
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
