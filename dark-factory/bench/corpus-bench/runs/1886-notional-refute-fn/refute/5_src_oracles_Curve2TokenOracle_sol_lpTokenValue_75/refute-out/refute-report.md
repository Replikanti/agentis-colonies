# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/Curve2TokenOracle.sol:_lpTokenValue:75 | C23 | REFUTED | Every coin-index-relevant field (LP_TOKEN, PRIMARY/SECONDARY_INDEX, TOKEN_1/2, DECIMALS_1/2) is immutable with no setter, so the claimed mispricing can only arise from a trusted deployer wiring a 3-coin pool into a contract explicitly scoped to two-token pools — a privileged misconfiguration, not an unprivileged attacker path — and the base-class _calculateLPTokenValue plus its limit-multiplier checks are not shown, leaving no verifiable step where an invariant breaks. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
