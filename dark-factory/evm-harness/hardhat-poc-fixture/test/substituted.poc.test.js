// substituted.poc.test.js — the anti-fabrication NEGATIVE fixture (#1507). This PoC never references the real
// in-scope target (Vuln): it drives a DIFFERENT artifact name (a would-be self-authored toy). Run through
// hardhat-poc.sh with --require-import contracts/Vuln.sol --require-contract Vuln, the #1471 linkage gate must
// reject it as HARNESS_ERROR (2) BEFORE any npm/compile spend — a fabricated / substituted target is NOT a
// verdict. Asserted by demo-poc-gen.sh with NO node (the linkage gate runs first).
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("substituted target PoC (must be rejected by the linkage gate)", function () {
  it("drives a non-target contract", async function () {
    // References NotVuln, never the in-scope Vuln artifact -> the linkage gate has nothing to bind to.
    const NotVuln = await ethers.getContractFactory("NotVuln");
    const c = await NotVuln.deploy();
    await c.waitForDeployment();
    expect(await c.getAddress()).to.be.properAddress;
  });
});
