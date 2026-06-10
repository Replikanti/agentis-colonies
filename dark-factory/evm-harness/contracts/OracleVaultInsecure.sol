// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// INSECURE — price read from a single manipulable spot source with no TWAP / sanity bound.
/// This contract bundles a minimal constant-product pair (the spot source) and a consumer that
/// quotes the collateral value of `token0` straight from the LIVE reserves: `price = reserve1 *
/// 1e18 / reserve0`. Anyone can move the reserves in the SAME transaction via `swap()` (a direct
/// reserve skew, the EVM analog of a flash-loan-funded swap), so an attacker inflates the spot
/// price and then borrows far more than the collateral is really worth. There is no
/// time-weighted average and no bound — the contract trusts whatever the instantaneous reserves
/// say. The EVM analog of a High: oracle/AMM manipulation. Self-contained (one deployable
/// contract) so the revm PoC can drive it from a single bytecode argv.
contract OracleVaultInsecure {
    uint256 public reserve0; // token0 (the collateral asset)
    uint256 public reserve1; // token1 (the quote asset, ~stablecoin)
    uint256 public debt;     // quote-asset units lent against deposited collateral

    constructor(uint256 r0, uint256 r1) {
        reserve0 = r0;
        reserve1 = r1;
    }

    /// Constant-product swap that mutates the LIVE reserves — the manipulation lever. Pushing
    /// `amount0In` of token0 in pulls token1 out, skewing the spot price upward for token0.
    function swap(uint256 amount0In) external {
        require(amount0In > 0, "zero in");
        uint256 k = reserve0 * reserve1;
        reserve0 += amount0In;
        uint256 newReserve1 = k / reserve0;
        reserve1 = newReserve1;
    }

    /// BUG: the price is the INSTANTANEOUS spot ratio of the reserves — no TWAP, no bound.
    function price() public view returns (uint256) {
        return (reserve1 * 1e18) / reserve0;
    }

    /// Borrow quote-asset units against `collateral0` token0, valued at the manipulable spot
    /// price. An attacker who skewed `price()` upward in this tx extracts more than the
    /// collateral is worth.
    function borrow(uint256 collateral0) external returns (uint256 borrowed) {
        borrowed = (collateral0 * price()) / 1e18;
        debt += borrowed;
        return borrowed;
    }
}
