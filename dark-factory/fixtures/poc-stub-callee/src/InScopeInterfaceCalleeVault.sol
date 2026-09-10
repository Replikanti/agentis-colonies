// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE via INTERFACE->IMPL), hardened to the #2175 review repro: the callee address (`feed`)
// IS settable (owner-only setter + mutable address state), and the vault casts to the INTERFACE `IPriceFeed`
// (the realistic CALLEE-VECTOR shape), NOT to a concrete contract name. But an in-scope `contract
// ChainlinkPriceFeed is IPriceFeed` IMPLEMENTS that interface, so the callee's real code IS drivable and the
// ordinary concrete-PoC path applies. A `contract IPriceFeed` grep would miss the differently-named impl and
// wrongly stub; the interface->implementation resolver keeps stub_eligible() = 0 here.

interface IPriceFeed {
    function price() external view returns (uint256);
}

contract ChainlinkPriceFeed is IPriceFeed {
    function price() external pure returns (uint256) {
        return 1;
    }
}

contract InScopeInterfaceCalleeVault {
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
