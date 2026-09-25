# Example Vault

A synthetic fixture for the scope-assumptions extractor. It describes no real protocol.

## Scope

| File | nSLOC |
|---|---|
| src/Vault.sol | 40 |
| src/Router.sol | 25 |

The contracts listed above are the ones under review.

## Q&A

### Q: On what chains are the smart contracts going to be deployed?
Only the settlement layer; no rollups or side chains.

### Q: Which tokens are expected to interact with the smart contracts?
Standard ERC20 only.
No fee-on-transfer, rebasing or hook-carrying tokens are supported.

### Q: Are there any trusted roles in the protocol?
The admin is a trusted multisig and sets the fee within the bounds its setter enforces.

### Q: Is the codebase expected to comply with any specific standard?
None.

## Known issues

- Rounding in favour of the vault on every share conversion is accepted.
- A paused vault blocks withdrawals until the admin unpauses it.

## Example

```solidity
// Tokens: this fenced line mentions tokens and must never be extracted.
function deposit(uint256 amount) external {}
```
