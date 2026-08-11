# Refuter→hunter constraint DERIVATION pass (#1887) — durable run archive

The **derivation** half of #1887's acceptance contract: the frozen constraint corpus
[`../../../../auditor/knowledge/refute-constraints.json`](../../../../auditor/knowledge/refute-constraints.json)
is built HERE, on `notional`, and measured on a DIFFERENT contest (`yieldoor`, archived under
[`../1887-yieldoor-refute-transfer/`](../1887-yieldoor-refute-transfer/)). Derivation and held-out targets
must differ, and the corpus was frozen and committed **before** the held-out arms ran — that ordering is the
measurement, not a formality.

## What produced it

- **Date:** 2026-08-11
- **Commit:** `62e8251` (branch `measure/1887-refute-transfer`, off `origin/main`; the mechanism landed in PR #1893)
- **Backend:** `flat-cyborg 0.12.1` over Claude Code (model `opus`), `agentis 1.28.0`
- **Input:** the **29 archived candidate manifests** of the #1886 live run
  ([`../1886-notional-refute-fn/refute/*/candidate.manifest`](../1886-notional-refute-fn/)), concatenated in
  gate order into `combined.manifest`. **No new hunt pass** — the derivation re-refutes an already-recorded
  candidate set, so it costs one refute sweep and nothing else.
- **Code:** a fresh clone of the contest code repo at `82c8710` — the same commit the #1886 run was hunted at.
- **Implementation appendices (#1861):** 9 of the 29 candidates carry an `aux` column. The archived manifests
  point at the (scrubbed) `<work>/…/gates/<n>_<slug>/aux.sol` of the #1886 run, and those files were still
  present on the host, so the re-refutation was driven with the **same** appendices the original pass saw.
  In this archive those paths are re-scrubbed back to `<work>/…`.

## Reproduce

```
bash <repo>/dark-factory/run-refute.sh \
  --candidates <combined.manifest> \
  --code-dir <notional checkout>/notional-v4 \
  --backend flat-cyborg \
  --out <out>

bash <repo>/dark-factory/refute-to-knowledge.sh \
  --in <out>/refute-constraints.tsv --out refute-constraints.json
```
(`combined.manifest` in this directory is exactly the input used, with host paths scrubbed.)

## Result

- **29 candidates checked · 2 REAL · 27 REFUTED · 0 ERRORED** — the same 29 → 2 split the #1886 run
  recorded, i.e. the re-refutation reproduced the original gate's verdict counts.
- **27 of 27 REFUTED verdicts carried a `CONSTRAINT|` line** (the channel is best-effort by design; here it
  fired on every refutation). Both REAL verdicts contributed nothing, as the contract requires.
- **27 constraints survived curation → 27 corpus entries**, over 5 classes:
  C15 × 9, C21 × 8, C23 × 4, C2 × 3, C22 × 3. No two sentences were identical, so every entry has
  `samples = 1`.

## Curation (hand review of every entry, before the corpus was committed)

The contract for a corpus entry is: a **generalisable** standard, no protocol / contract / function names,
no addresses, no target nouns. A mechanical scan of all 27 sentences for target nouns
(`curve|convex|pendle|notional|morpho|weth|susde|ethena|balancer|uniswap|aave|compound|chainlink`,
`0x…` addresses, `*.sol`, target function names) and for CamelCase identifiers returned **zero hits** —
the refuter's answer contract held, and **no entry was dropped for leakage**.

Two mechanical fixes were applied to the harvested rows (`refute-constraints.raw.tsv` →
`refute-constraints.curated.tsv`, both archived here so the edit is diffable):

| # | rows | what | why |
|---|---|---|---|
| 1 | 19 | class id `class=C15` → `C15` (and `class=C21/C22/C23` likewise) | The class column of those archived candidates literally reads `class=CXX`: `hunter.ag`'s answer template writes the class placeholder as `<class=…>` and the model echoes the label. The refuter therefore emitted `CONSTRAINT\|class=C15\|…`, which the feeder would key as `condition: "class class=C15"` — a row `hunter.ag` (which filters on the bare `C15`) can never read. Left uncurated, **two thirds of the corpus would be dead weight**. Filed upstream as a separate defect; not fixed here, because PR 2 changes no mechanism. |
| 2 | 1 | stripped the enclosing `<` / `>` from one sentence | The model echoed the template's angle-bracket delimiters around an otherwise well-formed sentence. Delimiters only — **no word was changed, added or removed**. |

No other edit was made to any constraint text, and none was made after the held-out arms started (the
#1887 burn rule).

## Contents

| path | what |
|---|---|
| `combined.manifest` | the 29-candidate input (concatenated #1886 manifests, gate order, paths scrubbed) |
| `refute-report.md` | the 29 verdicts of this pass (2 REAL / 27 REFUTED) |
| `refute-constraints.raw.tsv` | the 27 `<class>\t<file:fn>\t<constraint>` rows as harvested |
| `refute-constraints.curated.tsv` | the same rows after the two mechanical fixes above = the feeder's input |
| `refute-logs/refute_<slug>.log` | the full hostile-read rationale per candidate |

> `refute-logs/` holds **23** files for 29 candidates: `run-refute.sh` names a cell log after the candidate's
> `file:fn` slug, and six of the 29 archived candidates are sibling framings that share a `file:fn` with an
> earlier one, so their logs overwrite. The verdicts and the harvested constraints are unaffected (each is
> scraped immediately after its own cell), and `refute-report.md` carries all 29 rows.

> All host/worktree paths are scrubbed; contest-relative `src/...` paths are public and kept verbatim.
