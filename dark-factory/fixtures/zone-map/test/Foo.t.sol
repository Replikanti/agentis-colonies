// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: a Foundry test file under `test/` — must NOT become a discovery zone.
contract FooTest {
    function testWithdraw() public pure returns (bool) {
        return true;
    }
}
