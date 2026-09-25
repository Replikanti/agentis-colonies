// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture for fresh-set.sh --self-test (#2263). Line numbers are the pin: do not reflow.
contract Vault {
    mapping(address => uint256) public shares;

    function deposit(uint256 amount) external {
        shares[msg.sender] += amount;
    }

    function claimRewards() external {
        uint256 owed = shares[msg.sender];
        (bool ok, ) = msg.sender.call{value: owed}("");
        require(ok);
        shares[msg.sender] = 0;
    }

    // No GT row names this function: the cued probe's decoy.
    function pause() external {}
}
