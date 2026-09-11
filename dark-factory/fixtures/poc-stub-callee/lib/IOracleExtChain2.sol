// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture companion — deliberately OUTSIDE src/contracts, and deliberately TWO hops from `IOracle`. This
// pins the bound of scope_probe()'s one-hop fallback: TwoHopOutOfScopeCalleeVault.sol's `IOracle` cast must NOT
// resolve through this chain (the extends chain runs IOracleExt2 -> IOracleExt2Mid -> IOracle) — following the
// second link would grant scope credit two hops out, which #2177 STOP 1 explicitly puts out of bound. It is
// never copied into an isolated fixture's src/. (See the NOTE in TwoHopOutOfScopeCalleeVault.sol: this comment
// avoids writing the two declarations as adjacent `<keyword> <Name> is <Base>` text on one line on purpose.)

interface IOracle {
    function price() external view returns (uint256);
}

interface IOracleExt2Mid is IOracle {
    function extraMid() external;
}

interface IOracleExt2 is IOracleExt2Mid {
    function extra() external;
}
