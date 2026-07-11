// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A `*Router*Guard` wrapper around an external aggregator swap. The guard is the target's OWN integration
// code: it must bound slippage on the cross-protocol call so a manipulated route cannot extract value.
// If the min-out is checked against a pre-fee gross while the user receives the post-fee net, protection
// silently weakens across the seam. Generic, public-safe illustration.
import {IAggregationRouterV5} from "@1inch/router/contracts/interfaces/IAggregationRouterV5.sol";

contract OneInchRouterGuard {
    IAggregationRouterV5 public immutable router;

    constructor(address _router) {
        router = IAggregationRouterV5(_router);
    }

    function guardedSwap(bytes calldata data, uint256 minOut) external returns (uint256 out) {
        out = router.swap(data);
        require(out >= minOut, "slippage");
    }
}
