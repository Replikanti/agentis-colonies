# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/Curve2TokenOracle.sol:_lpTokenValue:73 | C2 | REFUTED | In the signed-index ETH StableSwap pools this oracle targets, remove_liquidity writes self.totalSupply = total_supply - _amount only after the per-coin transfer loop, so at the attacker's raw-ETH callback the oracle sees an un-burned totalSupply with balances[0] already decremented — a strictly deflated LP value, never the claimed 1/(1-f) inflation needed to mint or borrow against it. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
