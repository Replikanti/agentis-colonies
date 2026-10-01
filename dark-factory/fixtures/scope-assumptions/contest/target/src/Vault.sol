// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture: a deposit/withdraw pair whose code trips the value-moving + deduction signal.
contract Vault {
    mapping(address => uint256) public balances;
    uint256 public fee;
    address public admin;

    function deposit(uint256 amount) external {
        balances[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        balances[msg.sender] -= amount;
    }

    function setFee(uint256 newFee) external {
        require(msg.sender == admin, "admin");
        require(newFee <= 1000, "bound");
        fee = newFee;
    }
}
