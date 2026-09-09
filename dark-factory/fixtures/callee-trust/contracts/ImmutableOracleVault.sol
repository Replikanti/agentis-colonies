// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2145 fixture (negative arm) for hunter.ag's attacker-controlled-callee detector.
//
// Same call shape as the positive arm, but the oracle address is fixed at construction and can never be
// repointed: no setter, no mutable `address` state variable, and the call target is a stored `immutable`
// rather than something resolved through an external getter.
//
// MUST NOT trip has_attacker_controlled_callee(): the call surface is present, but no settable-target signal
// is. The directive is therefore "" and the hunt prompt stays byte-identical to the pre-#2145 one, with no
// CALLEE-TRUST| sentinel in the cell log.

interface IOracle {
    function poke() external;
}

contract ImmutableOracleVault {
    address public immutable oracle;

    mapping(address => uint256) public balanceOf;

    constructor(address fixedOracle) {
        oracle = fixedOracle;
    }

    function deposit(uint256 amount) external {
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
        IOracle(oracle).poke();
    }
}
