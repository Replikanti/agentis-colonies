// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// SECURE — the borrow price is NOT the raw instantaneous spot. `borrow()` values collateral at
/// a stored `anchorPrice` (a TWAP stand-in, fixed when liquidity was established) and additionally
/// requires the LIVE spot to stay within a tight deviation bound of that anchor. An attacker who
/// skews the reserves in the same transaction pushes the spot away from the anchor, so the bound
/// check reverts and the manipulated price is never trusted. This is the control that proves the
/// two-sided gate is not a rigged always-fire harness: an honest borrow at fair (unmanipulated)
/// reserves passes the bound and is accepted; only a manipulated borrow is rejected.
contract OracleVaultSecure {
    uint256 public reserve0;
    uint256 public reserve1;
    uint256 public debt;
    uint256 public immutable anchorPrice; // TWAP stand-in: the trusted price, fixed up front
    uint256 public constant MAX_DEVIATION_BPS = 100; // 1% bound between spot and anchor

    constructor(uint256 r0, uint256 r1) {
        reserve0 = r0;
        reserve1 = r1;
        anchorPrice = (r1 * 1e18) / r0;
    }

    function swap(uint256 amount0In) external {
        require(amount0In > 0, "zero in");
        uint256 k = reserve0 * reserve1;
        reserve0 += amount0In;
        uint256 newReserve1 = k / reserve0;
        reserve1 = newReserve1;
    }

    function spotPrice() public view returns (uint256) {
        return (reserve1 * 1e18) / reserve0;
    }

    /// FIX: price off the anchor (TWAP stand-in) and reject when the live spot deviates beyond
    /// the bound — a same-tx manipulation moves the spot away from the anchor and reverts here.
    function borrow(uint256 collateral0) external returns (uint256 borrowed) {
        uint256 spot = spotPrice();
        uint256 hi = (anchorPrice * (10000 + MAX_DEVIATION_BPS)) / 10000;
        uint256 lo = (anchorPrice * (10000 - MAX_DEVIATION_BPS)) / 10000;
        require(spot <= hi && spot >= lo, "price out of bounds");
        borrowed = (collateral0 * anchorPrice) / 1e18;
        debt += borrowed;
        return borrowed;
    }
}
