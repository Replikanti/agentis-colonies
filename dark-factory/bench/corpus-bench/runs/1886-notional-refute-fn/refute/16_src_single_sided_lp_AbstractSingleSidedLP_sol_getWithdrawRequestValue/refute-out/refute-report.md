# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:getWithdrawRequestValue | class=C15 | REFUTED | The withdraw path uses a proportional remove_liquidity exit (isSingleSided: false), whose per-leg amount poolBalance_i * poolClaim / totalSupply cannot be flash-swapped to zero for a material position without driving a Curve reserve to single-digit wei (unbounded cost under the invariant), and initiateWithdraw only acts on the caller's own account, so no unprivileged attacker can create the one-legged request that would make require(hasRequest) revert. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
