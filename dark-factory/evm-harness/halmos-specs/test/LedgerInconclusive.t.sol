// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.0;

// INCONCLUSIVE spec: a loop bounded by a SYMBOLIC count exceeds Halmos's unroll
// bound, so Halmos cannot fully explore every path. The asserted property is
// actually TRUE, and Halmos reports `0 failed` — but it also warns that "paths
// have not been fully explored due to the loop" (#loop-bound). A `0 failed`
// under incomplete exploration is NOT a sound proof, so the gate MUST return
// INCONCLUSIVE (exit 3), never PROVED. This spec is the soundness regression
// guard for that: if the gate ever mis-reports an under-unrolled loop as PROVED,
// the demo fails.
contract LedgerInconclusiveTest {
    // `s` counts up to `n`; the invariant s == n is true, but the loop runs a
    // symbolic number of times, beyond Halmos's default unroll bound.
    function check_loop_sum(uint256 n) public pure {
        uint256 s = 0;
        for (uint256 i = 0; i < n; i++) {
            s += 1;
        }
        assert(s == n);
    }
}
