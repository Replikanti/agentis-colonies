# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/Curve2TokenOracle.sol:_lpTokenValue:88 | C2 | REFUTED | The claimed revert lives in _calculateLPTokenValue in AbstractLPOracle, which is not shown, and the bounds it enforces are per-deployment constructor parameters (_lowerLimitMultiplier/_upperLimitMultiplier) probed at a per-pool tuned dyAmount, so the assumed 0.99e18 threshold and ~13%-of-TVL manipulation cost are unverifiable; what the shown code does establish is that routing the fee-inclusive get_dy spot price into a deviation check so the oracle refuses to answer rather than return a manipulated value is the guard working as designed, making this the accepted fail-safe-DoS tradeoff of bounded-deviation LP oracles rather than an unguarded break. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
