// SPDX-License-Identifier: MIT
// MockAggregatorV3 — Chainlink `AggregatorV3Interface`-shaped price feed for generated invariant harnesses
// (#1794). Dependency-free by contract: it imports NOTHING, so it always compiles inside a bare Foundry project
// with zero remappings (the environment run-invariant-hunt.sh stages it into).
//
// Defaults are FRESH and SANE so a harness that only does `new MockAggregatorV3(8, 1e8)` already satisfies a
// target's staleness/positivity checks: `_updatedAt == 0` means "always fresh" (latestRoundData reports the
// current block timestamp). Staleness is an EXPLICIT act — `setStale(age)` or `setUpdatedAt(ts)` — which is what
// the oracle lens's STALE-vs-FRESH parity relation needs.
//
// `pragma >=0.8.0` (not `^0.8.20`) on purpose: the mock must compile under whatever 0.8.x the STAGED TARGET
// project pins, and it uses no post-0.8.0 language feature (no custom errors, no `string.concat`, no UDVTs).
pragma solidity >=0.8.0;

contract MockAggregatorV3 {
    uint8 private _decimals;
    int256 private _answer;
    uint80 private _roundId;
    uint80 private _answeredInRound;
    uint256 private _startedAt;
    // 0 = "always fresh" (report block.timestamp); non-zero = a pinned, possibly stale, timestamp.
    uint256 private _updatedAt;
    string private _description;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
        _roundId = 1;
        _answeredInRound = 1;
        _startedAt = block.timestamp;
        _updatedAt = 0;
        _description = "MockAggregatorV3";
    }

    // --- AggregatorV3Interface reads -----------------------------------------------------------------------

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external view returns (string memory) {
        return _description;
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function latestAnswer() external view returns (int256) {
        return _answer;
    }

    function latestTimestamp() external view returns (uint256) {
        return _effectiveUpdatedAt();
    }

    function latestRound() external view returns (uint256) {
        return uint256(_roundId);
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _startedAt, _effectiveUpdatedAt(), _answeredInRound);
    }

    function getRoundData(uint80 roundId_)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (roundId_, _answer, _startedAt, _effectiveUpdatedAt(), _answeredInRound);
    }

    // --- Harness-side setters ------------------------------------------------------------------------------

    function setDecimals(uint8 decimals_) external {
        _decimals = decimals_;
    }

    /// Move the price. Bumps the round so a target that requires a MONOTONE round id still accepts the read.
    function setAnswer(int256 answer_) external {
        _answer = answer_;
        _roundId = _roundId + 1;
        _answeredInRound = _roundId;
        _startedAt = block.timestamp;
    }

    /// Pin `updatedAt` to an absolute timestamp. Pass 0 to go back to "always fresh".
    function setUpdatedAt(uint256 updatedAt_) external {
        _updatedAt = updatedAt_;
    }

    /// Report the answer as `age` seconds old (the STALE read the oracle lens perturbs with).
    function setStale(uint256 age) external {
        _updatedAt = block.timestamp > age ? block.timestamp - age : 1;
    }

    /// Report a round that never completed (`answeredInRound < roundId`) — the other staleness shape.
    function setIncompleteRound() external {
        _roundId = _roundId + 1;
        _answeredInRound = _roundId - 1;
    }

    function setRound(uint80 roundId_, uint80 answeredInRound_) external {
        _roundId = roundId_;
        _answeredInRound = answeredInRound_;
    }

    function _effectiveUpdatedAt() private view returns (uint256) {
        return _updatedAt == 0 ? block.timestamp : _updatedAt;
    }
}
