// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture (ALIAS resolution POSITIVE arm) for scope_probe()'s import-alias fallback.
//
// The vault casts the settable callee to `IPriceFeed` (a locally declared interface, so the cast site compiles
// standalone — the SAME "interface declared here, never implemented here" shape PermissionlessCalleeVault uses
// for `IOracle`). The in-scope carrier, `ChainlinkFeed`, does NOT implement `IPriceFeed` by that name: it
// imports the interface under an ALIAS, `import {IPriceFeed as IX} from "./IExternalPriceFeed.sol";`, then
// declares `contract ChainlinkFeed is IX`. A resolver that only ever tests the cast-site name literally
// (`IPriceFeed`) against the in-scope carrier patterns would never see `IX` and would fabricate an
// out-of-scope stub, even though `ChainlinkFeed` genuinely implements the callee's interface in scope.
//
// The setter is UNGUARDED (the PermissionlessCalleeVault shape) so the fixture reaches the scope check inside
// stub_class() instead of short-circuiting earlier at suppressed:admin-or-unprovable.
//
// MUST make scope_probe("IPriceFeed", repo) resolve "FOUND" via the alias fallback: the cast-site name
// `IPriceFeed` has no direct in-scope carrier, but its import alias `IX` does (`contract ChainlinkFeed is IX`).

import {IPriceFeed as IX} from "./IExternalPriceFeed.sol";

interface IPriceFeed {
    function price() external view returns (uint256);
}

contract ChainlinkFeed is IX {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract AliasImportCalleeVault {
    address public feed;

    // UNGUARDED: any caller can repoint the settable callee -> an ATTACKER repoint, not an admin one.
    function setFeed(address newFeed) external {
        feed = newFeed;
    }

    function price() external returns (uint256) {
        return IPriceFeed(feed).price();
    }
}
