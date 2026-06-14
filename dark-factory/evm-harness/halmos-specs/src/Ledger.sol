// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

// A two-account ledger used by the Halmos example specs. `transferSafe` is the
// honest implementation; `transferBuggy` plants a real bug (it credits the
// receiver but forgets to debit the sender on the equal-balance path), so the
// conserved-total invariant no longer holds for some symbolic inputs.
//
// Balances are uint8 so the symbolic search space stays tiny and Halmos returns
// a sound verdict in a couple of seconds. The "value conservation" invariant
// (sender_after + receiver_after == sender_before + receiver_before) is the
// property the specs assert over ALL symbolic inputs.
contract Ledger {
    // Honest transfer: debit sender, credit receiver. Reverts on insufficient
    // funds or on credit overflow, so the post-state always conserves the total.
    function transferSafe(uint8 from, uint8 to, uint8 amount)
        external
        pure
        returns (uint8 fromOut, uint8 toOut)
    {
        require(from >= amount, "insufficient");
        require(uint16(to) + uint16(amount) <= type(uint8).max, "overflow");
        fromOut = from - amount;
        toOut = to + amount;
    }

    // Planted bug: when the transferred amount exactly equals the sender's
    // balance, the sender is NOT debited (the `from - amount` write is skipped),
    // so the conserved-total invariant breaks and value is minted out of thin
    // air. Halmos must surface a concrete (from, to, amount) counterexample.
    function transferBuggy(uint8 from, uint8 to, uint8 amount)
        external
        pure
        returns (uint8 fromOut, uint8 toOut)
    {
        require(from >= amount, "insufficient");
        require(uint16(to) + uint16(amount) <= type(uint8).max, "overflow");
        if (amount == from) {
            fromOut = from; // BUG: should be `from - amount` (i.e. 0)
        } else {
            fromOut = from - amount;
        }
        toOut = to + amount;
    }
}
