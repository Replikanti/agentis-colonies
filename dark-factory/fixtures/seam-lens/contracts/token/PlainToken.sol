// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// NEGATIVE CONTROL: a self-contained ERC20-style token with NO integration into a second protocol — a plain
// name (no *Adapter/*Guard/*Oracle/*Wrapper/*Router/*Strategy suffix) and no external-protocol import. The
// zone-mapper's C15 detection rule must NOT tag this zone, and its brief must carry no seam hunt guide.
contract PlainToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}
