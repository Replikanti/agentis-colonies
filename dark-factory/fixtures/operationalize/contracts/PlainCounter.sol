// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// The minimal control zone: no external call, no numeric conversion, no assumption about another protocol,
// one trivial state transition. Like its sibling, these comments describe only the code — never the gate
// that consumes it — so nothing here can hand a model the answer it is being measured on.

contract PlainCounter {
    uint256 public count;

    function increment() external {
        count = count + 1;
    }

    function currentCount() external view returns (uint256) {
        return count;
    }
}
