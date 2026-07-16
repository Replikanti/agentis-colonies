// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A minimal VALUE-CUSTODY vault fixture for the #1713 deep-hunt A/B self-test. It DECLARES value-moving
// entrypoints (deposit/withdraw) AND does amount-deduction arithmetic (`amount -= fee`), so zone-mapper.ag's
// shipped #1698 C6 accounting net (has_value_moving_function + has_amount_deduction) fires -> is_value_custody
// is true. The offline self-test declares that flag through the map fixture's CUSTODY| line; this source is
// what makes it fire on a live --backend mock run too. The share math intentionally prices off the raw asset
// balance with no virtual offset (the classic first-depositor inflation shape) so the injected drain in
// truth.tsv is plausibly a stateful-invariant (multi-step) bug the breadth pass misses.
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

contract Vault {
    Token public asset;
    uint256 public totalShares;
    uint256 public feeBps;
    mapping(address => uint256) public shares;

    constructor(Token a) { asset = a; }

    // admin-ish setter — a breadth lead lands here in the self-test (NOT the value-custody drain).
    function setFee(uint256 bps) external { feeBps = bps; }

    // value-moving entrypoint + amount-deduction arithmetic -> C6 accounting signal.
    function deposit(uint256 amount) external returns (uint256 s) {
        uint256 fee = (amount * feeBps) / 10000;
        amount -= fee; // amount-deduction idiom (has_amount_deduction)
        uint256 ta = asset.balanceOf(address(this));
        s = totalShares == 0 ? amount : amount * totalShares / ta;
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
