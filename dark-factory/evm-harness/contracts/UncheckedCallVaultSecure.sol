// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// SECURE — the low-level call's success is checked. `withdraw()` zeroes the balance first
/// (no CEI issue) and then REQUIRES the returned bool of the `.call`, so a failed transfer
/// reverts the whole transaction (the debit is rolled back) instead of being silently trusted.
/// This is the control that proves the two-sided gate is not a rigged always-fire harness: the
/// honest withdraw still works, only a genuinely failing transfer is rejected.
contract UncheckedCallVaultSecure {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "no balance");
        balanceOf[msg.sender] = 0;
        // FIX: the success bool is checked — a failed send reverts (and rolls back the debit).
        (bool ok, ) = msg.sender.call{value: bal}("");
        require(ok, "send failed");
    }

    receive() external payable {}
}
