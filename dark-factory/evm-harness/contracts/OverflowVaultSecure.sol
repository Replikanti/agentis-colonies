// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// SECURE — the `unchecked` block is removed, so solc 0.8's default checked arithmetic applies.
/// `transfer()` reverts on a debit larger than the sender's balance (underflow) instead of
/// wrapping, preserving the total-supply invariant. This is the control that proves the two-sided
/// gate is not a rigged always-fire harness: an in-range transfer still succeeds with the correct
/// arithmetic; only an out-of-range (would-underflow) transfer is rejected.
contract OverflowVaultSecure {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor() {
        balanceOf[msg.sender] = 1000;
        totalSupply = 1000;
    }

    function transfer(address to, uint256 amount) external {
        // FIX: checked arithmetic (no `unchecked`) — an over-balance debit reverts on underflow.
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}
