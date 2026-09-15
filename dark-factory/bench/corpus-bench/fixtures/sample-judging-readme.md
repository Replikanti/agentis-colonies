# Issue H-1: Reentrant withdraw drains the vault before share burn

Source: https://github.com/sherlock-audit/sample-contest-judging/issues/1

## Found by
alice, bob

### Summary

`Vault::withdraw()` calls `token.safeTransfer()` before burning the caller's shares, so a malicious token
callback can re-enter `withdraw()` and drain more than the caller's fair share.

### Root Cause

In `Vault.sol:withdraw()` the external transfer happens before `_burn(msg.sender, shares)`.

### Code Snippet

File: Vault.sol

```solidity
    function withdraw(uint256 amount) external {
        _transferOut(msg.sender, amount);
        _burn(msg.sender, amount);
    }
```

The same accounting gap is reachable through the preview path at
https://github.com/sherlock-audit/sample-contest/blob/main/src/Vault.sol#L23-L25, and the share
bookkeeping it feeds lives in `Vault:30`.

### Impact

Total loss of vault funds.

# Issue M-1: Rounding in fee calculation always favors the protocol by one wei

Source: https://github.com/sherlock-audit/sample-contest-judging/issues/2

## Found by
alice, bob, carol, dave, erin, frank, grace, heidi, ivan

### Summary

`FeeMath::calc()` rounds down on every call, so the protocol collects a systematic one-wei-per-call bias.

### Root Cause

`FeeMath.sol:calc()` uses floor division instead of a rounding-mode parameter.

### Code Snippet

File: FeeMath.sol

```solidity
    function calc(uint256 amount) internal pure returns (uint256) {
        return (amount * FEE_BPS) / 10_000;
    }
```

### Impact

Negligible per-call dust accrual to the protocol at user expense.
