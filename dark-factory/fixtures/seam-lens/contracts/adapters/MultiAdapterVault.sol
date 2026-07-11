// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Generic ERC4626-style vault that routes deposits through pluggable adapters into a SECOND protocol.
// The integration seam: totalAssets() sums each adapter's reported balance, but the value actually held
// after the external round-trip may diverge — a mispriced share is theft. Public-safe, illustrative only.
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";

interface IAdapter {
    function reportedAssets() external view returns (uint256);
    function withdrawTo(address to, uint256 amount) external returns (uint256);
    function supply(uint256 amount) external;
}

contract MultiAdapterVault {
    IAdapter[] public adapters;
    mapping(address => uint256) public shares;
    uint256 public totalShares;

    function totalAssets() public view returns (uint256 sum) {
        for (uint256 i = 0; i < adapters.length; i++) {
            sum += adapters[i].reportedAssets();
        }
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 ta = totalAssets();
        return ta == 0 ? assets : (assets * totalShares) / ta;
    }

    function deposit(uint256 assets, uint256 index) external returns (uint256 minted) {
        minted = convertToShares(assets);
        adapters[index].supply(assets);
        shares[msg.sender] += minted;
        totalShares += minted;
    }

    function withdraw(uint256 shareAmount, uint256 index) external returns (uint256 assets) {
        uint256 ta = totalAssets();
        assets = (shareAmount * ta) / totalShares;
        shares[msg.sender] -= shareAmount;
        totalShares -= shareAmount;
        adapters[index].withdrawTo(msg.sender, assets);
    }
}
