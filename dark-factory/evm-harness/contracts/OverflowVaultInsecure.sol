// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// INSECURE — an explicit `unchecked { ... }` block defeats solc 0.8's built-in overflow checks
/// on a value-carrying balance. `transfer()` debits the sender and credits the recipient inside
/// `unchecked`, so a sender who moves MORE than they hold underflows their balance to a near-max
/// `uint256` (≈ minting tokens from nothing) instead of reverting. The total supply invariant is
/// broken. The EVM analog of a Medium: arithmetic that wraps/underflows on balances. No external
/// call and no access-control gate — the single signal is the `unchecked` wrap on a balance.
contract OverflowVaultInsecure {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    constructor() {
        balanceOf[msg.sender] = 1000;
        totalSupply = 1000;
    }

    function transfer(address to, uint256 amount) external {
        // BUG: `unchecked` disables the underflow guard — debiting more than the balance wraps
        // the sender to a huge value rather than reverting, conjuring tokens out of thin air.
        unchecked {
            balanceOf[msg.sender] -= amount;
            balanceOf[to] += amount;
        }
    }
}
