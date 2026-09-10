// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE via MULTI-LINE interface->impl), the #2176 review repro: the callee address (`feed`)
// IS settable, and the vault casts to the INTERFACE `IPriceFeed`. An in-scope implementer exists, but its
// inheritance list is spread across MULTIPLE lines (base on a different line than `contract <Name> is`) — the
// shape a line-oriented grep misses. The formatting-robust (grep -z, header-up-to-`{`) resolver must still see
// `IPriceFeed` as a base, keep the callee IN-scope, and yield stub_eligible = 0 (NO fabricated finding).

interface IPriceFeed {
    function price() external view returns (uint256);
}

abstract contract Ownable {
    address internal _owner;
}

contract ChainlinkPriceFeed is
    Ownable,
    IPriceFeed
{
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract MultiLineImplCalleeVault {
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
