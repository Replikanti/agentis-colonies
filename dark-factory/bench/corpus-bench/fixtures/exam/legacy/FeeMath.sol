// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Synthetic fixture for the #2311 pointed-ladder self-test: a library-only anchor (no concrete deploy target,
// so a pointed arm keeps the whole zone as its STAGE 4.5 target set). Never deployed.
library FeeMath {
    function mulDown(uint256 a, uint256 b, uint256 d) internal pure returns (uint256) {
        return (a * b) / d;
    }
}
