# price feed — hunt brief   (zone: src_feed)
In-scope files: src/feed/Feed.sol
Bug classes to hunt: C2 (Oracle integrity)

## Invariants to break / attack surface
Attack the price feed as an external actor:
- C2: can a consumer read a price that is arbitrarily old, and is the push path restricted to the keeper?
Break invariant: "read() never returns a price older than the freshness bound".

## In scope — a valid finding
Only Medium/High severity, exploitable by an external attacker holding NO privileged role. A trusted role acting WITHIN its documented permissions is OUT OF SCOPE; a role EXCEEDING its permissions, or any unprivileged user, IS in scope.

## Out of scope — NEVER report
Anything already documented in the target's audits is out of scope — never re-report a known or previously-disclosed issue.

## Honesty mandate
Trace the actual control/data flow yourself — assume nothing is safe until a guard in the code provably stops it. Write and RUN a real Foundry PoC: a candidate is an UNVERIFIED lead until it reproduces through forge-verify. A rigorous SAFE on audited code is a valid outcome. Never fabricate a finding.
