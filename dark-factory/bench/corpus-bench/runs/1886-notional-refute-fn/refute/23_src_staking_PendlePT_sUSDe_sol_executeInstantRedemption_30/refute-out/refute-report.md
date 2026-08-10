# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/PendlePT_sUSDe.sol:_executeInstantRedemption:30 | class=C15 | REFUTED | Slippage from the hardcoded first leg propagates directly into daiAmount and is enforced end-to-end by params.minPurchaseAmount (via _executeTrade's limit, or the explicit revert SlippageTooHigh in the DAI branch), so the only way the exploit works is an authorized spender/keeper deliberately setting its own guard to zero — a trusted-role action via an entry point not present in the shown code. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
