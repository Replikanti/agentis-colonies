# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/AbstractStakingStrategy.sol:convertToAssets:51 | class=C21 | REFUTED | The escrow branch is gated by the account-scoped t_CurrentAccount transient and only triggers after that same account's yield tokens have actually been transferred into the withdraw request manager by _initiateWithdraw, making getWithdrawRequestValue the correct pro-rata valuation rather than an inflated one; no path lets an attacker open a request against a third party (_postLiquidation's tokenizeWithdrawRequest is a no-op absent a pre-existing request), and the claimed inflation depends on unshown manager code. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
