// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// Tiny stand-in for an audited vault, used ONLY by the corpus-bench extract-gt.sh --code self-test (#2215).
// fixtures/sample-judging-readme.md links into the EXACT line numbers below, so do not reflow this file:
//   #L23-L25  -> enclosing `withdraw` (declared above the range) PLUS `previewRedeem` (declared inside it,
//                the "range opens on the doc comment" case notional M-12 exhibits)
//   `Vault:30` -> `_burn`
contract Vault {
    mapping(address => uint256) internal _shares;
    uint256 internal _totalShares;

    function deposit(uint256 amount) external {
        _shares[msg.sender] += amount;
        _totalShares += amount;
    }

    function withdraw(uint256 amount) external {
        _transferOut(msg.sender, amount);
        _burn(msg.sender, amount);
    }

    // The redemption preview reads the cached total instead of the live balance.
    function previewRedeem(uint256 shares_) public view returns (uint256) {
        return (shares_ * _totalShares) / 1e18;
    }

    function _burn(address owner, uint256 amount) internal {
        _shares[owner] -= amount;
        _totalShares -= amount;
    }

    function _transferOut(address to, uint256 amount) internal {}
}
