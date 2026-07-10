// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A price-feed oracle fixture for the zone-map demo (integrity + decimals-scaling surface).
contract Oracle {
    address public admin;
    uint8 public decimals = 8;
    uint256 private _price;
    uint256 public updatedAt;

    constructor() {
        admin = msg.sender;
    }

    function setPrice(uint256 price) external {
        require(msg.sender == admin, "not admin");
        _price = price;
        updatedAt = block.timestamp;
    }

    function latestPrice() external view returns (uint256) {
        require(block.timestamp - updatedAt < 1 hours, "stale");
        return _price;
    }

    function scaleTo(uint256 targetDecimals) external view returns (uint256) {
        if (targetDecimals >= decimals) {
            return _price * (10 ** (targetDecimals - decimals));
        }
        return _price / (10 ** (decimals - targetDecimals));
    }
}
