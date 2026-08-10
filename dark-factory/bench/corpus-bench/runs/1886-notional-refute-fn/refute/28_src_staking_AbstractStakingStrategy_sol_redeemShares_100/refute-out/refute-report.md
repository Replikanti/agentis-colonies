# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/AbstractStakingStrategy.sol:_redeemShares:100 | class=C21 | REFUTED | The pro-rata uses the account's own per-(vault,account) w.yieldTokenAmount/w.sharesAmount and truncates down, and any sharesToRedeem > w.sharesAmount must still pass finalizeAndRedeemWithdrawRequest, which debits the request in checked arithmetic and reverts on underflow — the claim rests on unshown manager code the reviewer never traced. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
