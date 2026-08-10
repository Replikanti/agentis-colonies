# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/AbstractStakingStrategy.sol:_redeemShares:100 | class=C15 | REFUTED | tokenizeWithdrawRequest in _postLiquidation splits the stored per-account WithdrawRequest, so the w later read by _redeemShares already carries only the liquidated account's reduced yieldTokenAmount/sharesAmount, making the pro-rata burn correct, with sharesToRedeem bounded by the caller's share burn and final conservation enforced inside finalizeAndRedeemWithdrawRequest (manager code not shown — uncertainty resolves to REFUTED). |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
