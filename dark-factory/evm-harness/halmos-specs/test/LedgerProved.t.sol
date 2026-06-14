// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

import {Ledger} from "../src/Ledger.sol";

// PROVED spec: Halmos exhaustively proves that the honest `transferSafe`
// conserves total value over ALL symbolic (from, to, amount) inputs. There is
// no input that breaks it, so the summary reports `0 failed` and the gate
// returns PROVED (exit 0). This is a sound proof, not a sampled fuzz run.
contract LedgerProvedTest {
    Ledger internal ledger;

    function setUp() public {
        ledger = new Ledger();
    }

    // For every symbolic input, the sum of the two balances after the transfer
    // equals the sum before it: value is neither created nor destroyed.
    function check_conservation(uint8 from, uint8 to, uint8 amount) public {
        uint16 before = uint16(from) + uint16(to);
        (uint8 fromOut, uint8 toOut) = ledger.transferSafe(from, to, amount);
        uint16 afterTotal = uint16(fromOut) + uint16(toOut);
        assert(afterTotal == before);
    }
}
