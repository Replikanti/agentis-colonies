// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-accounting TOOTHLESS invariant — the NEGATIVE control. It drives the SAME handler actions but asserts
// a VACUOUS property (`totalDebt >= 0`, always true for a uint), so it can NEVER break: it SURVIVES even
// the inverted-rounding mutant (verdict CLEAN). Pairing it against the mutant in the manifest is the
// source-level DISCRIMINATION proof — the self-test asserts the GOOD solvency invariant KILLS a mutant the
// toothless one MISSES, so a "kill" measures invariant EXPRESSIVENESS, not a rigged always-fire harness.
// Same imports / StdInvariant ABI as the good invariant; imports the staged `../src/Target.sol`.
import {Lending} from "../src/Target.sol";

contract Handler {
    Lending public lend;
    constructor(Lending _l){ lend = _l; }
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function deposit(uint a) public { a = _bound(a, 1, 1e24); lend.deposit(a); }
    function borrow(uint a) public {
        uint c = lend.collateral(address(this));
        uint d = lend.debt(address(this));
        if (c <= d) return;
        a = _bound(a, 1, c - d);
        lend.borrow(a);
    }
    function accrue(uint a) public { a = _bound(a, 1, 1e24); lend.accrue(a); }
}

abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract LendingToothlessTest is InvBase {
    Lending lend; Handler h;
    function setUp() public { lend = new Lending(); h = new Handler(lend); _target(address(h)); }
    // VACUOUS: totalDebt is a uint, so this holds for every reachable state -> never a finding.
    function invariant_debt_nonneg() public view {
        require(lend.totalDebt() >= 0, "unreachable");
    }
}
