# Dark Factory — adversarial refutation verdicts

- backend: flat-cyborg
- A REAL verdict is a LEAD that survived a hostile read — NOT a finding. Verify it through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires)
  before it counts; submission stays a separate, explicit human action. This colony never posts.

| Candidate (file:fn) | Class | Verdict | Reason |
|---|---|---|---|
| src/oracles/AbstractCustomOracle.sol:latestAnswer:64 | C2 | REFUTED | latestAnswer() is an unused legacy AggregatorV2 view (its siblings getRoundData/getAnswer/getTimestamp hard-revert and are annotated "Unused in the trading module"), while every actual protocol consumer prices through latestRoundData(), which does call _checkSequencer() — so no unprivileged state-changing path bypasses the sequencer gate. |

---
Checked: 1    REAL (survived, verify with forge): 0    REFUTED (killed): 1    ERRORED (unresolvable code file / unassessed no-verdict): 0
