// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "./libraries/Math.sol";

/// @notice Multi-root fixture (#2255): the `core` project's share vault. Generic, public-safe.
contract Vault {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;

    function deposit(uint256 assets) external returns (uint256 minted) {
        minted = Math.mulDiv(assets, totalShares + 1, totalAssets + 1);
        shares[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
    }

    function withdraw(uint256 amount) external returns (uint256 assets) {
        assets = Math.mulDiv(amount, totalAssets + 1, totalShares + 1);
        shares[msg.sender] -= amount;
        totalShares -= amount;
        totalAssets -= assets;
    }
}
