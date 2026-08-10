# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/AbstractSingleSidedLP.sol:convertToAssets:196 | C21 | REFUTED | Deposits are blocked while a withdraw request is pending (CannotEnterPosition) and deposit trades dispatch only to whitelisted TradingModule dexIds with per-token sell permissions, so no attacker-controlled re-entry into the view-only escrow branch exists — and that branch returns the manager's real, require(hasRequest)-gated pro-rata request value, which cannot be inflated. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
