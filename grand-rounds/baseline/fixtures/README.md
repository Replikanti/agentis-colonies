# Baseline test fixtures — synthetic, gated-data-free

Everything in this directory is **synthetic** and carries no gated clinical
data. Purity is asserted by [`../demo-baseline.sh`](../demo-baseline.sh) (a
synthetic sample name, `< 100` records, no `HP:` literal) and these files are
the one allowlisted exception in
[`../../../tools/check-no-gated-data.sh`](../../../tools/check-no-gated-data.sh).

| Fixture | Purpose |
|---------|---------|
| `mini.fa` | Three synthetic mini-contigs (`chr15`, `chr11` 300 bp; `chr5` 480 bp). The reference the live test normalises against; REF alleles in `proband.vcf` were derived from this sequence so `bcftools norm -f` is internally consistent. |
| `proband.vcf` | Synthetic proband VCF, sample `SAMPLE_SYNTH`, contigs unprefixed (`15`/`11`/`5`) to exercise stage 1's contig rename. The `chr15`/`chr11` variants (`BUB1B` hom-alt + compound-het, a `LowVAF` hard-filter record, `CEP57` compound-het) drive the baseline M1–M6 checks. The `chr5` `TRIP13` + `CENATAC` compound-het pairs (with a synthetic `INFO/GNOMAD_AF` on every record) drive the M3 lens checks (L1–L5): the AF is the benign-in-population refute signal and one `TRIP13` variant is low-VAF so the mosaicism lens promotes it. `INFO/GNOMAD_AF` is a synthetic POPULATION frequency (deliberately NOT the caller `AF` tag — a raw caller VCF carries the sample allele fraction there, the #2056 trap), NOT a real annotation. |
| `panel.gtf` | Synthetic GENCODE-style GTF placing `BUB1B` on `chr15`, `CEP57` on `chr11`, and (for the lens checks) `TRIP13` + `CENATAC` on `chr5`, so stage 4 can derive the panel BED by gene name. The `chr5` placement is a test-fixture convenience (the GTF, not `mva-genes.tsv`, supplies the coordinates). |
| `phenotype-source.txt` | Free-text synthetic vignette. The live test packs it into a `.docx` at run time (no `.docx` is committed) to exercise the phenotype stage. Contains no HPO ids. |

The synthetic `hp.obo` and the `.docx` are built at test time by
`demo-baseline-live.sh` in a temp directory, so no `HP:` literal and no Word
document is ever tracked in git.
