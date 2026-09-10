// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE with a `/*` inside a STRING LITERAL), the #2176 round-5 review path: the callee
// (`feed`) IS settable and cast to `IPriceFeed`. An in-scope contract implements IPriceFeed, but BEFORE that
// declaration a string literal contains the two chars `/*`. A comment-stripping pass would (wrongly) treat that
// `/*` as opening a block comment and eat the real `contract ... is IPriceFeed` carrier that follows, fabricating
// a stub against an in-scope callee. Matching RAW text (no comment stripping) sees the real carrier regardless,
// so the callee stays IN-scope and stub_eligible = 0.

interface IPriceFeed {
    function price() external view returns (uint256);
}

contract Note {
    // The `/*` below lives inside a Solidity STRING, not a comment. Raw-text matching is immune to it.
    string public label = "price feed adapter /* v2";
}

contract StringSlashFeed is IPriceFeed {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract StringSlashImplCalleeVault {
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
        uint256 p = IPriceFeed(feed).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
    }
}
