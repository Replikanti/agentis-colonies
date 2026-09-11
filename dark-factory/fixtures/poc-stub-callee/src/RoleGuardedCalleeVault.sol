// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2179 fixture (NEGATIVE arm — MODIFIER-style privilege). The callee address is a mutable state var and its
// type (`IOracle`) is out-of-scope (no in-scope implementer), but the setter is guarded by a ROLE modifier
// (`onlyRole(ADMIN_ROLE)`), so repointing the callee is an ADMIN/governance action, NOT an attacker one. The
// #2179 gate must read the modifier guard as privileged and SUPPRESS the stub -> `suppressed:admin-or-unprovable`.
// (ScopedVault covers the inline `require(msg.sender == owner)` style; this covers the modifier style.)

interface IOracle {
    function price() external view returns (uint256);
}

contract RoleGuardedCalleeVault {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    address public oracle;
    mapping(bytes32 => mapping(address => bool)) public roles;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    modifier onlyRole(bytes32 role) {
        require(roles[role][msg.sender], "missing role");
        _;
    }

    constructor(address initialOracle) {
        oracle = initialOracle;
        roles[ADMIN_ROLE][msg.sender] = true;
    }

    // GUARDED by a role modifier: only an ADMIN can repoint the callee -> governance, not attacker-repointable.
    function setOracle(address newOracle) external onlyRole(ADMIN_ROLE) {
        oracle = newOracle;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = IOracle(oracle).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
        totalShares = totalShares + minted;
    }
}
