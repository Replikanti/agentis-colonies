# Dark Factory — custom-code discovery leads

- repo: `target`   backend: mock
- Each CANDIDATE below is an UNVERIFIED LEAD. It is a finding ONLY after it reproduces through
  `evm-harness/forge-verify.sh --repo <repo> --poc <Exploit.t.sol>` (PoC PASSES = exploit fires).
- Submission is a separate, explicit human action. This colony never posts to a platform.

| Subsystem | Class | Lead (file:fn:line / severity / exploit / PoC sketch) |
|---|---|---|
| vault deposits | C1 | vault deposits:C1:1 / C1 / Medium / stub external exploit path / stub foundry PoC sketch |
| vault deposits | C6 | vault deposits:C6:1 / C6 / Medium / stub external exploit path / stub foundry PoC sketch |
| rewards distributor | C11 | rewards distributor:C11:1 / C11 / Medium / stub external exploit path / stub foundry PoC sketch |
| liquidation engine | C10 | liquidation engine:C10:1 / C10 / Medium / stub external exploit path / stub foundry PoC sketch |

---
Cells run: 4    Candidates surfaced: 4 (all UNVERIFIED — forge-verify each before it counts).
