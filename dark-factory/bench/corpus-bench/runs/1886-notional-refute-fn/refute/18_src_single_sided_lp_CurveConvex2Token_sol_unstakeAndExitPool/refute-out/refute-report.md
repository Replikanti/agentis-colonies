# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/single-sided-lp/CurveConvex2Token.sol:unstakeAndExitPool | class=C15 | REFUTED | unstakeAndExitPool exists only on the delegatecall-target CurveConvexLib, not on the vault's external ABI, and a direct call to the library executes with address(this) = the library, whose Convex/gauge staked balance is zero — so withdrawAndUnwrap/gauge.withdraw reverts (or unstakes nothing) and the vault's LP position is unreachable. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
