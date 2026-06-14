// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {Ledger} from "../src/Ledger.sol";

// COUNTEREXAMPLE spec: the same conservation invariant asserted against the
// buggy `transferBuggy`. Halmos finds the concrete input that violates it (any
// case where `amount == from` mints value, e.g. from = to = amount = some
// non-zero value), prints a `Counterexample:` block + `[FAIL]`, and the summary
// reports `1 failed`. The gate returns COUNTEREXAMPLE (exit 1): a real bug with
// a concrete witness, not a maybe.
contract LedgerCounterexampleTest {
    Ledger internal ledger;

    function setUp() public {
        ledger = new Ledger();
    }

    // Same invariant as the PROVED spec, but the buggy implementation breaks it
    // on the `amount == from` path, so Halmos refutes it with a witness.
    function check_conservation(uint8 from, uint8 to, uint8 amount) public {
        uint16 before = uint16(from) + uint16(to);
        (uint8 fromOut, uint8 toOut) = ledger.transferBuggy(from, to, amount);
        uint16 afterTotal = uint16(fromOut) + uint16(toOut);
        assert(afterTotal == before);
    }
}
