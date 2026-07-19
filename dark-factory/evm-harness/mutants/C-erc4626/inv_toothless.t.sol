// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-erc4626 TOOTHLESS invariant — the NEGATIVE control. It drives the SAME handler actions but asserts
// a VACUOUS property (`totalShares >= 0`, always true for a uint), so it can NEVER break: it SURVIVES
// even the donation/inflation mutant (verdict CLEAN). Pairing it against the mutant in the manifest is
// the source-level DISCRIMINATION proof — the self-test asserts the GOOD invariant KILLS a mutant the
// toothless one MISSES, so a "kill" measures invariant EXPRESSIVENESS, not a rigged always-fire harness.
// Same imports / StdInvariant ABI as the good invariant; imports the staged `../src/Target.sol`.
import {Vault, Token} from "../src/Target.sol";

contract Handler {
    Vault public v; Token public t;
    constructor(Vault _v, Token _t){ v=_v; t=_t; }
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }
    function attackerDonate(uint a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); }
    function victimDeposit(uint a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        v.deposit(a);
    }
}

abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract VaultToothlessTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t=new Token(); v=new Vault(t); h=new Handler(v,t); _target(address(h)); }
    // VACUOUS: totalShares is a uint, so this holds for every reachable state -> never a finding.
    function invariant_shares_nonneg() public view {
        require(v.totalShares() >= 0, "unreachable");
    }
}
