// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Share/asset conversion helpers for the vault zone (rounding-direction surface).
library VaultMath {
    function toShares(uint256 assets, uint256 supply, uint256 total) internal pure returns (uint256) {
        if (supply == 0 || total == 0) return assets;
        return (assets * supply) / total;
    }

    function toAssets(uint256 amount, uint256 supply, uint256 total) internal pure returns (uint256) {
        if (supply == 0) return 0;
        return (amount * total) / supply;
    }
}
