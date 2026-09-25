// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): the `core` project's own `Pair`. Its NAME collides with market/src/Pair.sol
///         on purpose: without per-root partitions the name is ambiguous and market's appendix is dropped.
contract Pair {
    uint256 public reserve0;
    uint256 public reserve1;

    function swap(uint256 amountIn) external returns (uint256 amountOut) {
        amountOut = (amountIn * reserve1) / (reserve0 + amountIn);
        reserve0 += amountIn;
        reserve1 -= amountOut;
    }
}
