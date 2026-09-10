// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SETTABILITY): same call shape and same OUT-OF-SCOPE `IOracle` callee as ScopedVault, but
// the oracle address is `immutable` with NO setter, so it is NOT attacker-repointable. stub_eligible() MUST be
// 0 here (has_settable_callee is false), so no hostile stub is synthesized -> no fabricated finding.

interface IOracle {
    function price() external view returns (uint256);
}

contract ImmutableCalleeVault {
    address public immutable oracle;
    mapping(address => uint256) public shares;

    constructor(address o) {
        oracle = o;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = IOracle(oracle).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
    }
}
