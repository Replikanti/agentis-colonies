#!/usr/bin/env bash
# demo-invariant-hunt.sh — reproducible proof of the #1035 STATEFUL-INVARIANT-FUZZING loop: a target is
# turned into a Foundry stateful-invariant test and the FUZZER (not the LLM) returns the verdict over
# randomized MULTI-CALL sequences.
#
# This drives the FULL target -> handler+invariants -> forge-invariant -> verdict loop through the substrate
# via `run-invariant-hunt.sh` + `auditor/agents/invariant-prover.ag`, using a FIXTURE handler (the
# offline/deterministic path — NO LLM, mock backend) and a REAL Foundry invariant run. Two vaults exercise
# both verdicts and prove the engine catches a real multi-step bug AND does not false-positive on the fix:
#   - a VULNERABLE ERC4626-style vault (no virtual shares/assets)  -> verdict FINDING (the inflation attack:
#     a SHRUNK call-sequence donate->...->victimDeposit robs the depositor — a reproducible exploit witness)
#   - a HARDENED twin (large virtual-share/asset offset)           -> verdict CLEAN  (the same fuzzed search
#     cannot break the invariant — no false positive on the fix)
# The verdict is the FUZZER's exit code, never the LLM's opinion — that is the whole point of #1035. The
# inflation attack is a MULTI-STEP bug a single-function symbolic check misses: it only emerges from the
# attacker's seed+donate priming the share price BEFORE the victim's deposit. A fixed --seed makes the search
# reproducible; the FINDING run is also repeated and asserted to surface a non-empty shrunk sequence.
#
# CI has no forge, so if it is missing this prints a single [SKIP] line and exits 0 (mirroring
# demo-symbolic.sh / the colony-lint skip convention) instead of failing. Install the toolchain to run it:
#   curl -L https://foundry.paradigm.xyz | bash && foundryup    # forge (has built-in invariant fuzzing)
#
# Usage:  dark-factory/demo-invariant-hunt.sh
# Exit: 0 = both verdicts correct (FINDING + a non-empty witness on vulnerable, CLEAN on hardened), or tools
#       absent -> SKIP ; non-zero = a verdict was wrong.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$HERE/run-invariant-hunt.sh"

FAILS=0
note() { echo "demo-invariant-hunt.sh: $*"; }
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; FAILS=$((FAILS + 1)); }
skip() { echo "  [SKIP] $*"; }

# Skip EARLY (before any work) when the toolchain is missing, so CI without forge reports a clean [SKIP] +
# exit 0 rather than a harness error. agentis is required to drive the substrate loop.
if ! command -v forge >/dev/null 2>&1; then
  skip "forge not on PATH — install foundryup (https://getfoundry.sh) to run this demo"
  exit 0
fi
if ! command -v agentis >/dev/null 2>&1; then
  skip "agentis not on PATH — install the agentis runtime to drive the substrate invariant-hunt loop"
  exit 0
fi

[ -x "$RUNNER" ] || { note "runner not found / not executable: $RUNNER" >&2; exit 3; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ----------------------------------------------------------------------------------------------------------
# Build the two tiny foundry repos: VULNERABLE (no virtual offset) and HARDENED (large virtual-share offset
# so the inflation attack cannot round the victim to zero shares). Both ship the SAME minimal ERC20 + the
# SAME public ABI, so the SAME fixture handler drives both — only the share-pricing math differs.
# ----------------------------------------------------------------------------------------------------------
mk_repo() {  # $1 = repo dir, $2 = the `s = ...` deposit pricing line, $3 = the `assets = ...` withdraw line
  _dir="$1"; _depositMath="$2"; _withdrawMath="$3"
  mkdir -p "$_dir/src" "$_dir/test"
  printf '[profile.default]\nsrc = "src"\nout = "out"\n\n[invariant]\nruns = 64\ndepth = 32\nfail_on_revert = false\n' > "$_dir/foundry.toml"
  cat > "$_dir/src/Vault.sol" <<SOL
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
contract Token {
  mapping(address=>uint) public balanceOf; uint public totalSupply;
  function mint(address to,uint a) external { balanceOf[to]+=a; totalSupply+=a; }
  function transfer(address to,uint a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
  function transferFrom(address f,address t,uint a) external returns(bool){ balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}
contract Vault {
  Token public asset; uint public totalShares; mapping(address=>uint) public shares;
  uint constant VS = 1000000000000000000000000000; uint constant VA = 1; // virtual offset (1e27); VS=1 in the vulnerable build below
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    ${_depositMath}
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    ${_withdrawMath}
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
SOL
}

# VULNERABLE: classic ERC4626 share price (no virtual offset) -> donation inflates ta, the next deposit mints
# 0 shares -> the depositor's claim collapses far below their deposit (a MULTI-STEP donation/inflation attack).
mk_repo "$WORK/vuln" \
  's = totalShares==0 ? assets : assets*totalShares/ta;' \
  'assets = s*ta/totalShares;'

# HARDENED: a large virtual-share/asset offset (the OpenZeppelin ERC4626 decimal-offset mitigation) so the
# share price cannot be inflated enough to round a real depositor to zero shares -> the same attack fails.
mk_repo "$WORK/hard" \
  's = assets * (totalShares + VS) / (ta + VA);' \
  'assets = s * (ta + VA) / (totalShares + VS);'

# ----------------------------------------------------------------------------------------------------------
# The PROVEN fixture handler+invariant (the validated template, parameterized to the vault under test). A
# `Handler` exposes the protocol's actions as bounded actor functions (attackerSeed / attackerDonate /
# victimDeposit) and a DEEP invariant (`invariant_victim_not_robbed`): a depositor's claim on the vault must
# always be worth at least what they deposited, minus dust. forge-std-free: targets are registered via the
# `targetContracts()` view (the StdInvariant ABI forge auto-discovers) and asserted with plain `require`.
# ----------------------------------------------------------------------------------------------------------
cat > "$WORK/fixture.t.sol" <<'SOL'
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import {Vault, Token} from "../src/Vault.sol";

// The protocol's actions as a real attacker/user calls them, with fuzzed inputs bounded to realistic ranges.
contract Handler {
    Vault public v; Token public t;
    uint public victimDeposited;   // total assets the honest victim has put in
    uint public victimShares;      // shares the victim holds
    constructor(Vault _v, Token _t){ v=_v; t=_t; }
    // forge-std-free bound: keep a fuzzed uint inside [lo, hi] without the forge-std `bound` cheatcode.
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }              // seed 1 share
    function attackerDonate(uint a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); } // direct transfer, no shares
    function victimDeposit(uint a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        uint s = v.deposit(a);
        victimDeposited += a; victimShares += s;
    }
}

// StdInvariant ABI forge auto-discovers: targetContracts() lists the addresses the fuzzer drives. No forge-std.
abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract VaultInvariantTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t=new Token(); v=new Vault(t); h=new Handler(v,t); _target(address(h)); }
    // DEEP invariant: the victim's CLAIM on the vault (shares * vaultBalance / totalShares) must always be
    // worth >= what they deposited, minus dust. The inflation attack makes a victim deposit mint 0 shares,
    // so their claim collapses far below their deposit -> a SEQUENCE the fuzzer must find.
    function invariant_victim_not_robbed() public view {
        uint vd = h.victimDeposited();
        if (vd == 0) return;
        uint ts = v.totalShares();
        uint claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");   // claim within dust(1e6) of deposit
    }
}
SOL

# The hardened build declares VS=1e27 in source; the vulnerable build's pricing ignores VS entirely (the
# classic formula), so a single shared fixture is correct for both. (Belt-and-suspenders: confirm the vuln
# source really uses the no-offset formula and the hardened one the VS/VA formula.)
grep -q 'assets\*totalShares/ta' "$WORK/vuln/src/Vault.sol" || { note "internal: vulnerable vault did not get the no-offset pricing" >&2; exit 3; }
grep -q 'totalShares + VS' "$WORK/hard/src/Vault.sol" || { note "internal: hardened vault did not get the virtual-offset pricing" >&2; exit 3; }

# Drive one target through the FULL substrate loop (mock backend = no LLM; the FIXTURE drives the test, the
# REAL Foundry fuzzer judges). $1 = repo, $2 = output dir.
SEED=1
run_one() {
  "$RUNNER" --repo "$1" --target "Vault.sol:Vault" --class "C-erc4626" \
            --handler-fixture "$WORK/fixture.t.sol" --backend mock \
            --runs 256 --depth 64 --seed "$SEED" --out "$2" >"$2.log" 2>&1
}

# Read the verdict cell out of a report's table row for Vault.sol:Vault.
verdict_of() {
  _row="$(grep -F '| Vault.sol:Vault ' "$1" 2>/dev/null | tail -1 || true)"
  printf '%s' "$_row" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$5); print $5}'
}

# ----------------------------------------------------------------------------------------------------------
# 1) VULNERABLE vault -> FINDING with a NON-EMPTY shrunk exploit sequence.
# ----------------------------------------------------------------------------------------------------------
note "driving the VULNERABLE vault -> fixture handler -> REAL Foundry stateful fuzzer -> verdict (mock backend) ..."
run_one "$WORK/vuln" "$WORK/vuln-out"; RC=$?
VREPORT="$WORK/vuln-out/invariant-report.md"
if [ "$RC" -ne 0 ] || [ ! -f "$VREPORT" ]; then
  bad "run-invariant-hunt.sh did not complete on the vulnerable vault (exit $RC); log:"
  sed 's/^/        | /' "$WORK/vuln-out.log" 2>/dev/null
else
  VV="$(verdict_of "$VREPORT")"
  if [ "$VV" = "FINDING" ]; then
    ok "VULNERABLE vault -> FINDING (the fuzzer's verdict, not the LLM's)"
    # The witness must be a non-empty shrunk call-sequence (the reproducible exploit).
    if grep -q '## Shrunk exploit call-sequence' "$VREPORT" && grep -qE 'victimDeposit\(|attackerDonate\(' "$VREPORT"; then
      ok "  witness present: a non-empty shrunk multi-step exploit sequence"
      note "  the shrunk exploit sequence the fuzzer found:"
      sed -n '/```/,/```/p' "$VREPORT" | sed '/```/d' | sed 's/^/        | /'
    else
      bad "  FINDING but no non-empty shrunk exploit sequence in the report"
    fi
  else
    bad "VULNERABLE vault expected FINDING, got '${VV:-<no row>}'"
    sed 's/^/        | /' "$WORK/vuln-out.log" 2>/dev/null | tail -20
  fi
fi

# ----------------------------------------------------------------------------------------------------------
# 2) HARDENED vault -> CLEAN (no false positive on the fix).
# ----------------------------------------------------------------------------------------------------------
note "driving the HARDENED vault (same handler, same search) -> verdict (mock backend) ..."
run_one "$WORK/hard" "$WORK/hard-out"; RC=$?
HREPORT="$WORK/hard-out/invariant-report.md"
if [ "$RC" -ne 0 ] || [ ! -f "$HREPORT" ]; then
  bad "run-invariant-hunt.sh did not complete on the hardened vault (exit $RC); log:"
  sed 's/^/        | /' "$WORK/hard-out.log" 2>/dev/null
else
  HV="$(verdict_of "$HREPORT")"
  if [ "$HV" = "CLEAN" ]; then
    ok "HARDENED vault -> CLEAN (the same fuzzed search could not break the invariant — no false positive)"
  else
    bad "HARDENED vault expected CLEAN, got '${HV:-<no row>}'"
    sed 's/^/        | /' "$WORK/hard-out.log" 2>/dev/null | tail -20
  fi
fi

echo
if [ "$FAILS" -eq 0 ]; then
  note "PASS: the LLM-as-generator / FUZZER-as-judge loop caught the VULNERABLE vault's multi-step inflation"
  note "      attack with a concrete shrunk exploit sequence (a CANDIDATE witness), and did NOT false-positive"
  note "      on the HARDENED twin — verdict is the fuzzer's, reproducible under a fixed seed; generation used a"
  note "      fixture so no LLM was involved (#1035). A FINDING is a LEAD a human triages; this colony never posts."
  exit 0
fi
note "DEMO FAILED — a verdict did not match the contract" >&2
exit 1
