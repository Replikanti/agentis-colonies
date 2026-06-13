// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ---------------------------------------------------------------------------
// Method-discovery control corpus — bug class C6 (accounting / solvency drift).
// A planted bug that is INVISIBLE to single-function review but caught by
// stateful invariant fuzzing (a deposit -> transfer SEQUENCE breaks solvency).
// Paired with a clean twin so a proposed method must DISCRIMINATE: fail on
// Buggy, pass on Safe (the two-sided gate).
// ---------------------------------------------------------------------------

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

// Minimal ERC20 with no allowance check (keeps the fuzz harness approve-free).
contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    function mint(address to, uint256 a) external { balanceOf[to] += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

// BUGGY: the internal `transfer()` double-counts `total` (stray `total += a`).
// Read in isolation `transfer()` looks fine; only a deposit -> transfer SEQUENCE
// makes `total` diverge from the real backing -> phantom funds -> insolvency.
contract BuggyBank {
    IERC20 public immutable token;
    uint256 public total;
    mapping(address => uint256) public balance;
    constructor(IERC20 t) { token = t; }
    function deposit(uint256 a) external {
        token.transferFrom(msg.sender, address(this), a);
        balance[msg.sender] += a; total += a;
    }
    function withdraw(uint256 a) external {
        balance[msg.sender] -= a; total -= a;
        token.transfer(msg.sender, a);
    }
    function transfer(address to, uint256 a) external {
        balance[msg.sender] -= a; balance[to] += a;
        total += a; // BUG: internal transfer must not change `total`
    }
}

// SAFE: identical, but `transfer()` leaves `total` untouched.
contract SafeBank {
    IERC20 public immutable token;
    uint256 public total;
    mapping(address => uint256) public balance;
    constructor(IERC20 t) { token = t; }
    function deposit(uint256 a) external {
        token.transferFrom(msg.sender, address(this), a);
        balance[msg.sender] += a; total += a;
    }
    function withdraw(uint256 a) external {
        balance[msg.sender] -= a; total -= a;
        token.transfer(msg.sender, a);
    }
    function transfer(address to, uint256 a) external {
        balance[msg.sender] -= a; balance[to] += a;
    }
}
