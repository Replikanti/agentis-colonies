// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// SECURE — the access-control check is restored. `setOwner()` carries the `onlyOwner`
/// modifier, so a non-owner's attempt to seize ownership reverts and the owner-gated
/// `withdraw()` stays unreachable to an attacker. This is the control that proves the
/// two-sided gate is not a rigged always-fire harness: the legitimate owner is still
/// accepted, only the unauthorized caller is rejected.
contract AccessControlVaultSecure {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function deposit() external payable {}

    // FIX: gated by onlyOwner — a non-owner cannot take ownership.
    function setOwner(address newOwner) external onlyOwner {
        owner = newOwner;
    }

    function withdraw(uint256 amount) external onlyOwner {
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
    }

    receive() external payable {}
}
