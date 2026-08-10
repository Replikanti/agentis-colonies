# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/withdraws/Ethena.sol:_finalizeCooldown:39 | class=C15 | REAL | When cooldownDuration()==0 the USDe is already redeemed onto the holder during _startCooldown, so balanceBefore is snapshotted after the funds arrive and the if (0 < userCooldown.cooldownEnd) unstake branch is skipped (cooldownEnd==0), making balanceAfter == balanceBefore and returning tokensClaimed=0 with finalized=true — no guard in the shown flow (canFinalizeWithdrawRequest even returns true whenever duration==0) prevents this permanent zero-payout finalization that strands the USDe on the clone. |

---
Checked: 1    REAL (survived, verify with forge): 1    REFUTED (killed): 0    ERRORED (unresolvable code file / unassessed no-verdict): 0
