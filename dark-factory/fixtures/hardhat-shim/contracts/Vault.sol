// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ShareMath} from "./libraries/ShareMath.sol";

/// @notice Foundry-shim fixture (#2277): a minimal share vault in a Hardhat-only project.
contract Vault {
    IERC20 public immutable asset;
    uint256 public totalShares;
    mapping(address => uint256) public shares;

    constructor(IERC20 asset_) {
        asset = asset_;
    }

    function deposit(uint256 amount) external {
        uint256 minted = ShareMath.toShares(amount, totalShares, asset.balanceOf(address(this)));
        require(asset.transferFrom(msg.sender, address(this), amount), "transfer");
        shares[msg.sender] += minted;
        totalShares += minted;
    }

    function withdraw(uint256 shareAmount) external {
        uint256 amount = ShareMath.toAssets(shareAmount, totalShares, asset.balanceOf(address(this)));
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        require(asset.transfer(msg.sender, amount), "transfer");
    }
}
