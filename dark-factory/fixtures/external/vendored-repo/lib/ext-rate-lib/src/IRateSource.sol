// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRateSource
/// @notice Minimal rate reader used by the consumer under audit.
interface IRateSource {
    /// @notice Rate of one unit of the source asset expressed in the quote asset.
    /// @dev The returned value is scaled by 1e18 for a standard source. A source whose quote asset
    ///      reports fewer than 18 decimals returns a value scaled by those decimals INSTEAD, so a
    ///      consumer that assumes 1e18 everywhere reads a wrongly scaled number for those sources.
    function rate(address source) external view returns (uint256); // scaled by 1e18 for standard sources

    /// @notice Decimals the rate returned by `rate` is scaled by.
    function rateDecimals(address source) external view returns (uint8);
}
