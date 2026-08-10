# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:_exitPool:263 | C21 | REFUTED | The Curve V2 exit passes receiver = address(this) (the vault under delegatecall), so the ETH push only invokes the vault's own empty payable receive() — no attacker-controlled contract ever gains execution, and Curve's @nonreentrant('lock') on remove_liquidity* would block re-entry regardless, so there is no reentrancy window to price the position through. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
