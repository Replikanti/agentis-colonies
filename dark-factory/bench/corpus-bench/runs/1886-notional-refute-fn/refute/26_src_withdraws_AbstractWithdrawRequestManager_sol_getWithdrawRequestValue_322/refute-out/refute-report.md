# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/withdraws/AbstractWithdrawRequestManager.sol:getWithdrawRequestValue:322 | class=C15 | REFUTED | The claimed divergence lives entirely in the unshown EthenaCooldownHolder/EthenaWithdrawRequestManager (the supplied derived contract, GenericERC20WithdrawRequestManager, sets WITHDRAW_TOKEN == YIELD_TOKEN and returns tokensClaimed == tokensToWithdraw, making both branches numerically identical), and even granting that wiring, w.yieldTokenAmount is frozen at initiateWithdraw while ExistingWithdrawRequest blocks any re-roll, so the overstatement is bounded by one cooldown period of sUSDe yield — a sub-percent, non-amplifiable approximation below Medium. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
