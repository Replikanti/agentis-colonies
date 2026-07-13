# Issue H-1: Reentrant withdraw drains the vault before share burn

Source: https://github.com/sherlock-audit/sample-contest-judging/issues/1

## Found by
alice, bob

### Summary

`Vault::withdraw()` calls `token.safeTransfer()` before burning the caller's shares, so a malicious token
callback can re-enter `withdraw()` and drain more than the caller's fair share.

### Root Cause

In `Vault.sol:withdraw()` the external transfer happens before `_burn(msg.sender, shares)`.

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

### Impact

Negligible per-call dust accrual to the protocol at user expense.
