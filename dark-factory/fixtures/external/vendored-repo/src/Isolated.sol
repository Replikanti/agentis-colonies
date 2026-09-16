// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Isolated
/// @notice Names an external feed the repository knows by NAME ONLY: no vendored source, no deployed
///         address anywhere in the deployment book, and no upstream repository named in any comment or
///         manifest. This is the shape whose true terminal refusal is `no-address` (#2238).
contract Isolated {
    function quote(address feed) external view returns (uint256) {
        return IIsolatedFeed(feed).spot();
    }
}

interface IIsolatedFeed {
    function spot() external view returns (uint256);
}
