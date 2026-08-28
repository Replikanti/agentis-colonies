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

```bash
./install.sh                                   # prerequisite checks + .agentis/config wiring
./baseline/scripts/fetch-reference-data.sh     # idempotent reference-data fetch (tens of GB)
./baseline/scripts/start-colony.sh             # runs `agentis go agents/pipeline.ag`
```

The pipeline **stops** after drafting the HPO set and waits for an operator to
review and approve it (a `sha256` of the reviewed draft is stored, so editing
after approval invalidates the gate). Re-run `start-colony.sh` to resume; the
schema-valid candidate CSV lands at
`$MVA_OUT_DIR/agentis-federation_baseline.csv`.

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
