// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IDelegateTarget} from "./IDelegateTarget.sol";
import {MathLib} from "./MathLib.sol";

// Models the failing shape: a SINGLETON value-custody vault (Balancer V3 Vault-style) that routes accounting
// through a delegatecall target and a math library. The symbol grounder must surface the REAL contract /
// interface / library / struct / enum names + external/public signatures so the generated harness does not
// reference a hallucinated identifier (the Error 7920 that survived all repair rounds).
contract Singleton {
    using MathLib for uint256;

    // A struct TYPE the harness may need to construct -- must be in the inventory.
    struct Position {
        uint256 shares;
        uint256 debt;
        address owner;
    }

    // An enum TYPE -- also a groundable identifier.
    enum PoolKind {
        Weighted,
        Stable
    }

    mapping(address => Position) internal positions;
    uint256 public totalManagedAssets;

    // external / public functions the grounded harness is allowed to call.
    function deposit(uint256 amount, address to) external returns (uint256 shares) {
        shares = amount;
        positions[to].shares += shares;
        totalManagedAssets += amount;
    }

    function withdraw(uint256 shares) external returns (uint256 amount) {
        amount = shares;
        positions[msg.sender].shares -= shares;
        totalManagedAssets -= amount;
    }

    function settle(IDelegateTarget target, PoolKind kind) public {
        target.onSettle(kind == PoolKind.Stable ? 1 : 0);
    }

    // an internal helper -- deliberately NOT in the external/public inventory.
    function _accrue(uint256 x) internal view returns (uint256) {
        return x.scaleUp();
    }
}
