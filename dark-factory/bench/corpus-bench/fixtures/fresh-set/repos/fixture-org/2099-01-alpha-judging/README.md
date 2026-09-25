# Issue H-1: Reentrant claimRewards payout lets a claimer drain the reward balance

Source: https://github.com/fixture-org/2099-01-alpha-judging/issues/1

## Found by
watson-a

### Summary

The payout is sent before the claimer's balance is cleared, see
https://github.com/fixture-org/2099-01-alpha/blob/main/proj/src/Vault.sol#L14

# Issue M-1: Stale exchange rate lets sweepDust round fee shares to zero

Source: https://github.com/fixture-org/2099-01-alpha-judging/issues/2

## Found by
watson-b, watson-c

### Summary

The dust sweep reads a cached rate that is never refreshed.

# Issue M-2: Missing slippage bound on `deposit()` lets a sandwich extract value

Source: https://github.com/fixture-org/2099-01-alpha-judging/issues/3

## Found by
watson-a, watson-b, watson-c, watson-d, watson-e, watson-f, watson-g

### Summary

The deposit path accepts any share output.
