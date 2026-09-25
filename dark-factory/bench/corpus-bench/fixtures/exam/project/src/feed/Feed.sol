// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture for the #2262 exam runner self-test. Never deployed.
contract Feed {
    uint256 public price;
    uint256 public updatedAt;
    address public keeper;

    constructor() {
        keeper = msg.sender;
    }

    function push(uint256 p) external {
        require(msg.sender == keeper, "keeper");
        price = p;
        updatedAt = block.timestamp;
    }

    function read() external view returns (uint256) {
        return price;
    }
}
