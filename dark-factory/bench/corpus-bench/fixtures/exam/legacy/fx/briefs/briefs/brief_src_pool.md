# share pool — hunt brief   (zone: src_pool)
In-scope files: src/pool/FeeMath.sol, src/pool/Pool.sol
Bug classes to hunt: C1 (ERC4626 share-price / vault accounting), C6 (Accounting / rounding direction)

## Invariants to break / attack surface
Attack the share accounting as an external depositor holding no privileged role:
- C1: does withdraw move value before the share balance is reduced, and can the ratio be skewed first?
- C6: is every division rounded against the caller on deposit and on withdraw?
Break invariant: "totalAssets covers every outstanding share at the current ratio".

## In scope — a valid finding
Only Medium/High severity, exploitable by an external attacker holding NO privileged role. A trusted role acting WITHIN its documented permissions is OUT OF SCOPE; a role EXCEEDING its permissions, or any unprivileged user, IS in scope.

## Out of scope — NEVER report
Anything already documented in the target's audits is out of scope — never re-report a known or previously-disclosed issue.

## Honesty mandate
Trace the actual control/data flow yourself — assume nothing is safe until a guard in the code provably stops it. Write and RUN a real Foundry PoC: a candidate is an UNVERIFIED lead until it reproduces through forge-verify. A rigorous SAFE on audited code is a valid outcome. Never fabricate a finding.
