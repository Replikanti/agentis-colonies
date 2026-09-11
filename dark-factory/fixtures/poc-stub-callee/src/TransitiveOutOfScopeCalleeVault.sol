// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2177 fixture (ONE-HOP INHERITANCE resolution POSITIVE arm) for scope_probe()'s bounded widened-read fallback.
//
// The vault casts the settable callee to `IOracle` (a locally declared interface, so the cast site compiles
// standalone). No in-scope type carries `IOracle` directly or via any in-scope extends chain — the extends
// link lives OUT of scope, in `lib/IOracleExtChain.sol` (`interface IOracleExt is IOracle`). The in-scope
// contract `ChainImpl` implements `IOracleExt`, one hop removed from the cast-site name. A resolver bounded to
// `src`/`contracts` alone would never learn that `IOracleExt` extends `IOracle` and would fabricate an
// out-of-scope stub against a callee that genuinely has an in-scope, drivable implementer.
//
// MUST make scope_probe("IOracle", repo) resolve "FOUND" via the bounded one-hop fallback: the widened
// (whole-repo, read-only) scan finds `interface IOracleExt is IOracle` in `lib/IOracleExtChain.sol`, and the
// candidate name `IOracleExt` then carries via the SAME in-scope-only carrier check (`contract ChainImpl is
// IOracleExt`).

import {IOracleExt} from "../lib/IOracleExtChain.sol";

interface IOracle {
    function price() external view returns (uint256);
}

contract ChainImpl is IOracleExt {
    function price() external pure returns (uint256) {
        return 1;
    }
    function extra() external {}
}

contract TransitiveOutOfScopeCalleeVault {
    address public oracle;

    // UNGUARDED: any caller can repoint the settable callee -> an ATTACKER repoint, not an admin one.
    function setOracle(address newOracle) external {
        oracle = newOracle;
    }

    function price() external returns (uint256) {
        return IOracle(oracle).price();
    }
}
