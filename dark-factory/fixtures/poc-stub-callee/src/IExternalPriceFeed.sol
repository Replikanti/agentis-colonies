// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture companion for AliasImportCalleeVault.sol's `import {IPriceFeed as IX} from
// "./IExternalPriceFeed.sol";`. This file exists ONLY so the whole poc-stub-callee/ fixture root compiles
// (run-poc.sh's REAL forge-poc.sh gate builds the whole repo, not just the probed file) — scope_probe() itself
// never resolves or requires this import to exist; the alias resolution is pure text matching over the CASTING
// file's own source (the cast-site name + the `import {X as Y}` fragment), not a real import-graph walk.

interface IPriceFeed {
    function price() external view returns (uint256);
}
