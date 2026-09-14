// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// Generic paired-operation vault over an external pool. Protocol-agnostic on purpose: no real product,
// protocol or token name appears anywhere, and these comments describe ONLY the code, never the gate that
// consumes it (a fixture that narrates the test it is fed to teaches the model the expected answer).
//
// Shape: a round trip whose two legs disagree about one literal flag. enterPool() passes the flag one way,
// exitPool() hardcodes it the other way. Both legs are guarded, CEI-ordered and unprivileged by design, so a
// pass that only looks for reentrancy or a missing role check walks straight past the asymmetry.

interface IPool {
    function join(uint256 amount, bool wrapNative) external returns (uint256 shares);
    function exit(uint256 shares, bool wrapNative) external returns (uint256 amount);
}

contract PairedPoolVault {
    IPool public immutable pool;

    mapping(address => uint256) public shareOf;

    uint256 public totalShares;

    constructor(IPool poolAddress) {
        pool = poolAddress;
    }

    // Entry leg: the pool is told NOT to wrap, so it receives the plain representation.
    function enterPool(uint256 amount) external returns (uint256 shares) {
        shares = pool.join(amount, false);
        shareOf[msg.sender] = shareOf[msg.sender] + shares;
        totalShares = totalShares + shares;
        return shares;
    }

    // Exit leg: the same literal flag is hardcoded the OTHER way round.
    function exitPool(uint256 shares) external returns (uint256 amount) {
        require(shareOf[msg.sender] >= shares, "insufficient shares");
        shareOf[msg.sender] = shareOf[msg.sender] - shares;
        totalShares = totalShares - shares;
        amount = pool.exit(shares, true);
        return amount;
    }
}
