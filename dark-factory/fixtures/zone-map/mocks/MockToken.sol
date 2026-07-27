// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: a Foundry mock under `mocks/` — must NOT become a discovery zone.
contract MockToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }
}
