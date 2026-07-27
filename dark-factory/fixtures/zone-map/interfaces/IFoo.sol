// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice #1824 fixture: a pure interface under `interfaces/` — must NOT become a discovery zone.
interface IFoo {
    function withdraw(uint256 amount) external;
}
