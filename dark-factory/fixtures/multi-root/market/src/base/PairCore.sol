// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): an abstract base with a body-less virtual member, split by directory from
///         its implementor market/src/Pair.sol — the #1861 inheritance-appendix trigger.
abstract contract PairCore {
    uint256 public balance;

    function settle(uint256 amount) external returns (uint256) {
        return _settle(amount);
    }

    function _settle(uint256 amount) internal virtual returns (uint256);
}
