// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: a `libraries/` contract — MUST still become a discovery zone (this is the
/// regression the fix guards against; yieldoor's rare M-2 finding lives in `ReserveLogic._updateIndexes`,
/// a real accounting bug that a path-prefix exclusion must never sweep up alongside test/mocks/scripts).
library ReserveLogic {
    struct ReserveData {
        uint256 liquidityIndex;
        uint256 lastUpdateTimestamp;
    }

    function _updateIndexes(ReserveData storage self, uint256 liquidityRate) internal {
        uint256 elapsed = block.timestamp - self.lastUpdateTimestamp;
        self.liquidityIndex += (self.liquidityIndex * liquidityRate * elapsed) / 1e18;
        self.lastUpdateTimestamp = block.timestamp;
    }
}
