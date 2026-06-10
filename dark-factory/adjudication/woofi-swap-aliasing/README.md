# Adjudication: WOOFi swap quote-pool aliasing

Resolves the **3/3-converged wildcard** flagged in
[agentis-core#857](https://github.com/Replikanti/agentis-core/issues/857) (backtest #3,
Sherlock WOOFi Solana). All three blind audit lenses independently flagged a High in WOOFi's
`swap.rs` that is **not** in the contest's confirmed-reward set — so it was either a real solo
High the entire field missed, or a shared LLM hallucination. Per the issue: *"You cannot tell
which without executing it — and that is precisely the litesvm harness's job."*

This directory is that execution.

## The claim under test

On a base↔quote swap the **quote pool** is passed into two mutable account slots of the same
instruction (`woopool_to`/`woopool_from` **and** `woopool_quote` — one canonical PDA per market).
Each Anchor `Account<'info, Pool>` deserializes an **independent** in-memory copy; at exit Anchor
serializes them back in **declaration order**, so the last-declared copy clobbers the earlier
copy's mutation. One `reserve` update is silently discarded → the pool reserve desyncs from the
vault.

## Result — REPRODUCED (real Solana SVM, `solana-program-test`, anchor-lang 0.31)

| Variant | Verdict | Evidence |
|---|---|---|
| `insecure.rs` | **VERIFIED** | CONTROL OK (distinct pools conserve exactly) + `INVARIANT VIOLATED`: aliased quote reserve = **1 001 000**, correct **971 000**, drift **+30 000** — the `quote_out` write was silently dropped. exit 101. |
| `secure.rs` | **SAFE** | CONTROL OK + `invariant held`: the duplicate-account guard rejects the aliased tx (`Custom(2003)` = Anchor ConstraintRaw). No false-VERIFIED. |

**True-positive: 1/1. False-VERIFIED: 0.** The two-sided gate behaves exactly as the colony
requires. The convergence is a **real bug mechanism**, not a hallucination.

Anchor version: WOOFi shipped on 0.29; this harness pins 0.31 (strictly newer, only adds safety
checks). A reproduction under 0.31 is therefore **conservative** — 0.29 exhibits it at least as
readily.

## Significance

This is the first end-to-end demonstration of the harness's **third role — convergence
adjudication** (alongside FP-filter and near-miss-rescue). It also resolves WOOFi from a
mid-pack 6/10 to a potential **#1** (a solo High = 5.0 Sherlock shares > the field's best 2.03),
and it surfaces a **new, harness-verifiable bug class the human field demonstrably misses**:
duplicate-mutable-account / account-aliasing reserve loss. That is exactly the low-duplicate
profile where bounty money concentrates.

## How to run

Standalone (what produced the result above), no `agentis` binary required:

```bash
cp insecure.rs  <harness>/src/lib.rs      # or secure.rs
cp poc.rs       <harness>/src/bin/poc.rs
cd <harness> && cargo run --bin poc        # <harness> = dark-factory/solana-harness-anchor
# insecure -> "INVARIANT VIOLATED" + exit 101 ; secure -> "invariant held" + exit 0
```

Via the colony (once the operator wires it like a sealevel lesson):

```bash
BOUNTY_TARGET=$PWD/insecure.rs BOUNTY_POC=$PWD/poc.rs \
SOLANA_ANCHOR_HARNESS_DIR=$PWD/../../solana-harness-anchor \
  agentis go ../../auditor/agents/auditor.ag --enable-exec --enable-messaging
```

## Follow-up (tracked in #857)

The colony detector (`classify_llm`) currently knows four classes
(MissingSignerCheck / IntegerOverflow / AccountDataMatching / MissingOwnerCheck). This artifact
proves a fifth — **DuplicateMutableAccount / account-aliasing** — is real and harness-adjudicable.
Adding it to the detector + invariant library is the highest-EV recall upgrade for live runs,
because it targets precisely the low-duplicate findings the field overlooks.
