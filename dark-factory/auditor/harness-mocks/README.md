# harness-mocks — shared mock library for generated invariant harnesses

The deep-hunt prover (`auditor/agents/invariant-prover.ag`) used to hand-author **every** external-dependency
mock inside each generated harness. On complex targets that is where generation failed: an LP oracle needing
Curve/Balancer-style pricing reads, or a modular vault needing a share-vault dependency, produced a harness that
did not compile — a `HARNESS_ERROR`, i.e. no verdict at all, not a clean or a finding.

This directory is the fix ([#1794](https://github.com/Replikanti/agentis-colonies/issues/1794)): a small library
of pre-written, pre-compiled mocks that `run-invariant-hunt.sh` stages into every generated harness project at
`<repo>/test/mocks/`, so the prover can `import {MockERC20} from "./mocks/MockERC20.sol";` instead of
re-deriving a token from scratch on every run.

| File | Stands in for | Key surface |
|---|---|---|
| `MockAggregatorV3.sol` | a Chainlink price feed | `decimals`, `latestRoundData`, `getRoundData`; `setAnswer` / `setStale` / `setIncompleteRound` |
| `MockERC20.sol` | any ERC20 asset/collateral token | `decimals` (constructor arg), `mint`/`burn`, `approve`/`transfer`/`transferFrom` |
| `MockVault4626.sol` | an ERC4626 share vault | `deposit`/`mint`/`withdraw`/`redeem`, `convertTo*`, `preview*`, `totalAssets`, `totalSupply` |
| `MockPool.sol` | a Curve/Balancer/UniV2-style LP pool | `getReserves`/`balances`, `totalSupply`, `get_virtual_price`/`getRate`, `get_dy`/`getAmountOut`; `setReserves` |

## Invariants of this library

- **Dependency-free.** No file here imports anything — not OpenZeppelin, not solmate, not forge-std, not a
  sibling in this directory. Each one compiles alone in a bare Foundry project with zero remappings. A single
  `import` line added to any of these files breaks that contract (and the source-guard demo fails).
- **`pragma solidity >=0.8.0`.** Deliberately wider than the harness's own `^0.8.20`, so a mock compiles under
  whatever 0.8.x the *staged target project* pins. No post-0.8.0 language feature is used (no custom errors, no
  `string.concat`, no user-defined value types).
- **Unique top-level identifiers.** No two files declare the same contract or interface name, so a harness may
  import all four at once without an "identifier already declared" error.
- **Inert when unused.** Staging copies files; it never edits the target project's config, sources or tests. A
  harness that imports nothing from here produces a byte-identical run.
- **Deliberately unhardened.** `mint`/`burn`/`setReserves`/`setAnswer` are unpermissioned and `MockVault4626`
  uses the classic offset-free share formula, so the donation / first-depositor / price-manipulation paths stay
  reachable. A mock that cannot be abused hides the bug class the harness is hunting.
- **Fidelity is still the caller's job.** The prover's MOCK-DEP FIDELITY rule stands: pass the decimals and
  units the *target* assumes (`new MockERC20("USDC", "USDC", 6)` for a 6-decimal asset), never a default.

## Adding a mock

Add the `.sol` file here, keep the invariants above, extend the table, and extend
`dark-factory/demo-harness-mocks.sh` — it source-guards the dependency-free contract, the staging wiring and the
prover's reuse directive.
