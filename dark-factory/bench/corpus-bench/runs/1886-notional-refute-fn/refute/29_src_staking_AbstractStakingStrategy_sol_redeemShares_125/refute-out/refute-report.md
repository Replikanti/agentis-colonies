# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/AbstractStakingStrategy.sol:_redeemShares:125 | class=C21 | REFUTED | _redeemShares is an internal function whose isEscrowed argument is supplied by the base AbstractYieldStrategy redeem flow (which derives pending-withdraw state itself, as convertToAssets here shows via _isWithdrawRequestPending), never by external calldata — the only attacker-controlled input, redeemData, decodes solely into RedeemParams trade fields — so no unprivileged caller can force the else branch for an escrowed account. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
