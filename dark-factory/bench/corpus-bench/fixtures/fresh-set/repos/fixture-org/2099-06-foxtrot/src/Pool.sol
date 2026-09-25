// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Pool {
    uint256 public total;

    function add(uint256 a) external {
        total += a;
    }
}
