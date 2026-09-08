// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2145 fixture (positive arm) for hunter.ag's attacker-controlled-callee detector.
//
// The vault pokes an oracle whose ADDRESS is a mutable state variable with a deployer-only setter, and it
// pokes it BEFORE the balance write. Nothing here is privileged-role abuse: the setter behaves exactly as
// documented. The exploitable half is that the CALLEE the vault hands control to is whatever that address
// currently points at, so it can reenter `deposit` against stale storage.
//
// MUST trip has_attacker_controlled_callee(): the interface-typed call `IOracle(oracle).poke()` is the call
// surface, and BOTH the `setOracle(address)` setter and the mutable `address public oracle;` declaration are
// settable-target signals.

interface IOracle {
    function poke() external;
}

contract SettableOracleVault {
    address public owner;
    address public oracle;

    mapping(address => uint256) public balanceOf;

    constructor(address initialOracle) {
        owner = msg.sender;
        oracle = initialOracle;
    }

    function setOracle(address newOracle) external {
        require(msg.sender == owner);
        oracle = newOracle;
    }

    function deposit(uint256 amount) external {
        IOracle(oracle).poke();
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
    }
}
