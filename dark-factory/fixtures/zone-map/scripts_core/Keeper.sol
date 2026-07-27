// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: `scripts_core/` is a REAL directory name (not the excluded `script/` prefix) —
/// a naive substring match on "script" would wrongly sweep this up; segment-anchored matching must not.
contract Keeper {
    function keep() external pure returns (bool) {
        return true;
    }
}
