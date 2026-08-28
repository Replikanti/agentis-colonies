# Grand Rounds — Methods Report

**Federation:** `grand-rounds` (agentis-colonies) · **Track:** MVA Hackathon 2026, Track 1 (causal-variant prioritization) · **Team:** Agentis Federation · **License:** [CC BY 4.0](../LICENSE)

This report documents the *method* — the pipeline architecture, how a candidate
becomes a ranked submission row, and how to reproduce a run. It contains **no
proband data**: no variant, coordinate, HPO id, or clinical detail derived from
the gated dataset appears here or anywhere in this repository (see
[the privacy rule](../README.md#the-hard-privacy-rule)). Concrete candidate
outputs exist only in the operator's local `$MVA_OUT_DIR` and are never
committed.

## 1. Design premise

Grand Rounds transplants the dark-factory **devise → refute** auditing pattern
to clinical genomics: instead of one monolithic "call the variant" prompt, the
decision surface is decomposed into independent agents that each reason from one
angle over a shared candidate pool, and an adversarial refuter that tries to
knock candidates down before they are ranked.

The federation is authored **`.ag`-first**: the whole decision surface lives in
the agentis language (billed in CB), while external binaries (`bcftools`,
optionally Exomiser) do only the bulk, mechanical data transforms. It is a
one-shot `agentis go` pipeline (no ticking daemons), conforming to
[ADR-0003](../../doc/adr/ADR-0003-federation-portability-contract.md).

## 2. Baseline pipeline (M1)

`baseline/agents/pipeline.ag` is one file of seven cooperating bus agents — a
coordinator plus six stages, wired only through the substrate emit/listen bus:

| Stage | Agent | Responsibility |
|-------|-------|----------------|
| 0 | `coordinator` | Resolve inputs (VCF, phenotype doc, output dir) from the environment; seed the bus. |
| 1 | `preprocessor` | Contig-rename + normalization (`bcftools` bulk); `.ag` decides the rename map and guards an empty-after-filter result. |
| 2 | `phenotyper` | Derive candidate HPO ids from the free-text phenotype document (LLM decision), then **stop at a hash-pinned operator gate**: a `sha256` of the reviewed HPO draft is stored, so editing after approval invalidates the gate. |
| 3 | `exomiser_runner` | **Opt-in** phenotype-driven ranking (Exomiser). Its output is a documented later revision — the Exomiser→reconcile merge is tracked in [#2031](https://github.com/Replikanti/agentis-colonies/issues/2031) and not yet consumed by stage 5. |
| 4 | `panel_reviewer` | Resolve the known-MVA-gene panel to coordinates from the operator-provided GENCODE GTF, restrict the normalized VCF to those regions, and classify each record. |
| 5 | `reconciler` | Assign each candidate an evidence tier and its EPCR (see §4); order the pool. |
| 6 | `emitter` | Build, **schema-validate**, and write the submission CSV. |

The known-MVA-gene panel (`mva-genes.tsv`) is drawn from the public literature
(e.g. *BUB1B*, *CEP57*, *TRIP13*, *CENATAC*) — public gene identities, not
proband-derived facts.

**Fail-fast guards.** A misconfigured run must fail loudly, never emit a
degenerate empty submission. The pipeline refuses to proceed when `MVA_GTF` is
unset/missing/gzipped, when the panel BED resolves no gene, or when the panel
yields zero records over a non-empty normalized VCF
([#2044](https://github.com/Replikanti/agentis-colonies/issues/2044)).

## 3. Lens fan-out + refute gate (M3)

Opt-in via `MVA_LENS_MODE=1`. Five **blind lenses** each score the whole
candidate pool from one angle over the substrate memo bus:

- **inheritance-model** lens (de novo / recessive / X-linked / mosaic fit),
- **mosaicism / low-VAF** lens (somatic vs germline, allele-frequency),
- **HPO phenotype-overlap** lens (re-reads the operator-approved HPO set),
- **known-MVA-gene** lens (panel membership),
- **pathway / novel-gene** lens (spindle-assembly-checkpoint and mitotic
  pathways; the inverse discriminator of the known-gene lens).

Each lens score is anchored to a **deterministic prior** grounded in
machine-checkable facts, so a lens is meaningful even before the live model
refines it. An adversarial **refuter** then judges each candidate on four axes
(benign-in-population, wrong-inheritance-fit, phenotype-mismatch, artifact),
**failing open**: an unassessable axis is never counted as a refutation. A
`lens_reconciler` merges lens *agreement* (promotes a candidate a rung) and
*refutation* (demotes into `refuted.tsv`) through the substrate `decide()`, and
`lens_emitter` writes a second submission `agentis-federation_lens.csv` reusing
the baseline schema validator/writer.

Lens mode is **default-off** and additive: with it off, the baseline submission
is byte-for-byte identical.

## 4. EPCR: an evidence-tier ladder, not a fabricated probability

Exomiser's combined score is a *ranking* score, not a calibrated probability;
reading it as "probability of causal relevance" would make every EPCR a
fabricated number. Instead the EPCR is driven by the candidate's **evidence
tier** (`settings/epcr.yml`), and any ranking score only orders candidates
*within* a tier:

| Tier | EPCR | finding_type |
|------|------|--------------|
| known MVA gene, biallelic (hom-alt) | 0.90 | primary |
| known MVA gene, candidate compound-het (unphased) | 0.75 | primary |
| known MVA gene, single rare protein-altering allele | 0.35 | primary |
| phenotype-driven candidate outside the known-gene panel | 0.20 | primary |
| incidental / weak phenotype support | 0.05 | secondary |

`baseline/demo-baseline.sh` pins the resulting ordering against a golden CSV, so
any change to this ladder is deliberate.

### Submission schema

Both emitters write the required GRCh38 format (≤10 rows), validated before
write:

```
proband_id,chrom_1,pos_1,ref_1,alt_1,chrom_2,pos_2,ref_2,alt_2,epcr,finding_type,notes
```

The second allele columns (`*_2`) carry the trans allele of a compound-het
candidate and are otherwise empty.

## 5. Reproducing a run

Grand Rounds runs against operator-provided, gated inputs — nothing gated is
committed, so a fresh checkout cannot reproduce results without them.

1. **Prerequisites.** `./install.sh` (checks tooling + writes `.agentis/config`,
   including the raised `llm.cli_timeout_ms` lens floor,
   [#2046](https://github.com/Replikanti/agentis-colonies/issues/2046)).
   External tools: `bcftools`/`tabix` for normalization and region restriction;
   a GENCODE GTF (e.g. v45, GRCh38) for the gene panel; optionally Exomiser.
2. **Inputs (environment only).** Point `$MVA_DATA_DIR` at the read-only gated
   inputs (the proband VCF, the clinical phenotype document), `$MVA_GTF` at the
   GENCODE GTF, and `$MVA_WORK_DIR` / `$MVA_OUT_DIR` at scratch/output dirs
   **outside** the checkout.
3. **Backend.** The federation drives its `prompt()` calls through the
   flat-cyborg backend (a PTY wrapper over an interactive Claude Code session);
   `baseline/demo-lens-smoke-real.sh` is the operator-run real-backend smoke
   gate that fails on any LLM timeout or an implausibly fast (fallback-only)
   run.
4. **Run.** `./baseline/scripts/start-colony.sh` runs `agentis go
   agents/pipeline.ag`; it pauses at the HPO operator gate, then (on re-run)
   writes `agentis-federation_baseline.csv` to `$MVA_OUT_DIR`. Set
   `MVA_LENS_MODE=1` to additionally produce `agentis-federation_lens.csv`.

The synthetic, gated-data-free fixtures under `baseline/fixtures/` (synthetic
sample names, no HPO literals) drive CI and `demo-baseline.sh`; their purity is
asserted by that demo and by the repo-level `tools/check-no-gated-data.sh` leak
guard.

## 6. Honest caveats

- **Known-gene-anchored.** The strongest EPCR tiers reward candidates in the
  public known-MVA-gene panel. Genuinely novel-gene discovery depends on the
  phenotype-driven and pathway lenses, which are weaker evidence.
- **Mosaicism (M2) is out of scope here.** Low-VAF somatic re-calling from
  BAM/CRAM (Mutect2-style) is a separate milestone; the current pipeline
  reasons over an existing germline VCF, so genuinely low-VAF variants a
  germline caller missed are not yet recovered.
- **Any lens tuning is teaching-to-test unless transfer-validated.** If lenses
  are ever tuned against a solved-case bench, the tuned ranking reflects that
  bench's classes, not a general capability — a distinction any results writeup
  must state.
- **EPCR is a tier label, not a calibrated probability** (see §4).

## References

- Epic: [#2031](https://github.com/Replikanti/agentis-colonies/issues/2031) ·
  License: [`../LICENSE`](../LICENSE) (CC BY 4.0) ·
  Federation overview: [`../README.md`](../README.md)
- Hackathon: https://sagebio-rare-disease-real-kid-mva-hackathon-2026.hf.space/
