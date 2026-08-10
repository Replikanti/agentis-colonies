# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:initiateWithdraw | class=C22 | REFUTED | The loop has no zero-manager skip, so an ETH-sentinel leg with no registered manager reverts on the high-level call to address(0) (and a registered manager must acquire the value it books, code not shown), while convertToAssets's escrow branch replaces rather than augments the normal valuation and getWithdrawRequestValue require(hasRequest)s on every leg — so no double-count of retained native ETH is reachable. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
