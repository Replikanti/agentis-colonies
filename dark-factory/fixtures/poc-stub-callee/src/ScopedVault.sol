// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171/#2179 fixture (NEGATIVE arm — ADMIN-GUARDED setter). The callee address is a mutable state variable and
// its interface (`IOracle`) is out-of-scope (only DECLARED here, never IMPLEMENTED in scope), but the setter is
// gated by an inline `require(msg.sender == owner, "only owner")`, so repointing the callee is an OWNER/admin
// action, NOT an attacker one. Under #2179 an admin-upgradeable callee is NOT attacker-repointable, so the gate
// must SUPPRESS the stub here -> `suppressed:admin-or-unprovable` (it armed pre-#2179 — that was the over-
// assumption #2179 fixes). PermissionlessCalleeVault is the positive (armed) arm; this is the owner-guarded
// mirror, and RoleGuardedCalleeVault covers the modifier-guarded variant.

interface IOracle {
    function price() external view returns (uint256);
}

contract ScopedVault {
    address public owner;
    address public oracle;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    constructor(address initialOracle) {
        owner = msg.sender;
        oracle = initialOracle;
    }

    function setOracle(address newOracle) external {
        require(msg.sender == owner, "only owner");
        oracle = newOracle;
    }

    // Credits shares straight from the callee's returned price BEFORE any bound/validation: a hostile oracle
    // returning an inflated value over-credits shares (a return-value hazard).
    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = IOracle(oracle).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
        totalShares = totalShares + minted;
    }
}
