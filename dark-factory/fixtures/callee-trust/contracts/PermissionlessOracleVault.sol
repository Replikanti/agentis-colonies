// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// Live-classification fixture (permissionless arm) for hunter.ag's #2145 attacker-controlled-callee directive's
// #2180 classification refinement.
//
// Same call shape as SettableOracleVault.sol (the zone-level detector's positive arm), but `setOracle` carries
// NO privilege guard at all — no `onlyOwner`, no `require(msg.sender == owner)`, nothing. Per the #2179 taxonomy
// this directive now mirrors, the oracle target is ATTACKER-REPOINTABLE (mutable address + unguarded external
// setter): ANY caller can repoint it, so the hunter MUST still classify the callee as hostile and emit a
// `CALLEE-VECTOR|...|CANDIDATE` line. This is the recall-guard arm — if the classification refinement ever
// suppresses this fixture too, the directive has gone from "conditional" to "always dismissed" and lost the
// recall #2145 exists to protect.

interface IOracle {
    function poke() external;
}

contract PermissionlessOracleVault {
    address public oracle;

    mapping(address => uint256) public balanceOf;

    constructor(address initialOracle) {
        oracle = initialOracle;
    }

    // UNGUARDED: any caller can repoint the callee -> an ATTACKER repoint, not an admin one.
    function setOracle(address newOracle) external {
        oracle = newOracle;
    }

    function deposit(uint256 amount) external {
        IOracle(oracle).poke();
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
    }
}
