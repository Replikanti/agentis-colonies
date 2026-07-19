// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-erc4626 MUTANT (donation / inflation) — the CLASSIC ERC4626 share price with NO virtual offset.
// A direct token donation to the vault inflates `ta` (the vault's asset balance) without minting any
// shares, so the NEXT honest deposit prices in at `assets*totalShares/ta` and rounds to ZERO shares:
// the depositor's claim collapses far below what they put in. This is a MULTI-STEP bug — it only
// emerges from an attacker seed+donate priming the share price BEFORE the victim's deposit — exactly
// the class a single-function audit misses. The GOOD invariant must KILL this mutant (verdict FINDING);
// the TOOTHLESS invariant must MISS it (verdict CLEAN). Same `contract Vault` + ABI as the base twin.
contract Token {
  mapping(address=>uint) public balanceOf; uint public totalSupply;
  function mint(address to,uint a) external { balanceOf[to]+=a; totalSupply+=a; }
  function transfer(address to,uint a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
  function transferFrom(address f,address t,uint a) external returns(bool){ balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}
contract Vault {
  Token public asset; uint public totalShares; mapping(address=>uint) public shares;
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    s = totalShares==0 ? assets : assets*totalShares/ta;    // BUG: no virtual offset -> donation inflates ta
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    assets = s*ta/totalShares;
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
