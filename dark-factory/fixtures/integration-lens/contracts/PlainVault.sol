// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2191 fixture (negative arm) for hunter.ag's external-integration/oracle-assumption detector.
//
// Pure in-contract accounting: no external call surface, no oracle/valuation read, no hardcoded call flag,
// no dual asset representation. MUST NOT trip has_external_integration_surface() — the directive is therefore
// "" and the hunt prompt stays byte-identical to the pre-#2191 one, with no INTEGRATION-LENS| sentinel.

contract PlainVault {
    mapping(address => uint256) public balanceOf;

    function deposit(uint256 amount) external {
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount);
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
    }
}
