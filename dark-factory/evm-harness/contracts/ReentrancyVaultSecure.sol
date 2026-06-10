// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// SECURE — checks-effects-interactions order restored. The recorded balance is zeroed
/// BEFORE the external `call`, so a re-entrant `withdraw()` sees a zero balance and reverts
/// on the `require(bal > 0)`. The attacker can never withdraw more than it deposited. This
/// is the control that proves the two-sided gate is not a rigged always-fire harness.
contract ReentrancyVaultSecure {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "no balance");
        balanceOf[msg.sender] = 0; // EFFECT first
        (bool ok, ) = msg.sender.call{value: bal}(""); // INTERACTION after
        require(ok, "send failed");
    }

    receive() external payable {}
}
