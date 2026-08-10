# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/Curve2TokenOracle.sol:_lpTokenValue:73 | C15 | REFUTED | The oracle never reads get_virtual_price — it prices via raw balances cross-checked by a get_dy spot-price deviation band enforced in AbstractLPOracle._calculateLPTokenValue, which is not shown, so the claim's core assertion (a 5–15% value error that simultaneously passes the deviation limits) cannot be traced to any guard-free step in the actual code. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
