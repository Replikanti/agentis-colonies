// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// INSECURE — unchecked low-level call. `withdraw()` zeroes the caller's recorded balance
/// FIRST (so it is NOT a reentrancy/CEI bug) and only THEN sends the ETH with a low-level
/// `.call`, but it IGNORES the returned success bool. If the transfer fails (the recipient
/// reverts, or runs out of gas), the contract has already debited the user's balance yet kept
/// the ETH — the funds are silently lost / stuck and the accounting no longer matches the
/// actual transfer outcome. The EVM analog of a Medium: a failed external call is trusted as
/// if it succeeded. Distinct from Reentrancy (effect precedes interaction here) — the single
/// signal is the discarded return value of `.call`.
contract UncheckedCallVaultInsecure {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "no balance");
        balanceOf[msg.sender] = 0; // EFFECT before interaction — not a reentrancy bug
        // BUG: the success bool of the low-level call is discarded. A failed send leaves the
        // user debited but unpaid, and the contract proceeds as if the transfer succeeded.
        msg.sender.call{value: bal}("");
    }

    receive() external payable {}
}
