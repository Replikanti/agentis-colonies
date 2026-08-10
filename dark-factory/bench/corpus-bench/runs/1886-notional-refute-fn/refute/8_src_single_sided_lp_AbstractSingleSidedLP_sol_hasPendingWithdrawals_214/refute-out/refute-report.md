# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:hasPendingWithdrawals:214 | C21 | REFUTED | The escrow branch does not value shares from a size-free snapshot — getWithdrawRequestValue requires a request on every pool token and both valuation and redemption scale strictly by shares / w.sharesAmount, so a dust yieldTokenAmount recorded against full sharesHeld under-values the attacker's own position (and strands the still-staked LP), while the alleged ability to pass a dust amount with full shares lives in the unshown external entry point of AbstractYieldStrategy, not in either file under review. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
