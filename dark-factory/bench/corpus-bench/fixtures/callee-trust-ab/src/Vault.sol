// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A minimal VALUE-CUSTODY vault fixture for the #2157 (milestone D3, epic #2130) CALLEE-TRUST A/B self-test.
// It DECLARES value-moving entrypoints (executeDeposit/withdraw) AND does amount-deduction arithmetic
// (`amount -= fee`), so the C6 accounting net fires -> is_value_custody. The offline self-test declares that
// flag through the map fixture's CUSTODY| line. Crucially the oracle callee is DEPLOYER-SETTABLE (a setter +
// mutable address state), so the #2145 detector flags executeDeposit's `oracle.getPrice()` as an
// ATTACKER-CONTROLLED CALLEE (a reentrant hazard) — the exact vector D1 (CALLEE-TRUST) is meant to surface and
// D2 (--vector-hunt) is meant to verify into a rare finding the breadth-only control misses. Generic shapes.
contract Token {
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;
    function mint(address to, uint256 a) external { balanceOf[to] += a; totalSupply += a; }
    function transfer(address to, uint256 a) external returns (bool) {
        balanceOf[msg.sender] -= a; balanceOf[to] += a; return true;
    }
    function transferFrom(address f, address t, uint256 a) external returns (bool) {
        balanceOf[f] -= a; balanceOf[t] += a; return true;
    }
}

interface IOracle {
    function getPrice() external returns (uint256);
}

contract Vault {
    Token public asset;
    uint256 public totalShares;
    uint256 public feeBps;
    mapping(address => uint256) public shares;

    // DEPLOYER-SETTABLE oracle: mutable address state + a setter -> the settable-callee detector fires.
    address public oracle;

    constructor(Token a) { asset = a; }

    function setOracle(address newOracle) external { oracle = newOracle; }
    function setFee(uint256 bps) external { feeBps = bps; }

    // value-moving entrypoint + amount-deduction arithmetic -> C6 accounting signal. It calls out to the
    // deployer-settable oracle BEFORE finalizing share state, so a hostile callee can reenter (CEI violated).
    function executeDeposit(uint256 amount) external returns (uint256 s) {
        uint256 fee = (amount * feeBps) / 10000;
        amount -= fee; // amount-deduction idiom
        uint256 price = IOracle(oracle).getPrice(); // ATTACKER-CONTROLLED CALLEE reached before state update
        uint256 ta = asset.balanceOf(address(this));
        s = totalShares == 0 ? amount : (amount * price * totalShares) / (ta * price);
        asset.transferFrom(msg.sender, address(this), amount);
        shares[msg.sender] += s;
        totalShares += s;
    }

    function withdraw(uint256 s) external returns (uint256 amount) {
        uint256 ta = asset.balanceOf(address(this));
        amount = s * ta / totalShares;
        shares[msg.sender] -= s;
        totalShares -= s;
        asset.transfer(msg.sender, amount);
    }
}
