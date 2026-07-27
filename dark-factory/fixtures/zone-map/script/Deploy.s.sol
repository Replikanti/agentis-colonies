// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: a Foundry deployment script under `script/` — must NOT become a discovery zone.
contract DeployScript {
    function run() external pure returns (bool) {
        return true;
    }
}
