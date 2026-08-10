# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:unstakeAndExitPool | class=C22 | REAL | For a CurveInterface.V2 crypto pool the coin address returned by coins(i) is the WETH ERC-20 (not ALT_ETH), so _rewriteAltETH leaves TOKEN_i == WETH and the ETH_ADDRESS-gated WETH.deposit re-wrap in unstakeAndExitPool never fires, yet _exitPool passes the hardcoded use_eth=true to both remove_liquidity_one_coin and remove_liquidity, which makes the pool unwrap and push native ETH to the vault — leaving the two-sided delta tokenBalance(WETH)-before at 0 and the single-sided branch crediting a WETH amount the vault never actually received. |

---
Checked: 1    REAL (survived, verify with forge): 1    REFUTED (killed): 0    ERRORED (unresolvable code file / unassessed no-verdict): 0
