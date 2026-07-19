// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-erc4626 GOOD invariant — a DEEP, protocol-specific property: an honest depositor's CLAIM on the
// vault (their shares valued at the current pool balance) must always be worth at least what they
// deposited, minus dust. The donation/inflation mutant makes a victim deposit mint 0 shares, so their
// claim collapses -> a SEQUENCE the stateful fuzzer must find (verdict FINDING = KILLED). Against the
// hardened base twin the same fuzzed search cannot break it (verdict CLEAN = SURVIVED). forge-std-free:
// fuzz targets registered via the `targetContracts()` StdInvariant view, asserted with plain require().
// Imports the staged `../src/Target.sol` (the STABLE-CONTRACT-NAME rule), never its own Vault shadow.
import {Vault, Token} from "../src/Target.sol";

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
    // DEEP invariant: the victim's CLAIM (shares * vaultBalance / totalShares) must always be worth >= what
    // they deposited, minus dust. The inflation attack makes a victim deposit mint 0 shares, so their claim
    // collapses far below their deposit -> a SEQUENCE the fuzzer must find.
    function invariant_victim_not_robbed() public view {
        uint vd = h.victimDeposited();
        if (vd == 0) return;
        uint ts = v.totalShares();
        uint claim = ts == 0 ? 0 : h.victimShares() * t.balanceOf(address(v)) / ts;
        require(claim + 1e6 >= vd, "victim robbed");   // claim within dust(1e6) of deposit
    }
}
