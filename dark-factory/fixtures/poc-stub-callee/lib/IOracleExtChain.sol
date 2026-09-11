// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture companion — deliberately OUTSIDE src/contracts. This is the file scope_probe()'s bounded
// one-hop fallback is allowed to see (read-only, whole-repo widened find) when resolving
// TransitiveOutOfScopeCalleeVault.sol's `IOracle` cast against its in-scope one-hop implementer
// `ChainImpl is IOracleExt`. It is never copied into an isolated fixture's src/.

interface IOracle {
    function price() external view returns (uint256);
}

interface IOracleExt is IOracle {
    function extra() external;
}
