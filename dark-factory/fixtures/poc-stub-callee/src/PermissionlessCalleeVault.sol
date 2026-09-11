// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2179 fixture (POSITIVE arm) for poc-writer.ag's hostile-stub-callee gate.
//
// The vault reads a price from an oracle whose ADDRESS is a mutable state variable, and it uses the returned
// value to CREDIT shares. The decisive property (#2179): `setOracle(address)` is an UNGUARDED `external`
// function — NO owner check, no role modifier — so ANYONE can repoint the callee. That is an ATTACKER repoint,
// not an admin/governance one. Combined with the callee's interface (`IOracle`) being only DECLARED here and
// never IMPLEMENTED in scope, this is exactly the Royco MaliciousOracle idiom: an attacker deploys a mock
// implementing IOracle, repoints `oracle` at it via the open setter, and over-credits shares on the return.
//
// MUST make stub_class() return `armed` for the callee-expr `IOracle(oracle)`: the interface-typed call is
// out-of-scope (no in-scope implementer) AND the backing `oracle` is a mutable address written by an UNGUARDED
// external setter (attacker-repointable). This is the arm that keeps the gate from silently degrading into
// "never arms".

interface IOracle {
    function price() external view returns (uint256);
}

contract PermissionlessCalleeVault {
    address public oracle;

    mapping(address => uint256) public shares;
    uint256 public totalShares;

    constructor(address initialOracle) {
        oracle = initialOracle;
    }

    // UNGUARDED: any caller can repoint the settable callee -> an ATTACKER repoint, not an admin one.
    function setOracle(address newOracle) external {
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
