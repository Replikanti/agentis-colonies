# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:_exitPool | class=C23 | REFUTED | The exit-side use_eth=true is consistent with the entry side for every pool the contract itself classifies as ETH-bearing (coin == ALT_ETH ⇒ TOKEN_x == ETH_ADDRESS ⇒ msgValue > 0 ⇒ use_eth=true, native-balance delta, then WETH.deposit{value:…} in unstakeAndExitPool); the claimed WETH-coin V2 case is a trusted-deployer DeploymentParams configuration that no unprivileged caller can reach, and its asserted loss steps lie in code not shown. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
