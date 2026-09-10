// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE with a comment-brace in the header), the #2176 review path 2: the callee (`feed`) IS
// settable and cast to `IPriceFeed`. An in-scope implementer exists, but its multi-line inheritance list carries
// an inline comment CONTAINING `{` and `}` braces. A `[^{]*` header span that scanned raw source would truncate
// at the comment brace BEFORE reaching the real `IPriceFeed` base and fabricate a stub. Stripping comments before
// matching keeps the base visible, so the callee stays IN-scope and stub_eligible = 0.

interface IPriceFeed {
    function price() external view returns (uint256);
}

abstract contract Ownable {
    address internal _owner;
}

contract CommentBraceFeed is
    Ownable, // this comment has { and } braces that must not truncate the header
    IPriceFeed
{
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract CommentBraceImplCalleeVault {
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
