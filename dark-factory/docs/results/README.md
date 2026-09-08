# Dark Factory — public results

> **We hunted and found nothing payable on these targets. This is not a security audit
> and it is not a safety claim.** A clean result here means: the pipeline described below
> ran to completion against real, deployed, in-scope code, raised zero candidates that
> survived adversarial scrutiny, and every stateful invariant it derived and fuzzed held
> across the fuzz budget. It does **not** mean the code is bug-free, it does not cover
> everything an audit would, and it should never be read as an endorsement of the target's
> security posture.

Dark Factory is an autonomous hunting pipeline that reads public bug-bounty scope, looks
for exploitable bugs, and — on the rare occasion it finds one — stages a human-reviewed
report. Nobody outside the team has been able to check that claim, because nothing about
it has been public. This page is the fix: five write-ups below are dated, reproducible
runs against still-active Immunefi programs, plus an honest recall number against
concluded contests where the answer key is public.

## What "rigorous negative" means here

Each hunt below goes through the same four stages before a target is called clean:

1. **Breadth pass** (`run-discovery.sh` fanning the substrate discovery agent over
   `subsystem × bug-class` cells, or the equivalent `run-zone-hunt.sh` breadth pass) reads
   every in-scope file and raises **candidates** — unverified leads, each an
   attack-path sketch tied to a specific function/line.
2. **Adversarial refute gate** takes every candidate and tries to kill it: is the
   "privileged" caller actually role-gated in the deployed source, does the described
   entrypoint exist, does the attack path survive a hostile re-read against the real
   contract (not a paraphrase of it)? A candidate that does not survive this is
   **refuted**, not a finding — the write-ups below describe *why* each one died, at the
   mechanism level, not just "refuted."
3. **Stateful-invariant fuzz** (the severity-first deep-hunt stage) derives explicit
   safety invariants for the value-custody zones (accounting identities, solvency
   conditions, access-control boundaries) and fuzzes them with a stateful harness looking
   for an unprivileged sequence that breaks one. An invariant that survives the fuzz
   budget is reported **held**; one that breaks produces a finding, which then goes back
   through the same refute gate.
4. **Verdict.** A target is a rigorous negative only when it clears all three: zero
   candidates survive the refute gate, and every derived invariant that was fuzzed held.
   Nothing is submitted anywhere by this process — a human reviews and manually submits
   anything that reaches VERIFIED (none of the five below did).

None of this claims completeness. Every write-up below states explicitly what was **not**
covered (zones out of scope for that hunt, invariants not yet derived, code paths the
harness could not instantiate). Treat "clean" as "we looked hard at X and Y and it held,"
not "the protocol is safe."

## How to reproduce a row

Every number in a write-up traces to two things you can check yourself without any
internal tooling:

- **The addresses and on-chain state** — each write-up lists the exact in-scope contract
  addresses, links the public Immunefi program page, and gives the `cast call` signatures
  used to read the accounting/solvency invariant it fuzzed. Run those calls yourself
  against a public RPC (e.g. `https://ethereum-rpc.publicnode.com`, `https://bsc-rpc.publicnode.com`)
  and you get the same live values, mechanically:

  ```bash
  cast call <address> "<signature>" [<args...>] --rpc-url <public-rpc>
  ```

  A write-up's "invariants fuzzed" table gives the left-hand and right-hand side calls and
  the relation (`>=`/`<=`) that must hold between them at every block.

- **The source** — every address is either verified on Sourcify/Blockscout (linked per
  contract) or was pulled keylessly from the verified implementation behind an upgrade
  proxy and rebuilt locally; the write-up says which. You can independently re-verify the
  bytecode against the same source.

- **The corpus-bench recall number** below is reproducible from this repo directly (see
  that section for the exact command); it needs a public RPC/forge setup but no internal
  artifacts.

## The five write-ups

| Target | Chain | Program | Hunt date(s) | Verdict |
|---|---|---|---|---|
| [Twyne](twyne.md) | Ethereum | [immunefi.com/bug-bounty/twyne](https://immunefi.com/bug-bounty/twyne/) | 2026-09-04 | clean — rigorous negative (core + operators) |
| [Lista DAO (CDP core)](lista-dao.md) | BNB Smart Chain | [immunefi.com/bug-bounty/listadao](https://immunefi.com/bug-bounty/listadao/) | 2026-09-04 | clean — rigorous negative |
| [USDN (SmarDex)](usdn.md) | Ethereum | [immunefi.com/bug-bounty/usdn](https://immunefi.com/bug-bounty/usdn/) | 2026-09-05 | clean — rigorous negative |
| [mETH Protocol](meth.md) | Ethereum | [immunefi.com/bug-bounty/mETH](https://immunefi.com/bug-bounty/mETH/) | 2026-09-05 | clean — rigorous negative |
| [Enzyme Onyx](enzyme-onyx.md) | Ethereum (+5 other chains) | [immunefi.com/bug-bounty/enzyme-onyx](https://immunefi.com/bug-bounty/enzyme-onyx/) | 2026-08-26 | clean — rigorous negative |

These are the only five hunts, out of a longer running list, for which the underlying
evidence is at this tier: cast-verified on-chain addresses, a completed breadth pass, and
a completed deep-hunt with an explicit invariant-fuzz verdict. Other targets have been
hunted but are held back from this page either because the program has an unfixed
Critical open elsewhere (disclosure etiquette), because the run itself hit tooling
failures that block calling it a clean result, or because the result is a program-declared
known issue rather than a hunt outcome — none of those are represented here, and none of
them are claimed as clean.

## Corpus-bench: honest recall against concluded contests

The five hunts above are **live** runs against unaudited-by-us, still-open scope — there is
no answer key, so "clean" is the strongest claim that data supports. To measure the
pipeline's actual recall, `dark-factory/bench/corpus-bench/` runs it against **concluded**
Sherlock contests that dozens of independent auditors ("watsons") already combed over,
where the ground truth is public. This is the honest number, stated without rounding up:

- **Overall recall: 3/37** confirmed findings across the run corpus.
- **Rare-tier recall (findings only 1–2 watsons independently found): 2/14.** This is the
  tier that separates an elite hunter from the crowd — the easy, everybody-catches-it bugs
  are not the interesting measurement. **2/14 is mid-tier, not elite**, and is stated here
  without qualification.
- Per-anchor detail (why each rare bug was caught or missed — generation miss vs.
  refute-gate false negative vs. genuinely caught) is in
  [`../../bench/corpus-bench/bug-class-coverage.md`](../../bench/corpus-bench/bug-class-coverage.md).

Reproduce it yourself:

```bash
# deterministic self-test (no network, no LLM) — what CI runs:
dark-factory/bench/corpus-bench/run-corpus-bench.sh

# the full live measurement over the whole corpus (needs a real LLM backend + forge;
# never run this as part of a PR gate):
dark-factory/bench/corpus-bench/run-corpus-bench.sh --live --work /path/outside/repo --json
```

No result on this page is cherry-picked: the corpus-bench number above is every contest in
`corpus.tsv` that has been run, not a subset selected for a good score, and it is dated
against the same measurement (`#1879`/`#1886`, 2026-08-10) cited in
`bug-class-coverage.md` rather than restated from memory.
