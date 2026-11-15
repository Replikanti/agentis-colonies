// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// Generic ether vault with one privileged path. Protocol-agnostic on purpose: no real product, protocol or
// token name appears anywhere, and these comments describe ONLY the code, never the gate that consumes it.
//
// Shape: users deposit and withdraw their own balance (checks, then effects, then the transfer). One more
// function moves the ether held above the sum of deposits, and it is behind a single owner check.

contract GuardedVault {
    address public immutable owner;

    mapping(address => uint256) public balanceOf;

    uint256 public totalDeposits;

    constructor() {
        owner = msg.sender;
    }

    function deposit() external payable {
        balanceOf[msg.sender] = balanceOf[msg.sender] + msg.value;
        totalDeposits = totalDeposits + msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient balance");
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
        totalDeposits = totalDeposits - amount;
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
    }

    function sweepSurplus(address to) external {
        require(msg.sender == owner, "not owner");
        uint256 surplus = address(this).balance - totalDeposits;
        (bool ok, ) = to.call{value: surplus}("");
        require(ok, "transfer failed");
    }
}
