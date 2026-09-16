// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Deployment book for the test network. Addresses are invented for the fixture.
contract Deploy {
    address constant RATE_SOURCE = 0x2222222222222222222222222222222222222222; // IRateSource
    // ExternalQuoteSource - the deployed quote reader
    address constant QUOTE_SOURCE = 0x1111111111111111111111111111111111111111;
}
