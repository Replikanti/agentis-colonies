// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PermissionlessCalleeVault} from "../src/PermissionlessCalleeVault.sol";

// #2171/#2179 fail-before control: an HONEST in-scope-behaving oracle credits shares 1:1, so the return-value
// over-credit does NOT reproduce -> this test FAILS its exploit assertion -> the gate scores CLEAN. No hostile
// stub, no finding. Runs against the POSITIVE (armed) arm PermissionlessCalleeVault — the contract the #2179
// gate actually arms. (No forge-std: plain require, self-contained.)
contract HonestOracle {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract PocPermissionlessControl {
    function test_control() external {
        HonestOracle honest = new HonestOracle();
        PermissionlessCalleeVault vault = new PermissionlessCalleeVault(address(honest));
        uint256 amount = 1000;
        uint256 minted = vault.deposit(amount);
        // Exploit = the callee over-credits shares. An honest oracle credits 1:1, so this MUST NOT hold.
        require(minted > amount, "over-credit exploit reproduced");
    }
}
