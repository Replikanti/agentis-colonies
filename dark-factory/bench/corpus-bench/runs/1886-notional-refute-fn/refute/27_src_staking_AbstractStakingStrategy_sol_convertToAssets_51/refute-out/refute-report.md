# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/AbstractStakingStrategy.sol:convertToAssets:51 | class=C15 | REFUTED | _initiateWithdraw escrows the account's full sharesHeld, and both the liquidation (tokenizeWithdrawRequest) and partial-redeem (yieldTokenAmount * sharesToRedeem / w.sharesAmount with matching sharesToBurn) paths decrement yieldTokenAmount and sharesAmount proportionally, so no reachable state desynchronizes shares from w.sharesAmount — and the alleged mis-scaling lives in the unshown getWithdrawRequestValue. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
