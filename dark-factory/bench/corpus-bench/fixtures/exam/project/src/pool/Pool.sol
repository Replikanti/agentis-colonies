// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture for the #2262 exam runner self-test. Never deployed.
contract Pool {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;

    function deposit(uint256 assets) external returns (uint256 minted) {
        minted = totalShares == 0 ? assets : (assets * totalShares) / totalAssets;
        shares[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
    }

    function withdraw(uint256 amount) external {
        uint256 assets = (amount * totalAssets) / totalShares;
        totalAssets -= assets;
        shares[msg.sender] -= amount;
        totalShares -= amount;
    }
}
