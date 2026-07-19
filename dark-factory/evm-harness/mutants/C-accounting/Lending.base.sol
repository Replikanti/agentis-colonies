// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-accounting CLEAN twin — a tiny collateralized-debt pool with CORRECT accounting. The system-wide
// solvency property `totalCollateral >= totalDebt` holds under EVERY sequence of deposit/borrow/accrue:
//   - deposit credits collateral 1:1,
//   - borrow is guarded so a position's debt never exceeds its collateral,
//   - accrue settles debt against collateral SYMMETRICALLY (both drop by the same amount), preserving
//     the collateral-minus-debt gap.
// The GOOD invariant (inv_debt_backed.t.sol) must SURVIVE this contract (verdict CLEAN — no false
// positive on the fix). Same `contract Lending` name + public ABI as the mutant (STABLE-CONTRACT-NAME
// rule): the harness stages the chosen fixture to `src/Target.sol` and the invariant imports it.
contract Lending {
  mapping(address=>uint) public collateral;
  mapping(address=>uint) public debt;
  uint public totalCollateral;
  uint public totalDebt;

  function deposit(uint a) external {
    collateral[msg.sender] += a; totalCollateral += a;
  }

  // A position can only borrow up to its own collateral, so debt <= collateral per user (hence globally).
  function borrow(uint a) external {
    require(debt[msg.sender] + a <= collateral[msg.sender], "undercollateralized");
    debt[msg.sender] += a; totalDebt += a;
  }

  // Settle up to `a` of the caller's debt against their collateral. CORRECT: debt and collateral drop by
  // the SAME `p`, so the solvency gap (collateral - debt) is preserved for this position and globally.
  function accrue(uint a) external {
    uint p = a;
    if (p > debt[msg.sender]) p = debt[msg.sender];
    if (p > collateral[msg.sender]) p = collateral[msg.sender];
    debt[msg.sender] -= p; totalDebt -= p;
    collateral[msg.sender] -= p; totalCollateral -= p;
  }
}
