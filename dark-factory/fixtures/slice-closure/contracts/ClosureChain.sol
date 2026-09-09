// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2150 fixture for auditor/slice-fns.sh's same-file callee closure.
//
// The shape the closure exists for: the only EXTERNAL entry point does nothing interesting itself. It
// delegates to an internal helper, which delegates to a second internal helper, and only THAT one reaches
// out of the contract. A slice of the entry point alone therefore shows a reader (human or detector) a
// contract with no external call in it at all.
//
// Deliberate properties, each pinned by demo-slice-closure.sh:
//   entry        external, the only requested name.
//   _a           internal, hop 1 — must appear at any SLICE_MAX_DEPTH >= 1.
//   _b           internal, hop 2 — must appear at SLICE_MAX_DEPTH >= 2 and must NOT at depth 1.
//   unrelated    external and never called — must never be pulled in (closure is not "add every function").
//   _neverCalled internal but unreachable from entry — must never be pulled in (the closure is call-graph
//                driven, not a visibility sweep).
// The two interfaces sit AFTER the contract so the header the slicer emits (everything up to the first
// `function` line) is the contract declaration and its state variables rather than an interface body.

contract ClosureChain {
    address public owner;
    ICfg public cfg;

    mapping(address => uint256) public balanceOf;

    constructor(address cfgAddress) {
        owner = msg.sender;
        cfg = ICfg(cfgAddress);
    }

    function entry(uint256 amount) external {
        _a(amount);
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
    }

    function _a(uint256 amount) internal {
        if (amount == 0) {
            return;
        }
        _b(amount);
    }

    function _b(uint256 amount) internal {
        // The external call the entry-point slice never showed: the target is whatever the config
        // contract returns at call time.
        IThing(cfg.get()).ping(amount);
        if (amount > 1) {
            IThing(cfg.get()).ping(amount - 1);
        }
        if (amount > 2) {
            IThing(cfg.get()).ping(amount - 2);
        }
        if (amount > 3) {
            IThing(cfg.get()).ping(amount - 3);
        }
    }

    function unrelated(uint256 amount) external view returns (uint256) {
        return balanceOf[msg.sender] + amount;
    }

    function _neverCalled(uint256 amount) internal pure returns (uint256) {
        return amount + 1;
    }
}

interface ICfg {
    function get() external view returns (address);
}

interface IThing {
    function ping(uint256 amount) external;
}
