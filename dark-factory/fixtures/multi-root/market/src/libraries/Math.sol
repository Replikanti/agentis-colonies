// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): market's math library (a same-named copy lives in core/).
library Math {
    function mulDiv(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        return (a * b + c - 1) / c;
    }
}
