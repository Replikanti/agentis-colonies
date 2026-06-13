// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Controls.sol";

// This test file IS the method "stateful invariant fuzzing" instantiated:
// a handler drives random deposit/withdraw/transfer SEQUENCES by 2 actors, and
// the invariant asserts solvency (accounted total == real token backing).
// Run against BuggyBank -> FAIL (fuzzer finds the deposit->transfer counterexample);
// against SafeBank -> PASS. That discrimination validates the method.

interface IBank {
    function deposit(uint256) external;
    function withdraw(uint256) external;
    function transfer(address, uint256) external;
    function total() external view returns (uint256);
    function balance(address) external view returns (uint256);
}

contract Handler is Test {
    MockERC20 public token;
    IBank public bank;
    address[2] public actors = [address(0xA1), address(0xA2)];
    constructor(MockERC20 t, address b) { token = t; bank = IBank(b); }

    function deposit(uint256 i, uint256 a) public {
        address u = actors[i % 2];
        a = bound(a, 1, 1e24);
        token.mint(u, a);
        vm.prank(u);
        bank.deposit(a);
    }
    function withdraw(uint256 i, uint256 a) public {
        address u = actors[i % 2];
        uint256 b = bank.balance(u);
        if (b == 0) return;
        a = bound(a, 1, b);
        vm.prank(u);
        bank.withdraw(a);
    }
    function transfer(uint256 i, uint256 a) public {
        address u = actors[i % 2];
        address to = actors[(i + 1) % 2];
        uint256 b = bank.balance(u);
        if (b == 0) return;
        a = bound(a, 1, b);
        vm.prank(u);
        bank.transfer(to, a);
    }
}

contract BuggyInvariantTest is Test {
    Handler h; address bank; MockERC20 token;
    function setUp() public {
        token = new MockERC20();
        bank = address(new BuggyBank(token));
        h = new Handler(token, bank);
        targetContract(address(h));
    }
    function invariant_solvent() public view {
        assertEq(BuggyBank(bank).total(), token.balanceOf(bank), "phantom funds: accounted total != real backing");
    }
}

contract SafeInvariantTest is Test {
    Handler h; address bank; MockERC20 token;
    function setUp() public {
        token = new MockERC20();
        bank = address(new SafeBank(token));
        h = new Handler(token, bank);
        targetContract(address(h));
    }
    function invariant_solvent() public view {
        assertEq(SafeBank(bank).total(), token.balanceOf(bank), "phantom funds: accounted total != real backing");
    }
}
