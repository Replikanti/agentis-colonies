# Grand Rounds

![Version: 0.1.0](https://img.shields.io/badge/version-0.1.0-blue) ![Status: Experimental](https://img.shields.io/badge/status-experimental-red)

**Version:** `0.1.0` · [Changelog](./CHANGELOG.md) · **Requires:** agentis >= `1.22.3`

Grand Rounds is a clinical-genomics federation for **rare-disease diagnostic
prioritization**. It was built for the MVA Hackathon 2026 (Track 1): given a
proband's whole-genome VCF and a free-text clinical phenotype document, rank a
short list of candidate causal variants for a suspected
mosaic-variegated-aneuploidy (MVA) presentation.

This federation was authored `.ag`-first: the whole *decision surface* lives in
the agentis language and is billed in CB, while external binaries do only the
bulk, mechanical data transforms. It conforms to
[ADR-0003](../doc/adr/ADR-0003-federation-portability-contract.md) (non-forge
federation contract) and is a one-shot `agentis go` pipeline, not a ticking
daemon colony.

## The hard privacy rule

The one unrecoverable failure mode here is committing gated clinical data.

- Gated inputs (the VCF, the FASTQ/BAM if any, the clinical `.docx`, and every
  HPO term or note derived from them) live **outside** this checkout and are
  reached **only** through the environment: `$MVA_DATA_DIR` (read-only inputs),
  `$MVA_WORK_DIR` (intermediate artifacts), `$MVA_OUT_DIR` (submission CSVs).
- Nothing gated, and nothing derived from gated data, is ever committed. The
  federation-level [`.gitignore`](./.gitignore) plus the repo-level
  [`tools/check-no-gated-data.sh`](../tools/check-no-gated-data.sh) leak guard
  (enforced in CI) are the belt and braces.
- Any evidence shared in a PR, issue, or commit is **counts and paths only** —
  never a variant, a coordinate, an HPO id, or clinical detail.

## Colonies

| Colony | Description | Agents |
|--------|-------------|--------|
| [baseline](./baseline/) | One-shot `agentis go` pipeline: preprocess → phenotype (hash-pinned operator gate) → Exomiser (opt-in) → panel review → reconcile → emit + validate. | 1 (`pipeline.ag`, seven cooperating bus agents: a coordinator + six stages) |

The M3 **lens layer** (five blind lenses — inheritance / mosaicism-VAF /
HPO-overlap / known-gene / pathway — plus an adversarial refute gate and a
reconciler) is opt-in via `MVA_LENS_MODE=1` and layered onto the baseline
candidate pool inside `baseline/agents/pipeline.ag`; default-off, it leaves the
baseline submission byte-for-byte identical. See the
[methods report](./doc/methods.md) for the full architecture.

## Quickstart

Works on GNU/Linux and macOS. Two paths, and the first needs no data and no
LLM — if you are evaluating this repository, start there.

### A. What anyone can run (no gated data, no LLM, no containers)

```bash
./install.sh                    # prerequisite check + agentis repo + config
./baseline/demo-baseline.sh     # offline test suite (a git clone: 50 ok, 0 failed;
                                #  an unpacked tarball: 49 ok, 0 failed, 1 skipped,
                                #  because the leak guard is repo-scoped)
./tools/run-verify-citations.sh # re-checks all 103 Track 2 citations against PubMed
./tools/run-analyze-nampt.sh    # re-derives the DepMap figure the Track 2 report cites
```

`install.sh` names the exact install command for your operating system for
anything that is missing. The only hard requirements for this path are **agentis**, **python3** and
**git**; a container runtime is not needed. Install agentis with the upstream
prebuilt binary:

```bash
curl -fsSL https://raw.githubusercontent.com/Replikanti/agentis/main/install.sh | sh
```

Not `cargo install agentis`, and not `cargo binstall agentis` either: no crate
by that name is published, so both fail — the second one only after resolving
the index. This is worth stating rather than leaving implicit, because it is the
command a Rust developer tries first and it costs a full rustup installation
before it fails. Re-checked 2026-09-01 against crates.io; it changes when
[agentis-core#964](https://github.com/Replikanti/agentis-core/issues/964) ships.

### B. The full diagnostic pipeline (needs gated data and an LLM backend)

Not runnable without the hackathon's gated dataset, which is not distributable.
Two further prerequisites:

```bash
# 1. Inputs and outputs live OUTSIDE the checkout, via these three variables.
export MVA_DATA_DIR="$HOME/.mva-hackathon/data"   # gated inputs (read-only)
export MVA_WORK_DIR="$HOME/.mva-hackathon/work"   # intermediates + reference data
export MVA_OUT_DIR="$HOME/.mva-hackathon/out"     # submission CSVs

# 2. A real LLM backend in baseline/.agentis/config. `agentis init` writes
#    llm.backend = mock, whose prompt() returns nothing, and start-colony.sh
#    refuses to start on it (exit 7) rather than emitting a submission built on
#    an empty phenotype set. Backend reference: ../doc/llm-backend.md in a
#    checkout (it is repository-level, so an unpacked bundle does not carry it).
#      llm.backend = claude
#      llm.command = /path/to/your/llm-wrapper.sh

./baseline/scripts/fetch-reference-data.sh   # reference data; pulls the Exomiser
                                             # bundles (tens of GB) even though
                                             # that stage is default-off
./baseline/scripts/start-colony.sh           # runs `agentis go agents/pipeline.ag`
```

`MVA_ALLOW_MOCK_BACKEND=1` exercises the deterministic stages without an LLM;
the result is **not** a valid submission.

### Portability

Path A above is verified portable: the offline suite, the citation verification
and the DepMap re-derivation all run under a real bash 3.2 (the version macOS
ships), and paths resolve through `python3` rather than `realpath`, which macOS
did not carry before 12.3.

Path B is **not** portable yet. `demo-baseline-live.sh` and
`demo-lens-smoke-real.sh` still use `grep -P` and `sha256sum`, neither of which
exists on macOS, and the repository-wide lint (`tools/colony-lint.sh`) does not
parse under bash 3.2. Those are tracked separately; do not expect the full
pipeline to run on a Mac today.

## Track 2 — mechanism and drug repurposing

Track 1 asks *which variant*. Track 2 asks *what follows from it*: characterize
the variant's mechanism and propose repositioned drug candidates. That is a
literature problem rather than a pipeline problem, so it reuses the federation's
devise-then-refute pattern — agents proposing candidates, agents attacking them —
with one addition that turned out to matter more than the architecture.

**The verification contract.** Research agents worked under a standing rule:
*never report an identifier you have not confirmed*. Every claim carried a
confidence label, and agents had to distinguish "shown in this exact model" from
"shown in a different model". It earned its cost immediately — an agent guessed
three PMIDs from memory and the lookup returned three unrelated papers, on
ascorbate, progesterone and bacterial ribosomes. Proofreading would never have
caught that; a fabricated citation looks exactly like a real one.

So the check is mechanical and anyone can re-run it:

```bash
tools/run-verify-citations.sh          # wraps agents-side verify-citations.ag
```

[`tools/verify-citations.ag`](./tools/verify-citations.ag) re-derives first author,
year, journal and pages for all 103 citations from PubMed and fails on any
mismatch, missing record, duplicate or malformed row. It is `.ag`-first like the
rest of this federation: the whole decision surface — parsing, validation,
alignment, comparison, verdict — is agentis-resident, and the external binaries
do only mechanical work (`curl` fetches, `grep` narrows MEDLINE to the three
tags the decision reads). MEDLINE is line-oriented, so no JSON parser is needed.
The shell wrapper decides nothing; it resolves paths and turns the agent's
verdict marker into an exit code.
It verifies *identity* — that a PMID is the paper we say it is. Whether the paper
supports the claim stays a human judgement, which is why the bibliography carries
the report section each citation serves.

**The check that corrected us.** The report rejected NAD+ precursors partly on
the claim that rhabdomyosarcoma — a risk tumour for this genotype — is
*specifically* NAD+-dependent. We tested that against public DepMap CRISPR data
and it did not hold, so the report now says so:

```bash
tools/run-analyze-nampt.sh            # wraps agents-side analyze-nampt.ag
```

Same boundary as above: `fetch-depmap-nampt.sh` streams a 429 MB dependency
matrix and narrows it to one small TSV (bulk, mechanical), while
[`tools/analyze-nampt.ag`](./tools/analyze-nampt.ag) owns the dependency
threshold, the classification rule deciding which lines are the tumour of
interest, the group comparison, a pan-essential positive control that refuses
the run if the matrix does not behave, and the verdict. It prints a warning if
the data ever starts supporting the claim we withdrew.

The Track 2 report itself is a submission artifact and is not committed here; it
is uploaded to the organizers. What lives in this repository is the tooling and
the bibliography, so the report's central claim — that its citations are checked
rather than trusted — is falsifiable by anyone who clones this.

## Tier contract

This federation's pipeline agents are one-shot (no `fn tick`), so they run to
completion under a single declared `cb` budget rather than gating behaviour on
the four-tier confidence ladder. The four-tier contract in
[ADR-0001](../doc/adr/ADR-0001-confidence-tiers.md) remains normative for any
future ticking agent added here.

## Documentation

- [Methods report](./doc/methods.md) — pipeline architecture, the EPCR
  evidence-tier ladder, reproduction steps, and honest caveats.
- [Operator hackathon runbook](./doc/hackathon-runbook.md) — the operator-driven
  steps (leaderboard submission, optional mosaicism deep-dive, Track 2 report +
  video, post-hackathon data deletion).
- [Changelog](./CHANGELOG.md).

## License

The `grand-rounds` federation deliverable is licensed under
[Creative Commons Attribution 4.0 International (CC BY 4.0)](./LICENSE) — the
license required for the MVA Hackathon 2026 submission — which is distinct from
the repository-root Apache-2.0 that governs the rest of agentis-colonies.
