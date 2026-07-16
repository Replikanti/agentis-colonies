// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// Placeholder stateful-invariant handler for the #1713 deep-hunt A/B self-test. On the SELF-TEST path the
// --agentis stub short-circuits `go invariant-prover.ag` (it prints a canned INVARIANT|/STEP| witness), so
// this file is only STAGED by run-invariant-hunt.sh, never compiled/fuzzed. A real deep-hunt run (live
// backend + forge) generates its own handler; this fixture exists to exercise the offline --handler-fixture
// flag path deterministically. See demo-invariant-hunt.sh for the real proven handler shape.
import {Vault, Token} from "../src/Vault.sol";

contract Handler {
    Vault public v;
    Token public t;
    uint256 public victimDeposited;
    uint256 public victimShares;
    constructor(Vault _v, Token _t) { v = _v; t = _t; }
    function _bound(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (hi <= lo) return lo;
        return lo + (x % (hi - lo + 1));
    }
    function attackerSeed() public { t.mint(address(this), 1); v.deposit(1); }
    function attackerDonate(uint256 a) public { a = _bound(a, 1, 1e24); t.mint(address(v), a); }
    function victimDeposit(uint256 a) public {
        a = _bound(a, 1e6, 1e18);
        t.mint(address(this), a);
        uint256 s = v.deposit(a);
        victimDeposited += a; victimShares += s;
    }
}

abstract contract InvBase {
    address[] private _targets;
    function targetContracts() public view returns (address[] memory) { return _targets; }
    function _target(address a) internal { _targets.push(a); }
}

contract VaultInvariantTest is InvBase {
    Vault v; Token t; Handler h;
    function setUp() public { t = new Token(); v = new Vault(t); h = new Handler(v, t); _target(address(h)); }
    function invariant_victim_not_robbed() public view {
        uint256 vd = h.victimDeposited();
        if (vd == 0) return;
        uint256 ts = v.totalShares();
        uint256 claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");
    }
}
