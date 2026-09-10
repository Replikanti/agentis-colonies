// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE): the callee address is settable (owner-only setter + mutable address state), but
// the callee TYPE `PriceFeed` is IMPLEMENTED IN SCOPE (a `contract PriceFeed` body below), so its real code IS
// drivable and the ordinary concrete-PoC path applies. stub_eligible() MUST be 0 here (callee_out_of_scope is
// false), so no hostile stub is synthesized -> no fabricated finding on an in-scope callee.

contract PriceFeed {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract InScopeCalleeVault {
    address public owner;
    address public feed;
    mapping(address => uint256) public shares;

    constructor(address f) {
        owner = msg.sender;
        feed = f;
    }

    function setFeed(address newFeed) external {
        require(msg.sender == owner, "only owner");
        feed = newFeed;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = PriceFeed(feed).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
    }
}
