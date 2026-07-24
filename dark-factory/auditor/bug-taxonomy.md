# EVM bug-class taxonomy — custom-code discovery knowledge

The DAG matcher (`seed-patterns.ag` / `recall-match.ag`) finds **recurrences of known code** — it only fires on forks / N-day variants. It returns nothing on *custom* protocols (a fresh stablecoin, a bespoke perp DEX, …), because there is no seeded sub-graph to match.

This taxonomy is the complementary knowledge for the **discovery** track (`hunter.ag`): on custom code you cannot match the *code*, but you can apply heuristics for *how DeFi protocols break*. Each class is a lens a hunter applies adversarially against the in-scope contracts and the protocol's stated invariants, scoped EXTERNAL-only (an attacker holding no privileged role; trusted-role/leaked-key impacts are out of scope unless a role exceeds its permissions).

It is consumed two ways:
1. `hunter.ag` loads the relevant classes for a subsystem and builds a deep adversarial `prompt()` per class (the discovery query).
2. `learn()` records which classes actually produced a forge-verified finding on which protocol-type, so the taxonomy is reweighted by fitness over time (the knowledge_market analog of the DAG's pattern fitness).

Format per class: **hits** (protocol shapes where it lives) · **hunt** (the adversarial questions) · **breaks** (the invariant the bug violates) · **sev** (typical Sherlock/Immunefi severity) · **seen** (where we hit/cleared it).

---

## C1 — ERC4626 share-price / vault accounting
- **hits:** yield-bearing/savings tokens, staking vaults (sDAI/sUSDe-style), `convertToShares/Assets`.
- **hunt:** Can the share price (`totalAssets/totalSupply`) ever DECREASE outside rounding dust? Trace every write to the assets numerator and every input to `totalAssets()`. Does a direct token donation inflate the price (raw `balanceOf` vs a `_virtualBalance`)? Can a depositor enter right before a reward/yield step and exit right after to capture yield they didn't earn (vesting sandwich)? Is reward vesting *smooth* (linear) or a discrete jump that can be sandwiched? Does `claim` advance state in lockstep with the value moved (no double-claim, no stranded dust)?
- **breaks:** "share price monotonic non-decreasing"; "totalAssets == tracked deposits + vested rewards".
- **sev:** Medium–High (value extraction / dilution).
- **seen:** a custom ERC4626 savings vault (clean — virtual-balance + smooth linear vest); Impossible kLast (non-payable).

## C2 — Oracle integrity
- **hits:** anything pricing collateral/debt via Chainlink/Pyth/Orakl or a derived source.
- **hunt:** Is the staleness + deviation + **sequencer-uptime/grace** check applied on EVERY price-read path (mint AND withdrawal AND liquidation), or does one path skip it? Is `startedAt==0` treated as healthy (it should revert — canonical L2 pattern)? Is the deviation threshold compared against the right reference and direction? Are `roundId`/`answeredInRound` checked? Is the 6↔18 (token↔feed↔stable) decimal conversion exact, or does a scaling error systematically over-mint / over-withdraw? **Is any price sourced from a manipulable on-protocol spot** (the protocol's own low-liquidity DEX, an AMM reserve, a staking exchange-rate) without a TWAP/bound?
- **breaks:** "price used == fair price"; "no over-mint/over-withdraw via mispricing".
- **sev:** High (drain) for manipulable source / missing check; Medium for decimal/bound gaps.
- **seen:** a custom Chainlink+sequencer oracle (clean — checks on all paths); KiloLend KiloOracle (Pyth/Orakl/admin, NOT a DEX → no manip); Curve scrvUSD (smoothing-capped).

## C3 — Cross-chain / LayerZero OFT + compose
- **hits:** OFT/OFTAdapter tokens, ovault composers, hub-lockbox + spoke-mint share bridges.
- **hunt:** Lockbox conservation — can shares be minted on a spoke WITHOUT a matching lock on the hub (or unlocked without burn)? Compose partial-failure — deposit ok / stake fails: are funds refunded AND not double-spent; can an attacker trigger a refund and keep the shares? Is the compose entrypoint endpoint-gated (`msg.sender == endpoint`, `_composeSender ∈ peers`)? Shared-decimals dust (de-dust on debit vs credit) symmetric? Compliance desync across chains beyond the documented quarantine — a path letting a frozen address actually transfer/redeem cross-chain? Replay of a compose message?
- **breaks:** "Σ spoke supply == hub locked"; "value conserved across every compose terminal state".
- **sev:** High (cross-chain inflation/double-spend) — sponsor's usual #1 focus.
- **seen:** a custom OFT ovault (clean — conserved + endpoint-gated).

## C4 — Withdrawal queue / NFT claim accounting
- **hits:** request→fill withdrawal queues, ERC721 withdrawal positions, express/standard tiers.
- **hunt:** Does every burned unit produce a claim with the EXACT owed amount (no forge, no inflate)? Double-claim (re-list / re-burn a tokenId)? Capacity invariant (`available <= maxLimit`) holdable under request/fill/payback? Is a tier's fee applied consistently with its slippage check (fee-before-vs-after the user's min)? Confusion between two NFT instances (standard vs express)? Who can mint/burn the position NFT — only the manager?
- **breaks:** "burned == claimable owed"; "available capacity bounded".
- **sev:** Medium–High.
- **seen:** a custom withdrawal-NFT queue (clean — atomic burn↔mint, exact amount).

## C5 — Access control / role model
- **hits:** AccessControl/AccessManaged/Ownable, role-gated setters, upgrade authorization, timelocks.
- **hunt:** Does any sensitive setter LOSE its guard or get the WRONG role (esp. after an access-control rewrite vs the upstream)? OZ AccessManaged: is any (target,selector) mapped to `PUBLIC_ROLE` on-chain (verify the deployed config, not just the modifier)? Any unprivileged path to obtain a role (mis-set role-admin, broken `grantRole`)? UUPS: is `_authorizeUpgrade` restricted, implementation `_disableInitializers`'d? Can a role exceed its permissions to reach another role's function (THIS is in-scope even when roles are "trusted")?
- **breaks:** "only the intended role can call X".
- **sev:** High (privileged drain) if a real escalation; else trusted-role → out of scope.
- **seen:** Parallel (clean — verified all 36 sensitive selectors role-gated on-chain via getTargetFunctionRole).

## C6 — Accounting / rounding direction
- **hits:** mint/redeem, fee math, AMM invariants, any `a*b/c`.
- **hunt:** Does a mint→redeem round-trip ever net the user MORE than deposited? Does every rounding step favor the protocol (truncate against the user)? Is a fee added to debt vs deducted from output consistently (no unbacked/phantom mint)? Does a custom invariant (constant-product/sum, K-check) conserve value across a swap round-trip even at asymmetric params?
- **breaks:** "no value extraction via round-trip"; "supply fully backed".
- **sev:** Medium–High.
- **seen:** Impossible (xybk round-trips net 0); Variational manager (provider-custodial → no external surface).

## C7 — Signature / replay
- **hits:** EIP-712 mint/permit, custodian-signed fiat mints, meta-tx relayers.
- **hunt:** Domain separator binds `address(this)` + live `block.chainid` (no cross-deployment / cross-chain replay)? Nonce incremented after verify? Is a user-protective field (slippage/min) part of the signed payload (a relayer can't weaken it)? Replay guard (used-ref mapping) total? Expiry + chainId enforced? Can one signature be routed to a different privileged action (purpose-binding)?
- **breaks:** "each authorization usable once, for exactly its intent".
- **sev:** Medium–High.
- **seen:** a custodian-signed fiat-mint (clean — `address(this)` bound, ref-replay guarded).

## C8 — Reentrancy
- **hits:** native-token (ETH/cEther) markets, ERC777/callback tokens, external calls before state writes.
- **hunt:** CEI order — is any value-bearing external call (`.call`, `safeTransfer` of a callback token, native send) made BEFORE the caller's balance/supply/borrow is updated? Cross-function and read-only reentrancy (a view used by another contract mid-call)? Is the `nonReentrant` guard on every entrypoint that needs it (including the native path)?
- **breaks:** "no recursive drain".
- **sev:** High.
- **seen:** KiloLend Compound fork (clean — CEI preserved, `to.transfer` 2300 gas, guards present).

## C9 — Decimals / scaling
- **hits:** mixed-decimal stablecoins (6) ↔ protocol token (18) ↔ feed (8), `1e36/price` inversions.
- **hunt:** Every conversion exact + favoring the protocol? Any path that truncates a small amount to zero (dust griefing) or, worse, mis-scales by `10^(±k)` (a Pyth-expo or feed-decimal bug)? Inversion (`1e36/price`) skipping a later decimal adjustment?
- **breaks:** "price/amount dimensionally consistent across all consumers".
- **sev:** High if systematic over-credit; Low for dust.
- **seen:** a 6↔18-decimal stablecoin (clean); KiloOracle Pyth-expo (latent, admin-path → out of scope).

## C10 — Liquidation / redemption (CDP & money-market forks)
- **hits:** Liquity/Compound/Aave-shaped lenders, `seizeInternal`, redemption ordering, stability-pool offset.
- **hunt:** Seize math + liquidation-incentive rounding (self-liquidation, seize-more-than-owed)? Redemption order/hints + base-rate math vs the upstream? Stability-pool P/S/G product offset faithful? First-depositor / empty-market exchange-rate inflation (donation to a freshly-listed, unseeded market)? New collateral-egress paths added vs the parent (e.g. a fee-router that can pull collateral)?
- **breaks:** "collateral conserved"; "no unbacked debt / over-seize".
- **sev:** High.
- **seen:** Hedgehog (Liquity fork — FeesRouter egress bounded-to-fee, clean); KiloLend (Compound — donation window closed, paused).

## C11 — First-depositor / inflation
- **hits:** any share-minting vault/market without a dead-shares mitigation — INCLUDING a strategy/vault that INHERITS its share logic from an external framework (ERC4626, Solmate/OZ ERC4626, Yearn `BaseStrategy`/`TokenizedStrategy`, a v3 vault base) rather than implementing `mint`/`deposit` itself.
- **hunt:** Can an attacker mint 1 wei into an empty market then donate underlying to inflate the exchange rate so later depositors' shares round to 0? Is there a `MINIMUM_LIQUIDITY` / dead-shares / virtual-offset guard? Are new markets seeded at listing? **When the contract INHERITS its share math from a framework, do NOT assume the framework mitigates** — many ERC4626 bases (incl. Yearn TokenizedStrategy) do NOT add dead shares / a virtual offset, so the DEPLOYER must seed. Check whether THIS contract or its FACTORY/constructor performs an initial seed deposit at deploy time. A framework-inheriting strategy that reaches an EMPTY first state with no initial seed and no inherited virtual-offset is first-depositor-inflatable even though the mint math lives in the inherited base — the finding is the MISSING deploy-time seed, not code in this file.
- **breaks:** "later depositors get fair shares"; "a fresh vault/strategy is never reachable in an unseeded, mitigation-free state".
- **sev:** High when a fresh/empty market is reachable.
- **seen:** a virtual-balance savings vault (mitigates); KiloLend (markets seeded); corpus-bench yearn GT H-1 (a Yearn v3 strategy inheriting `TokenizedStrategy` whose factory/constructor performs no initial seed → first-depositor inflatable).

## C12 — Slippage / MEV / fee-vs-protection
- **hits:** swaps, withdrawals with user `minOut`, anything with a fee deducted around a user check.
- **hunt:** Is the user's `minOut`/`minUsdc` checked against the PRE-fee gross while they receive the POST-fee net (protection silently weakened by the fee)? Is the gap bounded + documented (then likely Low) or unbounded (Medium+)? Sandwich/front-run of a user op via a manipulable intermediate?
- **breaks:** "user receives ≥ their stated minimum".
- **sev:** Low if fee-bounded+documented; Medium if material/undisclosed.
- **seen:** a custom express-withdrawal tier (pre-fee slippage — bounded 5% + documented → Low/invalid, not submitted).

## C13 — Pause / freeze / compliance consistency
- **hits:** sanctions/blocklist enforcement via `_update` overrides, pausable flows.
- **hunt:** Is the freeze/sanction check enforced on EVERY value-moving path (mint/burn/transfer/stake/redeem/NFT-transfer/bridge) with no inconsistency between contracts? Any `_update` bypass that isn't the documented quarantine? Is the sanctions wrapper fail-CLOSED (reverts/blocks on a failed external call, not fail-open)? Does pause coverage have a gap (one path missing `whenNotPaused`)?
- **breaks:** "frozen/sanctioned cannot move value, consistently".
- **sev:** Medium (compliance bypass).
- **seen:** a sanctions-wrapped stablecoin (clean — consistent address-validation, fail-closed wrapper).

## C14 — Fork-delta (bridge to the DAG matcher)
- **hits:** any contract that forks an audited parent (the parent is picked-clean; the DELTA is the surface).
- **hunt:** Semantic-diff the fork vs the audited parent (ignore renames/formatting). Audit ONLY the changed/added code + the documented "changes since" — that delta is unaudited. New facets/modules absent from the parent get full scrutiny.
- **breaks:** whatever invariant the delta touches (route to C1–C13).
- **sev:** inherits the touched class.
- **seen:** Parallel/Monet/Rocky (Cooper-Labs Transmuter fork — clean delta); the whole #861 premise.

## C15 — Integration-seam / composability
- **hits:** adapter/guard/bridge/oracle/wrapper/router/strategy modules — any contract whose job is to call INTO a second protocol: ERC4626 adapter vaults, multi-adapter pool managers, oracle-integrated AMMs, external-protocol wrappers. The seam is under-audited by construction — protocol A's auditors trust B, and B's auditors never see A's integration code, so the cross-protocol boundary is the tail nobody owns.
- **hunt:** (1) ASSET/BALANCE MIS-ACCOUNTING across the boundary — does the value the adapter reports match the assets actually held after the external call round-trips? The ERC4626 share-price-vs-real-assets invariant across the integration boundary is the top seam: a mispriced share/pool-token = theft. (2) NEW/EXOTIC ADAPTER BIAS — prioritise recently-added/one-off adapters; the widely-forked ones are picked over, the recently-added tail is not. (3) GLOBAL VALUE-CONSERVATION BACKSTOP — FIRST find (or prove ABSENT) a protocol-wide invariant layer (a withdraw-invariant + an operation-type lock + a cumulative-slippage cap that reverts any op leaving the pool worth less): where it holds, a single-adapter bug degrades to a REVERT not a drain, so the lens pays off only where per-adapter correctness is the ONLY barrier OR the integration code is FRESH. (4) CROSS-INTEGRATION COMPOSITION — can two adapters, or a flashloan via adapter A → manipulate a position priced by adapter B → extract, compose into a state single-adapter checks miss? Check for an operation-type lock. (5) SCOPE DISCIPLINE — attack the TARGET's OWN integration code (adapter/guard/wrapper/oracle-read), not the integrated protocol; "the integrated protocol misbehaves" is usually out-of-scope-by-trust unless the target fails to defend against it. Payable = theft/freezing of the target's users via its own integration logic. (6) FRESHNESS SYNERGY — amplifies on fresh integration-heavy targets; it is an amplifier, not a way to crack a mature hardened multi-adapter manager (there expect reverts, not drains).
- **breaks:** "adapter-reported value == assets actually held across the external call"; "no single adapter moves value the global backstop does not re-check"; "composition of adapters conserves total pool value".
- **sev:** High (value extraction via adapter mis-accounting; freezing via guard bypass); degrades to revert/Low where a global conservation backstop holds.
- **seen:** generic — oracle-integrated AMMs, ERC4626 adapter vaults, multi-adapter pool managers (a global op-lock/slippage backstop, where present, downgrades single-adapter bugs to reverts).

## C16 — State-machine liveness / stuck-state
- **hits:** request/job/queue-lifecycle contracts where a third-party actor (worker, relayer, oracle callback, counterparty) is expected to advance the state — deployment-request queues, escrow/dispute flows, cross-chain message queues, assignment/claim systems.
- **hunt:** For every state a request/job can enter, is there a way OUT if the expected actor never responds — timeout, cancel, anyone-after-deadline recovery? Can a worker/relayer simply never call the completing function, leaving the request permanently pending with funds or a shared slot locked? Is an "in-progress" lock/flag cleared on every exit path (success, timeout, cancel) or only the happy path? Does one stuck request block a SHARED resource (queue slot, nonce, capacity counter) for other users, not just its own submitter?
- **breaks:** "every state transition has a way out" — no operation that depends on a third party can be griefed into permanent limbo.
- **sev:** Medium (DoS/griefing; escalates when the stuck state locks shared capacity or funds for the whole system, not just the requester).
- **seen:** corpus-bench Crestal GT M-5 (worker-induced DoS in deployment requests — no cancellation mechanism).

## C17 — Index/slot-overwrite
- **hits:** any mapping/array keyed by an id that is not strictly-unique-by-construction — a hardcoded literal index, a counter that resets per caller/epoch, a caller-suppliable key, a low-entropy composite key.
- **hunt:** Trace every write to a keyed slot: is the key GUARANTEED unique across the record's whole lifetime (monotonic global counter, checked-unique hash), or can two legitimate calls compute the SAME key (hardcoded literal, a per-caller counter that restarts, caller+timestamp at second granularity)? When a write targets an ALREADY-OCCUPIED slot, does it REVERT/require the slot empty, or silently overwrite (losing the prior record's funds/state with no event, no refund)? Is the id space partitioned correctly per user/round/epoch, or does a shared default (e.g. index 0) alias two different callers' records?
- **breaks:** "no record is silently clobbered" — every write to a keyed slot either targets a fresh key or explicitly reverts on collision.
- **sev:** Medium–High (silent fund/state loss for the overwritten record; scales with whether the lost record held funds).
- **seen:** corpus-bench Crestal GT M-1 (`createCommonProjectIDAndDeploymentRequest()` hardcodes the request-id index to 0, losing prior requests).

## C18 — Round/auction-griefing
- **hits:** auction/round/epoch-settlement mechanisms (Dutch/English auctions, batch settlement, reward-distribution epochs) where a running counter accumulates contributions/bids during the round and settlement reads that same counter to decide success/failure and compute a rate.
- **hunt:** Can a participant manipulate the round's running counter (total sold, total bid, total contributed) AFTER the round's success/failure condition is effectively decided, corrupting the same counter used both to gate settlement and to compute payout? Does a FAILED round (below its success threshold) still update the SAME state variable a successful round updates, corrupting subsequent rounds' math? Can a user inflate a threshold-tracking variable (deposit-then-withdraw, or a non-decreasing counter) to push the round past its natural end condition indefinitely, blocking finalization for everyone? Is finalization idempotent (can't be re-triggered) with counters correctly reset/carried into the next round?
- **breaks:** "round settlement is atomic and protected" — a round's success/failure outcome and its settlement state cannot be corrupted or indefinitely deferred by a participant's own counter manipulation.
- **sev:** Medium–High (blocks or corrupts settlement for all round participants, not just the manipulator).
- **seen:** corpus-bench Plaza GT M-1 (a failed auction period still updates `sharesPerToken` as if it succeeded) and M-10 (a user can always inflate `totalSellReserveAmount` to block the auction from ending).

## C19 — Narrow-integer overflow / unsafe downcast → revert-DoS
- **hits:** any arithmetic or explicit cast on a value an EXTERNAL party (or an external contract's state) can drive — packed struct fields and counters read from another contract (e.g. a Uniswap V3 pool's `slot0` / observation counters, which are `uint16`), user-supplied amounts, token balances, `block.timestamp`/`block.number`-derived counters, and `uintN(x)` / `intN(x)` downcasts of unbounded inputs. Especially arithmetic done in a NARROW type (`uint8/16/32`, `int24/56`) BEFORE it is widened to `uint256`.
- **hunt:** For every `+`/`-`/`*`/`%` or `uintN(...)`/`intN(...)` cast whose operand is externally influenceable: can that operand reach a value that overflows/underflows the (possibly narrow) type, or truncates the cast? Solidity ≥0.8 REVERTS on overflow/underflow — so the finding is usually NOT silent state corruption but a REVERT that PERMANENTLY BRICKS every function routing through that line (a liveness / freezing-of-funds DoS). Trace operand TYPES precisely: `uint16 a + uint16 b` is evaluated in `uint16` and reverts at 65536 even when the result is later assigned to a `uint256`. Do NOT dismiss "it only reverts" as safe — on a reachable, attacker/environment-set input a revert on a shared core path IS the bug.
- **breaks:** "no reachable arithmetic or downcast on external input can revert a shared code path into permanent unavailability" — every overflow-prone op is widened before the op, bounded by a checked guard, or on a path where a revert cannot brick a shared resource.
- **sev:** High when the reverting line sits on a path every user/operation routes through (a price/activity read gating rebalance/compound/withdraw), permanently freezing funds; Medium when it only griefs the caller's own transaction.
- **seen:** corpus-bench yieldoor GT H-3 (a strategy summed two `uint16` Uniswap-V3 slot0 observation counters in `uint16`; a pool with a large observation buffer overflowed the sum, reverting and permanently DoS'ing every pool-activity-gated operation).

## C20 — Concentrated-liquidity tick / range precision (Uniswap V3-style)
- **hits:** strategies/vaults/managers running a Uniswap-V3-style concentrated-liquidity position — any code that reads `slot0`, computes or centers position tick ranges, rebalances, or converts between a tick and `sqrtPriceX96`.
- **hunt:** Does the code set/center position ranges from `slot0.tick` DIRECTLY, or from the tick DERIVED from `slot0.sqrtPriceX96`? Uniswap V3 sets `slot0.tick` to the price's tick MINUS 1 when the price sits exactly on a tick boundary (the current tick's lower edge is inclusive), so `slot0.tick` can LAG the true price by one tick; centering a range on the stale `slot0.tick` allocates liquidity ASYMMETRICALLY around the real price → systematic fee loss / mis-allocation, and a 1-wei boundary-crossing swap can move the true price outside the just-set range. Also check: are `tickLower`/`tickUpper` snapped to `tickSpacing` in the correct direction; is the range symmetric around the TRUE (sqrtPrice) price; can an attacker place the pool exactly on a boundary before a rebalance to force the mis-allocation?
- **breaks:** "position ranges are centered on the true pool price" — ranges are derived from `sqrtPriceX96` (not the boundary-lagging `slot0.tick`) and are symmetric around the real price, with correct tick-spacing rounding.
- **sev:** Medium–High (systematic loss of fees / capital mis-allocation for all depositors; escalates where the mis-allocation enables extractable value).
- **seen:** corpus-bench yieldoor GT H-2 (main position ticks are set from `slot0.tick` rather than the `sqrtPrice`-derived tick; at a boundary the tick lags by one, so the allocated range is asymmetric and the position loses fees).

---

### Hunter usage notes
- Map each in-scope contract to its likely classes (a savings token → C1/C11; an oracle → C2/C9; an ovault → C3; a manager → C4/C6/C7/C12; a lender → C8/C10/C11; an adapter/guard/bridge/wrapper/router/strategy or any oracle-integrated module → C15; a request/job queue completed by an off-chain worker or relayer → C16; any id-keyed record write (mapping/array slot assignment) → C17; an auction/round/epoch settlement mechanism → C18; any module doing arithmetic or downcasts on an external contract's narrow-int state (a Uniswap/oracle `slot0`, packed `uint8/16/32` counters) or on unbounded user input → C19; a Uniswap-V3-style concentrated-liquidity strategy/vault that reads slot0 or sets position tick ranges → C20). Run one deep adversarial `prompt()` per (subsystem × class). For C15, FIND THE GLOBAL VALUE-CONSERVATION BACKSTOP FIRST: where a protocol-wide op-lock/slippage cap holds, a single-adapter bug degrades to a revert, so the lens pays off only where per-adapter correctness is the ONLY barrier OR the integration code is FRESH — it amplifies on fresh integration-heavy targets, it does not crack mature hardened ones.
- Always load the scope brief first: the **invariants** the sponsor wants held (each is a finding if broken) and the **known-issues / acceptable-risks** (never report these).
- A class only produces a *finding* after the forge-verify harness reproduces it (deploy → exploit → assert the broken invariant). Static suspicion → candidate; forge-passing → finding. `learn()` the (class, protocol-type, verified?) tuple either way.
