# Baseline test fixtures — synthetic, gated-data-free

Everything in this directory is **synthetic** and carries no gated clinical
data. Purity is asserted by [`../demo-baseline.sh`](../demo-baseline.sh) (a
synthetic sample name, `< 100` records, no `HP:` literal) and these files are
the one allowlisted exception in
[`../../../tools/check-no-gated-data.sh`](../../../tools/check-no-gated-data.sh).

| Fixture | Purpose |
|---------|---------|
| `mini.fa` | Two synthetic mini-contigs (`chr15`, `chr11`, 300 bp each). The reference the live test normalises against; REF alleles in `proband.vcf` were derived from this sequence so `bcftools norm -f` is internally consistent. |
| `proband.vcf` | Synthetic proband VCF, sample `SAMPLE_SYNTH`, contigs unprefixed (`15`/`11`) to exercise stage 1's contig rename. Six variants across the two synthetic panel windows: a hom-alt and a candidate compound-het pair in `BUB1B`, a hard-filter-FAILED (`LowVAF`) record, a `CEP57` monoallelic hit, and a benign call. |
| `panel.gtf` | Synthetic GENCODE-style GTF placing `BUB1B` on `chr15` and `CEP57` on `chr11`, so stage 4 can derive the panel BED by gene name. |
| `phenotype-source.txt` | Free-text synthetic vignette. The live test packs it into a `.docx` at run time (no `.docx` is committed) to exercise the phenotype stage. Contains no HPO ids. |

The synthetic `hp.obo` and the `.docx` are built at test time by
`demo-baseline-live.sh` in a temp directory, so no `HP:` literal and no Word
document is ever tracked in git.
