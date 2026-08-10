# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:joinPoolAndStake | class=C22 | REFUTED | The claim's decisive step (_executeDepositTrades delivering native ETH rather than WETH) lives in AbstractSingleSidedLP, which is not in the reviewed code, while the visible entry-unwrap/exit-rewrap symmetry (WETH.withdraw on join, WETH.deposit{value: exitBalances[i]} on exit) establishes the opposite convention that the vault holds the ETH leg as WETH at rest, and the alleged failure is a deterministic revert under a privileged deployment configuration rather than an unprivileged value-extracting exploit. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
