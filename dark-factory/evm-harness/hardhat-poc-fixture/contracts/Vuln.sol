// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Vuln — a deliberately vulnerable bank used ONLY as the offline hardhat-poc fixture target (#1507).
// The bug: withdraw() sends ETH BEFORE zeroing the balance (a classic re-entrancy), so a malicious
// receiver can re-enter withdraw() and drain more than it deposited. The bundled exploit PoC reproduces it.
contract Vuln {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw() external {
        uint256 bal = balanceOf[msg.sender];
        require(bal > 0, "no balance");
        // VULNERABILITY: external call before state update -> re-entrancy.
        (bool ok, ) = msg.sender.call{value: bal}("");
        require(ok, "send failed");
        balanceOf[msg.sender] = 0;
    }

    receive() external payable {}
}
