// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A mock/helper ERC20-ish token co-staged as an --aux dependency. Its NAME + external signatures round out the
// multi-contract inventory the grounder assembles across the target + aux sources.
contract MockToken {
    mapping(address => uint256) public balanceOf;
    uint8 public constant decimals = 6;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
