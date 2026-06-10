// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// INSECURE — classic reentrancy (checks-effects-interactions violation).
/// `withdraw()` sends ETH to the caller BEFORE zeroing its recorded balance, so a
/// malicious receiver can re-enter `withdraw()` during the `call` and drain the whole
/// vault — far beyond its own deposit. The EVM analog of a low-duplicate High: the
/// money is real, deployed, and a working PoC pays the full Immunefi severity tier.
contract ReentrancyVaultInsecure {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "no balance");
        (bool ok, ) = msg.sender.call{value: bal}(""); // INTERACTION before EFFECT
        require(ok, "send failed");
        balanceOf[msg.sender] = 0; // EFFECT after the external call — too late
    }

    receive() external payable {}
}
