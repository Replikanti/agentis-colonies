// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A `*Wrapper` that READS an external price feed and re-exposes it to the protocol — an oracle integration
// seam. The wrapper is the target's own code: staleness/decimals across the boundary are ITS responsibility,
// not the feed's. A mispriced read here mis-prices every downstream share. Generic, public-safe illustration.
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract ChainlinkOracleWrapper {
    AggregatorV3Interface public immutable feed;
    uint256 public constant MAX_STALE = 3600;

    constructor(address _feed) {
        feed = AggregatorV3Interface(_feed);
    }

    function price() external view returns (uint256) {
        (, int256 answer, , uint256 updatedAt, ) = feed.latestRoundData();
        require(answer > 0, "bad price");
        require(block.timestamp - updatedAt <= MAX_STALE, "stale");
        return uint256(answer);
    }
}
