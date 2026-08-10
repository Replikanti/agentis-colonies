# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/staking/PendlePT.sol:_initiateWithdraw:148 | class=C22 | REFUTED | The redeemed TOKEN_OUT_SY is escrowed in a per-account withdraw request created in the same call that removes that account's PT and its sharesHeld from PT-denominated accounting, so those shares are valued off the request rather than the vault's PT balance and no shortfall is left to socialise onto other depositors. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
