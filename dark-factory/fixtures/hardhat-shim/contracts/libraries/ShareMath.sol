// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Foundry-shim fixture (#2277): share <-> asset conversion.
library ShareMath {
    function toShares(uint256 assets, uint256 supply, uint256 held) internal pure returns (uint256) {
        return supply == 0 || held == 0 ? assets : (assets * supply) / held;
    }

    function toAssets(uint256 shareAmount, uint256 supply, uint256 held) internal pure returns (uint256) {
        return supply == 0 ? 0 : (shareAmount * held) / supply;
    }
}
