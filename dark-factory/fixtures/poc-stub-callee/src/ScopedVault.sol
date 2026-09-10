// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 fixture (positive arm) for poc-writer.ag's hostile-stub-callee gate.
//
// The vault reads a price from an oracle whose ADDRESS is a mutable state variable with an owner-only setter,
// and it uses the returned value to CREDIT shares. Nothing here is privileged-role abuse: the setter behaves
// exactly as documented. The exploitable half is that the CALLEE is whatever `oracle` currently points at, and
// that callee's interface (`IOracle`) is only DECLARED here, never IMPLEMENTED in scope — so the concrete-PoC
// path cannot drive its real code and would refute the vector to CLEAN. Modelled as the Royco MaliciousOracle
// idiom (an attacker-deployed mock injected via the setter) it reproduces as a return-value over-credit.
//
// MUST make stub_eligible() fire for the callee-expr `IOracle(oracle)`: the interface-typed call is out-of-scope
// (only `interface IOracle`, no `contract IOracle` body), and BOTH the `setOracle(address)` setter and the
// mutable `address public oracle;` declaration are settable-target signals.

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
