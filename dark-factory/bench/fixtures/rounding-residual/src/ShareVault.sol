// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// A minimal share-based vault fixture for the dark-factory capability bench.
///
/// It carries TWO defects on purpose, with different visibility to the "provided audit":
///   * KNOWN (in audit.txt): a reentrancy in withdraw() — the external transfer runs before the balance
///     state update. This is the exclusion-boundary finding; a pipeline that re-reports it is WRONG.
///   * RESIDUAL (NOT in audit.txt): the share-accounting path convertToShares()/redeem() rounds DOWN in
///     the vault's favour on deposit and in the redeemer's favour on exit, and the first depositor can
///     inflate the share price by donating assets directly — a classic audit-surviving accounting class
///     the provided audit never analysed. This is what DEVISE must surface and the attack must confirm.
contract ShareVault {
    mapping(address => uint256) public balanceOf;   // raw asset ledger (for deposit/withdraw)
    mapping(address => uint256) public shares;       // vault shares (for mint/redeem)
    uint256 public totalShares;
    uint256 public totalAssets;

    // ---- raw asset path (carries the KNOWN reentrancy) ----------------------------------------------
    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 amount) external {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        // KNOWN (audit.txt): external call precedes the state update -> reentrancy.
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "transfer failed");
        balanceOf[msg.sender] -= amount;
    }

    // ---- share path (carries the RESIDUAL rounding / first-deposit inflation) ------------------------
    /// assets -> shares. Rounds DOWN. On an empty vault this mints 1:1, so a first depositor who then
    /// donates assets directly to the contract inflates totalAssets without minting shares, pushing the
    /// share price up so later small depositors round to zero shares and lose their deposit.
    function convertToShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) {
            return assets;
        }
        return (assets * totalShares) / totalAssets; // floor: leaks dust to the vault
    }

    function convertToAssets(uint256 shr) public view returns (uint256) {
        if (totalShares == 0) {
            return shr;
        }
        return (shr * totalAssets) / totalShares; // floor
    }

    function mint() external payable {
        uint256 minted = convertToShares(msg.value);
        shares[msg.sender] += minted;
        totalShares += minted;
        totalAssets += msg.value;
    }

    /// shares -> assets, then pays out. Rounds DOWN via convertToAssets; combined with the mint-side
    /// floor, repeated mint/redeem cycles leak value out of honest LPs. No reentrancy guard here either,
    /// but the RESIDUAL of interest is the accounting, not the call order.
    function redeem(uint256 shr) external {
        require(shares[msg.sender] >= shr, "insufficient shares");
        uint256 assets = convertToAssets(shr);
        shares[msg.sender] -= shr;
        totalShares -= shr;
        totalAssets -= assets;
        (bool ok, ) = msg.sender.call{value: assets}("");
        require(ok, "redeem failed");
    }
}
