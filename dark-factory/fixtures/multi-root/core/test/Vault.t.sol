// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): a test file inside a project root — never a zone (#1824).
contract VaultTest {
    function test_deposit() external pure returns (bool) {
        return true;
    }
}
