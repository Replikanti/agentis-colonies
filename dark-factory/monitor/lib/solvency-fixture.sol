// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

/// SolvencyFixture — a MINIMAL, self-test-only fixture for the Dark Factory
/// monitor colony's backtest self-test and live demo (#1889).
///
/// NOT A VULNERABILITY PoC. It models no real protocol and has no security
/// relevance. It exposes exactly one on-chain solvency invariant —
/// `totalSupply() <= totalAssets()` — and a single `mintUnbacked()` lever whose
/// ONLY purpose is to let the self-test / demo deterministically FLIP that
/// invariant to violated on a local anvil chain, so the monitor's
/// invariant-watcher verdict logic can be proven to page on it (a true
/// positive) while a quiet baseline stays clean (no false positives).
///
/// The compiled creation bytecode is committed alongside as
/// `solvency-fixture.bin` (mirroring `evm-harness/contracts/bin/*.bin`), so the
/// self-test and demo need no Solidity compiler at run time. To regenerate the
/// bytecode after editing this file:
///   forge build   # then take out/SolvencyFixture.sol/SolvencyFixture.json .bytecode.object
/// (strip the leading `0x`; commit the raw hex with no trailing newline).
contract SolvencyFixture {
    /// Shares outstanding (the LHS of the watched solvency invariant).
    uint256 public totalSupply;
    /// Assets backing those shares (the RHS).
    uint256 public totalAssets;

    constructor(uint256 supply_, uint256 assets_) {
        totalSupply = supply_;
        totalAssets = assets_;
    }

    /// Mint shares with NO backing assets, pushing `totalSupply()` above
    /// `totalAssets()` so the solvency invariant flips to violated. Self-test
    /// lever only — there is no real accounting here to protect.
    function mintUnbacked(uint256 amount) external {
        totalSupply += amount;
    }
}
