// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// INSECURE — missing access control on a privileged state-changing function.
/// `setOwner()` is meant to be owner-only but carries NO `onlyOwner` check, so any caller can
/// seize ownership and then drain the vault through the (correctly) owner-gated `withdraw()`.
/// The EVM analog of a Solana MissingSignerCheck: a privileged action reachable by an
/// unauthorized caller. The money is real and a working PoC pays the Immunefi severity tier.
contract AccessControlVaultInsecure {
    address public owner;

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function deposit() external payable {}

    // BUG: no access-control check — any caller can take ownership.
    function setOwner(address newOwner) external {
        owner = newOwner;
    }

    function withdraw(uint256 amount) external onlyOwner {
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "send failed");
    }

    receive() external payable {}
}
