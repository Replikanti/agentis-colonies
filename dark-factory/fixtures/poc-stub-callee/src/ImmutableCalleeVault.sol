// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SETTABILITY), hardened to the #2175 review repro: the CALLEE address (`oracle`) is
// `immutable` (deploy-time only, no role can repoint it), but the contract ALSO carries a routine UNRELATED
// setter (`setTreasury`) and an unrelated mutable address (`treasury`) — exactly what every real target has.
// A file-level settability check would trip on those and fabricate a finding; the callee-specific gate ties
// settability to `oracle` itself, so stub_eligible() MUST be 0 here regardless of the unrelated setter.

interface IOracle {
    function price() external view returns (uint256);
}

contract ImmutableCalleeVault {
    address public owner;
    address public immutable oracle;   // the CALLEE — immutable, NOT attacker-repointable
    address public treasury;           // unrelated mutable address (a routine config knob)
    mapping(address => uint256) public shares;

    constructor(address o) {
        owner = msg.sender;
        oracle = o;
    }

    // Unrelated setter — must NOT make the immutable `oracle` callee look settable.
    function setTreasury(address newTreasury) external {
        require(msg.sender == owner, "only owner");
        treasury = newTreasury;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = IOracle(oracle).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
    }
}
