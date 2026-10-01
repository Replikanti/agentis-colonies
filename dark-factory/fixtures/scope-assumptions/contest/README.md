# Example Lending contest details

A synthetic fixture for the scope-assumptions extractor. It describes no real protocol and no real contest.

- Join the contest chat for questions and announcements.
- Submit every report through the contest dashboard before the deadline.
- [Read the judging rules](https://example.org/judging) before submitting.

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Only the settlement layer; no rollups or side chains.

### Q: Which tokens are expected to interact with the smart contracts?
- Standard ERC20 only.
- No fee-on-transfer or rebasing assets are supported.

### Q: Which contracts hold user funds?
- Vault and Router hold every deposit.
- Bot never custodies funds.

### Q: Are there any limitations on values set by admins?
The admin is a trusted multisig and keeps the fee within the bounds its setter enforces.

# Audit scope

[target @ 0123abc](https://example.org/example/target/tree/0123abc)
- [target/src/Vault.sol](https://example.org/example/target/blob/0123abc/src/Vault.sol)
- [target/src/Router.sol](https://example.org/example/target/blob/0123abc/src/Router.sol)
- [target/src/keeper/Bot.sol](https://example.org/example/target/blob/0123abc/src/keeper/Bot.sol)
- [target/src/tokens/Wrapper.sol](https://example.org/example/target/blob/0123abc/src/tokens/Wrapper.sol)

# Out of scope

- Findings that need the deployment scripts or the test harness.
