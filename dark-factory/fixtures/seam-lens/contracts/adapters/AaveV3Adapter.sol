// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A `*Adapter` module whose only job is to call INTO a second lending protocol. The seam auditors on
// either side do not own: this repo's authors trust the pool, the pool's auditors never see this glue.
// reportedAssets() trusts the external aToken balance verbatim — the mis-accounting surface. Illustrative.
import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AaveV3Adapter {
    IPool public immutable pool;
    IERC20 public immutable aToken;

    constructor(address _pool, address _aToken) {
        pool = IPool(_pool);
        aToken = IERC20(_aToken);
    }

    function reportedAssets() external view returns (uint256) {
        // Trusts the external protocol's balance report across the integration boundary.
        return aToken.balanceOf(address(this));
    }

    function supply(uint256 amount) external {
        pool.supply(address(aToken), amount, address(this), 0);
    }

    function withdrawTo(address to, uint256 amount) external returns (uint256) {
        return pool.withdraw(address(aToken), amount, to);
    }
}
