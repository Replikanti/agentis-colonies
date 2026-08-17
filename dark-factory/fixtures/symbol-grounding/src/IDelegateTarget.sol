// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// The delegatecall-style extension point the singleton routes accounting through. An interface's external
// function signatures are prime grounding targets -- the harness composes calls across the system via them.
interface IDelegateTarget {
    function onSettle(uint256 poolKind) external;
    function previewAccrual(uint256 shares) external view returns (uint256 assets);
}
