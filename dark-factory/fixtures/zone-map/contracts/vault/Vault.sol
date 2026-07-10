// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./VaultMath.sol";

/// @notice A minimal ERC4626-style share vault fixture for the zone-map demo.
///         Generic, public-safe — no real protocol.
contract Vault {
    mapping(address => uint256) public shares;
    uint256 public totalShares;
    uint256 public totalAssets;

    function deposit(uint256 assets) external returns (uint256 minted) {
        minted = VaultMath.toShares(assets, totalShares, totalAssets);
        shares[msg.sender] += minted;
        totalShares += minted;
        totalAssets += assets;
    }

    function redeem(uint256 amount) external returns (uint256 assets) {
        assets = VaultMath.toAssets(amount, totalShares, totalAssets);
        shares[msg.sender] -= amount;
        totalShares -= amount;
        totalAssets -= assets;
    }

    function pricePerShare() external view returns (uint256) {
        if (totalShares == 0) return 1e18;
        return (totalAssets * 1e18) / totalShares;
    }
}
