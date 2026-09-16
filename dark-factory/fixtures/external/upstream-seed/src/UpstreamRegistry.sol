// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title UpstreamRegistry
/// @notice The canonical registry, readable only from the upstream repository.
contract UpstreamRegistry {
    mapping(address => bool) internal listed;

    /// @notice A source is listed only after governance accepts it; delisting is immediate and
    ///         retroactive, so a cached `isListed` answer may already be stale when it is used.
    function isListed(address source) external view returns (bool) {
        return listed[source];
    }
}
