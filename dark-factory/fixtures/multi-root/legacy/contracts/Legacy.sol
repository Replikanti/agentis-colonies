// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice Multi-root fixture (#2255): the `legacy` Hardhat project (no foundry.toml).
contract Legacy {
    mapping(address => uint256) public balances;

    function deposit() external payable {
        balances[msg.sender] += msg.value;
    }
}
