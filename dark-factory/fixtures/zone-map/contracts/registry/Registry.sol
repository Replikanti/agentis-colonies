// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Registry
/// @notice #1834 fixture: a small allowlist registry carrying every phantom-name-producing shape from the
///         issue in one file, padded past LOC_SLICE_THRESHOLD (120 lines) so map-zones.sh's fn_names()
///         actually engages on it (files at/under the threshold are fed to the hunter whole, un-sliced).
///         Kept to 3 real declared functions (setAllowed, isAllowed, renounceOwnership) plus the three
///         phantom-producing shapes, in its own file/zone so this fixture never interacts with the
///         FN_SLICE_CAP=16 reorder/truncation machinery contracts/liquidation/Liquidation.sol already pins
///         for #1701/#1799/#1825. Generic, public-safe -- no real protocol, no real access-control soundness.
contract Registry {
    address public owner;
    mapping(address => bool) public allowed;

    event AllowedSet(address indexed who, bool ok);
    event OwnershipRenounced(address indexed previousOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    // ------------------------------------------------------------------------------------------------
    // Shape 1 (#1834): NatSpec prose using the ordinary English word "function" directly above a real
    // declaration. The old unanchored `\bfunction\s+([A-Za-z0-9_]+)` regex scraped the WORD FOLLOWING
    // "function" in each line below as a phantom function name -- "which" from the @notice line, "to"
    // from the @dev line -- burning two slice slots on English prose, never real declarations. The
    // anchored regex requires the line to START (after only leading whitespace) with `function NAME(`,
    // so NatSpec prose never matches regardless of which English word follows "function" in it.
    // ------------------------------------------------------------------------------------------------
    /// @notice Internal function which performs the allowlist toggle for a single address.
    /// @dev Internal function to update the allowed mapping and emit the AllowedSet event.
    function setAllowed(address who, bool ok) external onlyOwner {
        allowed[who] = ok;
        emit AllowedSet(who, ok);
    }

    // ------------------------------------------------------------------------------------------------
    // Shape 2 (#1834): a commented-out OLD declaration living on a `//` line directly above the current
    // declaration. The old regex matched the word after "function" inside the comment too (here it would
    // have scraped "legacyIsAllowed" itself, which happens to look like a real name -- the issue's
    // original report also covers dead-code comments like `// function decimals()` where the scraped
    // name shadows or displaces a real one). The anchored regex still matches `^\s*function\s+NAME\s*\(`
    // on this line because a leading `//` is not stripped before the regex runs -- but `//` is not
    // whitespace, so `^\s*function` never matches a `//`-prefixed line. Zero phantom from this shape.
    // ------------------------------------------------------------------------------------------------
    // function legacyIsAllowed(address who) external view returns (bool) { return allowed[who]; }
    function isAllowed(address who) external view returns (bool) {
        return allowed[who];
    }

    function renounceOwnership() external onlyOwner {
        address previousOwner = owner;
        owner = address(0);
        emit OwnershipRenounced(previousOwner);
    }

    // ------------------------------------------------------------------------------------------------
    // Padding (#1834): filler lines with no load-bearing content beyond the LOC count, pushing this file
    // past LOC_SLICE_THRESHOLD (120) so map-zones.sh's fn_names()/prioritize_fn_names() slicing path is
    // actually exercised for this zone (an un-sliced file below the threshold is emitted whole, which
    // would not exercise the phantom-name regression this fixture targets).
    // ------------------------------------------------------------------------------------------------
    // padding line 01
    // padding line 02
    // padding line 03
    // padding line 04
    // padding line 05
    // padding line 06
    // padding line 07
    // padding line 08
    // padding line 09
    // padding line 10
    // padding line 11
    // padding line 12
    // padding line 13
    // padding line 14
    // padding line 15
    // padding line 16
    // padding line 17
    // padding line 18
    // padding line 19
    // padding line 20
    // padding line 21
    // padding line 22
    // padding line 23
    // padding line 24
    // padding line 25
    // padding line 26
    // padding line 27
    // padding line 28
    // padding line 29
    // padding line 30
    // padding line 31
    // padding line 32
    // padding line 33
    // padding line 34
    // padding line 35
    // padding line 36
    // padding line 37
    // padding line 38
    // padding line 39
    // padding line 40

    // ------------------------------------------------------------------------------------------------
    // Shape 3 (#1834): a declaration living inside a `/* ... */` block comment. This is the ACCEPTED,
    // DOCUMENTED residual -- fn_names() is a one-pass-per-line scraper with no lexer, so it has no
    // comment-state tracking and cannot tell a `/* */` block from real code. The anchored regex still
    // matches `oldSetAllowedBatch` on the line below because, taken alone, that line starts with
    // `function NAME(` after leading whitespace -- the regex has no way to know it sits inside a block
    // comment that opened several lines above. Out of scope for #1834 (see the plan's Out-of-scope
    // section): tracking `/* */` state is a materially bigger, riskier change for a residual that is
    // empirically absent from the sampled corpus-bench targets (0 hits across 263 .sol files). Pinned as
    // PRESENT (not absent) by demo-map-zones.sh block (1f), so the gap stays a conscious, pinned decision.
    // ------------------------------------------------------------------------------------------------
    /*
    function oldSetAllowedBatch(address[] memory who, bool ok) external onlyOwner {
        for (uint256 i = 0; i < who.length; i++) {
            allowed[who[i]] = ok;
            emit AllowedSet(who[i], ok);
        }
    }
    */
}
