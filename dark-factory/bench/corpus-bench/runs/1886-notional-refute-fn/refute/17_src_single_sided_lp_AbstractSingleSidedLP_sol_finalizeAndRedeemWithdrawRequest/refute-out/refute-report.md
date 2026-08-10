# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:finalizeAndRedeemWithdrawRequest | class=C15 | REFUTED | The escrowed state the claim needs is unreachable: BaseLPLib.initiateWithdraw itself has no zero-manager guard and reverts on the proportional (non-zero) exit balance of any leg lacking a manager, so no withdraw request can ever be recorded in the "one-legged" configuration, which in any case is a privileged ADDRESS_REGISTRY/deployment misconfiguration rather than an unprivileged attack. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
