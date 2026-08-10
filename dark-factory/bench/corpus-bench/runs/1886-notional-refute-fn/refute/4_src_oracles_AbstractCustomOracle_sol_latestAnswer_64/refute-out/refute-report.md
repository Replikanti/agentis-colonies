# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/AbstractCustomOracle.sol:latestAnswer:64 | C15 | REFUTED | The protocol's actual consumer path is latestRoundData(), which does call _checkSequencer() (the legacy V2 legs are documented as unused by the TradingModule and no shown caller reads them), and the gate can only ever bind during a sequencer outage/restart that an unprivileged attacker cannot induce — so the claim depends on a caller absent from both the base and derived contracts. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
