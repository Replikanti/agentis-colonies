// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IExtQuoteFeed
/// @notice An external protocol's quote feed, vendored the way a real repository does it when it keeps
///         third-party interfaces beside its own source instead of under `lib/` (#2240).
interface IExtQuoteFeed {
    /// @notice Latest quote for the pair.
    /// @dev The returned value is always scaled by 1e18, whatever the underlying assets' decimals are.
    function latestQuote(address base, address quote) external view returns (uint256); // scaled by 1e18
}
