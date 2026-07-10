// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice A role model + pause/freeze fixture for the zone-map demo (access-control + pause surface).
contract Governance {
    address public owner;
    bool public paused;
    mapping(address => bool) public guardians;
    mapping(bytes32 => uint256) public timelock;

    uint256 public constant DELAY = 2 days;

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "paused");
        _;
    }

    constructor() {
        owner = msg.sender;
    }

    function setGuardian(address who, bool ok) external onlyOwner {
        guardians[who] = ok;
    }

    function pause() external {
        require(guardians[msg.sender] || msg.sender == owner, "not authorized");
        paused = true;
    }

    function unpause() external onlyOwner {
        paused = false;
    }

    function queue(bytes32 id) external onlyOwner whenNotPaused {
        timelock[id] = block.timestamp + DELAY;
    }

    function execute(bytes32 id) external onlyOwner whenNotPaused {
        require(timelock[id] != 0 && block.timestamp >= timelock[id], "not ready");
        timelock[id] = 0;
    }

    function transferOwnership(address next) external onlyOwner {
        require(next != address(0), "zero");
        owner = next;
    }
}
