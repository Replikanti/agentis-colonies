// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
// C-erc4626 CLEAN twin — a HARDENED ERC4626-style vault. A large virtual-share/asset offset
// (VS/VA, the OpenZeppelin decimal-offset mitigation) keeps the share price un-inflatable, so the
// multi-step donation/inflation attack cannot round a real depositor down to zero shares. The GOOD
// invariant (inv_victim_not_robbed.t.sol) must SURVIVE this contract (verdict CLEAN — no false
// positive on the fix). Same `contract Vault` name + public ABI as every other fixture in this
// class (the STABLE-CONTRACT-NAME rule), so one invariant test drives the base and every mutant;
// the harness stages the chosen fixture to `src/Target.sol` and the invariant imports it.
contract Token {
  mapping(address=>uint) public balanceOf; uint public totalSupply;
  function mint(address to,uint a) external { balanceOf[to]+=a; totalSupply+=a; }
  function transfer(address to,uint a) external returns(bool){ balanceOf[msg.sender]-=a; balanceOf[to]+=a; return true; }
  function transferFrom(address f,address t,uint a) external returns(bool){ balanceOf[f]-=a; balanceOf[t]+=a; return true; }
}
contract Vault {
  Token public asset; uint public totalShares; mapping(address=>uint) public shares;
  uint constant VS = 1000000000000000000000000000; uint constant VA = 1; // virtual offset (1e27)
  constructor(Token a){ asset=a; }
  function deposit(uint assets) external returns(uint s){
    uint ta = asset.balanceOf(address(this));
    s = assets * (totalShares + VS) / (ta + VA);           // hardened: virtual offset resists inflation
    asset.transferFrom(msg.sender,address(this),assets);
    shares[msg.sender]+=s; totalShares+=s;
  }
  function withdraw(uint s) external returns(uint assets){
    uint ta = asset.balanceOf(address(this));
    assets = s * (ta + VA) / (totalShares + VS);
    shares[msg.sender]-=s; totalShares-=s;
    asset.transfer(msg.sender,assets);
  }
}
