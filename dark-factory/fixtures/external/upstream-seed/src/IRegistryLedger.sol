// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title IRegistryLedger
/// @notice Balance view of the upstream ledger.
interface IRegistryLedger {
    /// @dev Balances are reported in the ledger's own 6-decimal unit, NOT in the token's decimals.
    function balanceOf(address account) external view returns (uint256);
}
