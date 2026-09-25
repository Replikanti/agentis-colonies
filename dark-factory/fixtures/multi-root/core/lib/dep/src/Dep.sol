// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): a vendored dependency under core/lib/ — pruned, never a zone or a root.
contract Dep {
    function ping() external pure returns (uint256) {
        return 1;
    }
}
