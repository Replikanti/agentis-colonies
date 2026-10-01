// SPDX-License-Identifier: MIT
// A synthetic fixture for the scope-assumptions demo. It describes no real protocol.
pragma solidity ^0.8.20;

interface IAsset {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract Wrapper {
    IAsset public immutable asset;
    mapping(address => uint256) public shares;

    constructor(IAsset asset_) {
        asset = asset_;
    }

    function wrap(uint256 amount) external {
        asset.transferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += amount;
    }

    function unwrap(uint256 amount) external {
        shares[msg.sender] -= amount;
        asset.transfer(msg.sender, amount);
    }
}
