// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-accounting MUTANT (inverted rounding / accounting drift) — deposit and borrow are correct, but
// `accrue` credits the borrower's DEBT reduction with a HALVED (floored) amount while consuming the FULL
// collateral. Each settlement therefore burns more collateral than debt it forgives, so total collateral
// drifts below total debt over a call sequence (borrow to the collateral limit, then accrue). This is the
// classic accounting-drift class a single-function check misses: no individual call looks wrong, the
// insolvency only emerges from the SEQUENCE. The GOOD invariant must KILL this mutant (verdict FINDING);
// the TOOTHLESS invariant must MISS it (verdict CLEAN). Same `contract Lending` + ABI as the base twin.
contract Lending {
  mapping(address=>uint) public collateral;
  mapping(address=>uint) public debt;
  uint public totalCollateral;
  uint public totalDebt;

  function deposit(uint a) external {
    collateral[msg.sender] += a; totalCollateral += a;
  }

  function borrow(uint a) external {
    require(debt[msg.sender] + a <= collateral[msg.sender], "undercollateralized");
    debt[msg.sender] += a; totalDebt += a;
  }

  // BUG: collateral is consumed in FULL (`p`) but debt is only credited HALF (`p/2`, floored). The
  // settlement removes more collateral than debt, so repeated/large accrues push totalCollateral below
  // totalDebt — insolvency the solvency invariant must catch.
  function accrue(uint a) external {
    uint p = a;
    if (p > debt[msg.sender]) p = debt[msg.sender];
    if (p > collateral[msg.sender]) p = collateral[msg.sender];
    uint credit = p / 2;                                   // inverted rounding: borrower under-credited
    debt[msg.sender] -= credit; totalDebt -= credit;
    collateral[msg.sender] -= p; totalCollateral -= p;
  }
}
