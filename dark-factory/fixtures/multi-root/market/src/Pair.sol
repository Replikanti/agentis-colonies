// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PairCore} from "./base/PairCore.sol";

/// @notice Multi-root fixture (#2255): the `market` project's concrete Pair — the implementor of PairCore.
contract Pair is PairCore {
    function _settle(uint256 amount) internal override returns (uint256) {
        balance -= amount;
        return amount;
    }
}
