# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:tokenizeWithdrawRequest:255 | C21 | REFUTED | tokenizeWithdrawRequest runs only in __postLiquidation (after the health check) and is a documented noop unless the victim already self-initiated a request via initiateWithdraw, so a liquidator cannot flip hasPendingWithdrawals(victim); and the escrow branch cannot under-report anyway because getWithdrawRequestValue executes require(hasRequest) for every token and reverts rather than omitting un-requested value. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
