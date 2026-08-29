# Grand Rounds — Operator Hackathon Runbook

The MVA Hackathon 2026 steps that a **human operator must drive** — leaderboard
submission, the optional mosaicism deep-dive, the Track 2 report + video, and
post-hackathon data deletion. The code side (baseline pipeline, lens layer,
license, methods report, `grand-rounds-v0.1.0`) is done; this is the checklist
for the parts that need operator credentials, gated data, or a person.

> **Deadline: 2026-10-24 23:59 UTC.** Track 1: ≤6 submissions per participant.
> Track 2: 1 submission per team. Team name: **Agentis Federation**.

All gated inputs and every artifact derived from them live **outside** the repo
checkout, reached only via `$MVA_DATA_DIR` / `$MVA_WORK_DIR` / `$MVA_OUT_DIR`.
Nothing gated — no VCF, BAM, coordinate, HPO id, or clinical detail — ever
enters git (`tools/check-no-gated-data.sh` is the CI gate).

## 1. Track 1 submission (M4) — the immediate, highest-value step

The baseline pipeline already produces a schema-valid ranked CSV
(`$MVA_OUT_DIR/agentis-federation_baseline.csv`); the lens layer produces a
second one (`agentis-federation_lens.csv`) when run with `MVA_LENS_MODE=1`.

1. **Sanity-check the CSV before spending a slot.** Confirm: header matches the
   required schema (`proband_id,chrom_1,pos_1,ref_1,alt_1,chrom_2,pos_2,ref_2,alt_2,epcr,finding_type,notes`),
   ≤10 data rows, GRCh38 `chr`-prefixed contigs, `epcr` in `(0,1]`. See
   [methods.md](./methods.md) §4 for the EPCR evidence-tier ladder.
2. **Submit on the hackathon platform** (Synapse/Hugging Face — the challenge
   space linked from the epic). This requires the operator's registered,
   credentialed account; it cannot be automated from here.
3. **Spend slots deliberately** (≤6 total). A reasonable order: baseline CSV
   first as a scoring-calibration probe, then the lens CSV, then any improved
   run (e.g. after the M2 deep-dive below). Record `take-N = <which CSV + config>`
   next to each submission so the leaderboard delta is attributable.
4. **Track the leaderboard** and paste a rank/score snapshot link into the epic
   issue (#2031) — one live-updated status comment, not a new comment per run.

## 2. Optional mosaicism deep-dive (M2) — score booster, gated + heavy

MVA is mosaic; low-VAF variants a germline caller under-calls are exactly where
extra signal lives. This is **not** in the shipped pipeline (which reasons over
the provided germline VCF) and needs data + compute the automation cannot reach.

**Why it is not automated:** the gated dataset is **raw FASTQ only** (8 files,
~85 GB, R1/R2 × 4 lanes) **plus the germline VCF — there is no aligned
BAM/CRAM.** So there is no coordinate-indexed file to region-slice; M2 requires
the full download, a whole-genome alignment (~a day of CPU), then somatic
calling.

**a. Robust download** (the naive path silently truncates — the xet CAS backend
can exit 0 with files missing):

```bash
# Per-file, resumable, xet disabled; verify count/size against the dataset card.
export HF_HUB_DISABLE_XET=1
hf download SageBio/mva-hackathon-2026-data --repo-type dataset \
    --local-dir "$MVA_DATA_DIR" --include '*.fastq.gz'
# Then VERIFY: 8 fastq.gz present, each ~10–11 GB, sizes match the HF file listing.
```

**b. Toolchain** (not on the host by default; all conda/apt-installable):
`bwa-mem2` or `minimap2` (align), `samtools` (sort/index), a GRCh38 reference
FASTA, and a tumor-only somatic caller (`gatk Mutect2` tumor-only, or
`DeepSomatic`). `bcftools`/`tabix` for VCF handling.

**c. Pipeline outline** (operator-run, outside the repo):
1. Align the FASTQ to GRCh38 → sorted, indexed BAM.
2. Tumor-only somatic calling **restricted to the spindle-assembly-checkpoint
   genes/pathway** (BUB1B, CEP57, TRIP13, CENATAC + pathway) — the targeted
   region keeps calling tractable.
3. Filter for plausible low-VAF candidates the germline VCF missed; feed them
   into the candidate pool and re-run the lens ranking.
4. Submit the improved CSV as a later Track 1 slot (§1).

## 3. Track 2 report + video (M5)

1. **Report** — mechanism characterization grounded in the Track 1 findings
   (disrupted pathway, LoF/GoF, downstream consequence) + drug-repurposing
   candidates with literature/in-silico rationale, written to the organizer's
   methods template. Ground every claim in the actual findings; do not overstate.
2. **Video** — a ≤3-minute pitch (human step).
3. **Submit once** before the deadline (1 Track 2 submission per team).

## 3b. Publication compliance (any public communication)

- Include the organizer acknowledgement paragraph verbatim (now in
  [methods.md](./methods.md) §Acknowledgements) in any report, abstract, blog
  post, or video description arising from participation.
- Cite the dataset using the reference on the Hackathon Synapse page at the
  time of publication.
- Embargo: no peer-reviewed manuscript submissions using the dataset until the
  organizers post their summary/preprint; code, models, and derived outputs
  are shareable any time; conference abstracts/posters need prior written
  organizer approval.
- Never include anything that could re-identify the family beyond their own
  public communications.

## 4. Post-hackathon compliance (M7) — do not skip

1. **Delete all gated data** (`$MVA_DATA_DIR`, `$MVA_WORK_DIR`, `$MVA_OUT_DIR`
   and any derived intermediates) within **30 days of the hackathon close**.
2. **Email the organizer** confirming deletion, per the dataset's gated terms.
3. Set a calendar reminder for the 30-day deadline now.

## Status snapshot

| Item | Owner | State |
|------|-------|-------|
| Baseline + lens pipeline, license, methods report, v0.1.0 release | code | ✅ done |
| M4 leaderboard submission | operator (credentialed) | ☐ |
| M2 mosaicism deep-dive (optional) | operator (gated data + compute) | ☐ |
| M5 Track 2 report + video | operator (human) | ☐ |
| M7 data deletion + confirmation email | operator (human) | ☐ |
