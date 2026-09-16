// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "ext-rate-lib/src/IRateSource.sol";

/// @title Consumer
/// @notice Reads an external rate and an external quote before it prices a position.
/// @dev The registry this contract queries is maintained upstream at
///      https://github.com/example-org/ext-registry — see UpstreamRegistry there for the
///      canonical accounting rules; ExternalQuoteSource is the deployed quote reader.
contract Consumer {
    IRateSource public immutable rateSource;
    address public quoteSource;

    constructor(IRateSource rateSource_, address quoteSource_) {
        rateSource = rateSource_;
        quoteSource = quoteSource_;
    }

    function priceOf(address asset) external view returns (uint256) {
        // Assumes the rate is 1e18-scaled for every asset. Whether that holds is a fact about
        // IRateSource, not about this file.
        return rateSource.rate(asset);
    }
}
