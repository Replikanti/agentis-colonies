# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:checkReentrancyContext:156 | class=C23 | REFUTED | The claimed revert depends on unshown Curve V2 pool internals (whether it burns _amount=1 or the decremented amount=0 from msg.sender), and even if it did, LP_LIB's LP balance is permissionlessly toppable up by a 1-wei ERC20 transfer that no code in this file rejects, so no permanent, unliquidatable-position brick is established. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
