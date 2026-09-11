// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture (BOUND-ENFORCEMENT negative arm, pins the one-hop limit) for scope_probe()'s widened-read
// fallback.
//
// Same shape as TransitiveOutOfScopeCalleeVault.sol, but the extends chain to the cast-site name `IOracle` is
// TWO hops out of scope, declared in `lib/IOracleExtChain2.sol`: the chain runs
// IOracleExt2 -> IOracleExt2Mid -> IOracle (two extends links, each on its own declaration). The in-scope
// contract `ChainImpl2` implements `IOracleExt2` — one hop from the cast site's REAL carrier requirement, but
// the one-hop fallback only learns the FIRST link (IOracleExt2 extends IOracleExt2Mid), never the SECOND
// (IOracleExt2Mid extends IOracle) — following a second out-of-scope link is explicitly out of bound per
// #2177 STOP 1.
//
// MUST STAY "SCANNED" (armed): scope_probe("IOracle", repo) must NOT resolve here. This is the false-positive
// bound pin — the one-hop fallback must not silently become an unbounded chain-follower.
//
// NOTE: this comment deliberately never writes the two extends declarations as adjacent `<keyword> <Name> is
// <Base>` text on a single line — scope_probe() matches raw file text, comments included (by design, see the
// FAIL-CLOSED-BY-CONSTRUCTION note above scope_probe()), so a comment that LOOKED like a real declaration line
// could itself leak a false one-hop candidate. Describing the chain with arrows keeps this fixture's own prose
// from becoming an accidental carrier.

import {IOracleExt2} from "../lib/IOracleExtChain2.sol";

interface IOracle {
    function price() external view returns (uint256);
}

contract ChainImpl2 is IOracleExt2 {
    function price() external pure returns (uint256) {
        return 1;
    }
    function extraMid() external {}
    function extra() external {}
}

contract TwoHopOutOfScopeCalleeVault {
    address public oracle;

    // UNGUARDED: any caller can repoint the settable callee -> an ATTACKER repoint, not an admin one.
    function setOracle(address newOracle) external {
        oracle = newOracle;
    }

    function price() external returns (uint256) {
        return IOracle(oracle).price();
    }
}
