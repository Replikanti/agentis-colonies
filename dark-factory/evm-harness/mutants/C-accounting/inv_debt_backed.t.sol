// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-accounting GOOD invariant — system-wide SOLVENCY: total collateral must always back total debt
// (`totalCollateral >= totalDebt`). The inverted-rounding mutant consumes full collateral while crediting
// only half the debt on each accrue, so a borrow-to-limit + accrue sequence drives collateral below debt
// -> a SEQUENCE the stateful fuzzer must find (verdict FINDING = KILLED). Against the correctly-accounted
// base twin the same search cannot break it (verdict CLEAN = SURVIVED). forge-std-free: targets registered
// via the `targetContracts()` StdInvariant view, asserted with plain require(). Imports the staged
// `../src/Target.sol` (STABLE-CONTRACT-NAME rule), never its own Lending shadow.
import {Lending} from "../src/Target.sol";

// The protocol's actions as a user drives them, with fuzzed inputs bounded to realistic ranges. A single
// handler acts as one position, so per-position accounting is the system accounting.
contract Handler {
    Lending public lend;
    constructor(Lending _l){ lend = _l; }
    // forge-std-free bound: keep a fuzzed uint inside [lo, hi] without the forge-std `bound` cheatcode.
    function _bound(uint x, uint lo, uint hi) internal pure returns (uint) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function deposit(uint a) public { a = _bound(a, 1, 1e24); lend.deposit(a); }
    function borrow(uint a) public {
        uint c = lend.collateral(address(this));
        uint d = lend.debt(address(this));
        if (c <= d) return;                    // no headroom -> skip (keeps the call from reverting)
        a = _bound(a, 1, c - d);
        lend.borrow(a);
    }
    function accrue(uint a) public { a = _bound(a, 1, 1e24); lend.accrue(a); }
}

// StdInvariant ABI forge auto-discovers: targetContracts() lists the addresses the fuzzer drives. No forge-std.
abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract LendingInvariantTest is InvBase {
    Lending lend; Handler h;
    function setUp() public { lend = new Lending(); h = new Handler(lend); _target(address(h)); }
    // SOLVENCY: the pool's total collateral must always cover its total debt. The rounding mutant drifts
    // collateral below debt over a call sequence; correct accounting holds it.
    function invariant_debt_backed() public view {
        require(lend.totalCollateral() >= lend.totalDebt(), "insolvent: debt exceeds collateral");
    }
}
