# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:unstakeAndExitPool | class=C23 | REFUTED | The ASSET == address(WETH) gate is a WETH-representation converter, not a leak: for a non-WETH asset the constructor's ALT_ETH→ETH_ADDRESS rewrite makes native ETH the vault's correct internal form of that leg (and with _PRIMARY_INDEX pointing at the non-ETH asset the single-sided exit writes zero to the ETH leg anyway), while the claimed phantom escrow depends entirely on __initiateWithdraw/convertToAssets code not present in the reviewed file. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
