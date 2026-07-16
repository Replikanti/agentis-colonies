// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A NON-custody helper zone: read-only view getters, no value-moving entrypoint body and no amount-deduction
// arithmetic, so zone-mapper.ag's is_value_custody would return false (the deep-hunt stage skips it). The
// offline self-test declares this with the map fixture's `CUSTODY|src_periphery|false` line.
interface IVault {
    function totalShares() external view returns (uint256);
    function shares(address who) external view returns (uint256);
}

contract Views {
    IVault public vault;

    constructor(IVault v) { vault = v; }

    function shareOf(address who) external view returns (uint256) {
        return vault.shares(who);
    }

    function totalShares() external view returns (uint256) {
        return vault.totalShares();
    }
}
