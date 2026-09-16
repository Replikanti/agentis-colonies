// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "ext-registry/src/IRegistryLedger.sol";

/// @title Ledger
/// @notice Mirrors balances the upstream ledger owns. This header names no repository on purpose:
///         the only pointer to the upstream code is the vendored package manifest.
contract Ledger {
    IRegistryLedger public ledger;

    function mirror(address account) external view returns (uint256) {
        return ledger.balanceOf(account);
    }
}
