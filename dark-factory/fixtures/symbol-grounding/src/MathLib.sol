// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A library the singleton uses via `using MathLib for uint256`. Its NAME must be in the inventory so the
// grounded harness never invents a differently-named math helper.
library MathLib {
    uint256 internal constant ONE = 1e18;

    function scaleUp(uint256 x) internal pure returns (uint256) {
        return x * ONE;
    }

    function mulDown(uint256 a, uint256 b) public pure returns (uint256) {
        return (a * b) / ONE;
    }
}
