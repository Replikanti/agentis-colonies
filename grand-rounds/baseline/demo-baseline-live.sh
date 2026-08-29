#!/bin/bash
# demo-baseline-live.sh — live-agent mutation test for the grand-rounds
# baseline colony. Runs the REAL agents through `agentis go` against a
# SYNTHETIC data dir (a tiny VCF, a mini FASTA, a .docx built here, a synthetic
# hp.obo + GTF), and asserts on OUTPUT artifacts. Every assertion is a MUTATION
# check: if the mutated input produces an identical output, the .ag logic is a
# no-op and the test fails.
#
# Requires agentis + bcftools + samtools + zip; SKIPs LOUDLY otherwise (CI has
# no agentis binary — behaviour is pinned here, on an operator's machine).
#
# *** A GREEN RUN HERE DOES NOT CERTIFY THE REAL-BACKEND PATH. *** This test
# wires NO LLM backend, so prompt() returns near-instantly: real flat-cyborg
# latency (~630 s per heavy lens prompt), llm.cli_timeout_ms, and the
# FLAT_CYBORG_* knobs are never exercised — the exact fidelity gap that let
# #2046 ([llm.timeout] on every lens prompt) and #2044 pass a green live test.
# The real-backend gate is ./demo-lens-smoke-real.sh (operator-run).
#
# Stage 3 (Exomiser) is deliberately NOT covered here (multi-tens-of-GB bundle,
# hour-scale run) — it is covered by the operator end-to-end run on real data.
# The panel -> reconcile -> emit chain does not depend on the Exomiser output,
# so these checks exercise stages 1, 2, 4, 5, 6 (M1-M6) plus the opt-in M3 lens
# mode (MVA_LENS_MODE=1): the lens fan-out + refute gate + reconcile (L1-L4).
# Every lens assertion keys on an input-driven STRUCTURAL consequence, never an
# exact LLM score, so it is deterministic under a mock/offline backend too.
#
# Exit 0 all pass, 1 a mutation check failed, 0 with a SKIP notice if prereqs
# are missing.

set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
FIX="$BASE_DIR/fixtures"

# agentis + zip are hard prerequisites (no container substitute).
missing=""
for t in agentis zip; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
done
if [ -n "$missing" ]; then
    echo "[SKIP] demo-baseline-live: missing prerequisite(s):$missing — behaviour check is operator-run."
    exit 0
fi

WORKROOT="$(mktemp -d)"
trap 'rm -rf "$WORKROOT"' EXIT

# Resolve bcftools. Prefer a native install; otherwise wrap the PINNED
# biocontainer so the happy path is exercisable without a native toolchain (the
# reason this test used to SKIP on every machine that lacked bcftools). The
# image must already be present locally — we never pull over the network here.
# samtools is NOT required: the .ag's `bcftools norm -f` lets htslib auto-build
# the reference .fai, so the explicit faidx below is best-effort only.
BCFTOOLS_BIN="bcftools"
if command -v bcftools >/dev/null 2>&1; then
    :
else
    CIMG="${MVA_BCFTOOLS_IMAGE:-quay.io/biocontainers/bcftools:1.19--h8b25389_0}"
    CRUN="${MVA_CONTAINER_CMD:-}"
    if [ -z "$CRUN" ]; then
        if command -v podman >/dev/null 2>&1; then CRUN="podman"
        elif command -v docker >/dev/null 2>&1; then CRUN="docker"; fi
    fi
    if [ -z "$CRUN" ] || ! "$CRUN" image exists "$CIMG" >/dev/null 2>&1; then
        echo "[SKIP] demo-baseline-live: no native bcftools and no local biocontainer ($CIMG) — behaviour check is operator-run."
        exit 0
    fi
    TOOLBIN="$WORKROOT/toolbin"
    mkdir -p "$TOOLBIN"
    # Wrap bcftools so every invocation runs in the container with $WORKROOT
    # bind-mounted at the SAME absolute path (all .ag I/O is absolute + under
    # $WORKROOT). -i keeps stdin attached for piped stages; :z is the SELinux
    # shared-relabel needed on Fedora.
    {
        printf '#!/bin/sh\n'
        printf 'exec %s run --rm -i -v "%s:%s:z" %s bcftools "$@"\n' "$CRUN" "$WORKROOT" "$WORKROOT" "$CIMG"
    } > "$TOOLBIN/bcftools"
    chmod +x "$TOOLBIN/bcftools"
    PATH="$TOOLBIN:$PATH"
    BCFTOOLS_BIN="$TOOLBIN/bcftools"
    echo "  (using containerized bcftools: $CRUN $CIMG)"
fi

pass=0; fail=0
ok() { echo "  [ok] $1"; pass=$((pass + 1)); }
bad() { echo "  [FAIL] $1" >&2; fail=$((fail + 1)); }

# Build a synthetic gated-style data dir from a VCF body file.
build_data_dir() {
    dd="$1"; vcf_src="$2"
    mkdir -p "$dd"
    # Stage the source VCF INTO $dd (under $WORKROOT) so the containerized
    # bcftools — which only bind-mounts $WORKROOT — can read it even when the
    # source is a repo fixture outside the mount.
    cp "$vcf_src" "$dd/src.vcf"
    "$BCFTOOLS_BIN" view -Oz -o "$dd/proband.vcf.gz" "$dd/src.vcf" >/dev/null 2>&1
    "$BCFTOOLS_BIN" index -t "$dd/proband.vcf.gz" >/dev/null 2>&1
    # Minimal .docx: a zip whose word/document.xml wraps the phenotype text.
    ddoc="$WORKROOT/docx"; rm -rf "$ddoc"; mkdir -p "$ddoc/word"
    {
        printf '<?xml version="1.0"?><w:document xmlns:w="x"><w:body>'
        while IFS= read -r linetext; do
            printf '<w:p><w:r><w:t>%s</w:t></w:r></w:p>' "$linetext"
        done < "$FIX/phenotype-source.txt"
        printf '</w:body></w:document>'
    } > "$ddoc/word/document.xml"
    ( cd "$ddoc" && zip -q -r "$dd/phenotype.docx" word )
}

# Build a run copy of the colony + refdata + .agentis/config, then run it.
# Populates $RUN and $OUTDIR; approval is applied when $2 = "approve"; M3 lens
# mode is on when $3 = "1" (default off, so the baseline runs are unchanged).
run_pipeline() {
    dd="$1"; approve="$2"; lens="${3:-0}"
    RUN="$WORKROOT/run.$RANDOM"
    cp -r "$BASE_DIR" "$RUN"
    rm -rf "$RUN/.agentis"
    OUTDIR="$RUN/out"; WORKDIR="$RUN/work"
    mkdir -p "$OUTDIR" "$WORKDIR/refdata"
    cp "$FIX/mini.fa" "$WORKDIR/refdata/ref.fa"
    # Best-effort faidx; if samtools is absent the .ag's `bcftools norm -f` makes
    # htslib auto-build ref.fa.fai on first use, so this is not required.
    if command -v samtools >/dev/null 2>&1; then
        samtools faidx "$WORKDIR/refdata/ref.fa" >/dev/null 2>&1 || true
    fi
    cp "$FIX/panel.gtf" "$WORKDIR/refdata/panel.gtf"
    # Synthetic hp.obo (built here, never committed). The ids are assembled from
    # fragments so this SOURCE carries no concrete HP:<7 digits> literal.
    {
        printf 'format-version: 1.2\n'
        printf '[Term]\nid: HP:%s\nname: Microcephaly\n' '0000252'
        printf '[Term]\nid: HP:%s\nname: Short stature\n' '0004322'
    } > "$WORKDIR/refdata/hp.obo"
    ( cd "$RUN" && agentis init >/dev/null 2>&1 )
    cat > "$RUN/.agentis/config" <<CFG
exec.env_passthrough = MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_APPROVAL_FILE,MVA_APPROACH,MVA_LENS_MODE,MVA_PANEL_ALLOW_PARTIAL,PANEL_PAD,EXOMISER_TIMEOUT_MS,COLONY_DIR
exec.default_timeout_ms = 120000
experience.enabled = true
CFG
    export MVA_DATA_DIR="$dd" MVA_WORK_DIR="$WORKDIR" MVA_OUT_DIR="$OUTDIR"
    export MVA_REF_FASTA="$WORKDIR/refdata/ref.fa" MVA_HPO_OBO="$WORKDIR/refdata/hp.obo"
    export MVA_GTF="$WORKDIR/refdata/panel.gtf" MVA_BCFTOOLS="$BCFTOOLS_BIN"
    export MVA_PANEL_ALLOW_PARTIAL=0
    export MVA_APPROVAL_FILE="$WORKDIR/phenotype/hpo-approved.txt"
    export MVA_APPROACH="baseline" PANEL_PAD="10" EXOMISER_TIMEOUT_MS="1000"
    export MVA_LENS_MODE="$lens"
    export COLONY_DIR="$RUN"
    # Small panel windows: the synthetic contigs are 300 bp.
    ( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
    if [ "$approve" = "approve" ] && [ -f "$WORKDIR/phenotype/hpo-draft.txt" ]; then
        sha256sum "$WORKDIR/phenotype/hpo-draft.txt" | cut -d' ' -f1 > "$MVA_APPROVAL_FILE"
        ( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
    fi
    CSV="$OUTDIR/agentis-federation_baseline.csv"
    LENSCSV="$OUTDIR/agentis-federation_lens.csv"
    MEMODIR="$RUN/.agentis/memo"
    RUNLOG="$RUN/run.log"
}

# Line number of the first CSV row whose notes name $1 ("" if absent).
gene_line() { grep -nF "$1" "$2" 2>/dev/null | head -1 | cut -d: -f1; }

echo "grand-rounds/baseline: live-agent mutation test"

# --- baseline + M1: het -> hom-alt flips the stage-4 classification --------
DD="$WORKROOT/data.base"; build_data_dir "$DD" "$FIX/proband.vcf"
run_pipeline "$DD" approve
cp -f "$CSV" "$WORKROOT/m1-base.csv" 2>/dev/null || true
# Presence check only since #2059 (the hom-alt rides as the secondary
# alternate); R2 pins the leading classification + tiers exactly.
if [ -f "$CSV" ] && grep -q 'biallelic (hom-alt)' "$CSV"; then
    ok "M1 base: BUB1B hom-alt classified biallelic"
else
    bad "M1 base: expected a biallelic BUB1B row in the CSV"
fi

# Flip chr15:120 from 1/1 to 0/1 -> BUB1B now three het -> candidate comp-het.
sed 's#^15\t120\(.*\)1/1#15\t120\11/0#; s#\(15\t120.*GT:AD\t\)1/1#\10/1#' "$FIX/proband.vcf" > "$WORKROOT/m1.vcf"
DD1="$WORKROOT/data.m1"; build_data_dir "$DD1" "$WORKROOT/m1.vcf"
run_pipeline "$DD1" approve
if [ -f "$CSV" ] && grep -q 'candidate compound-het (unphased)' "$CSV" && ! grep -q 'biallelic (hom-alt)' "$CSV"; then
    ok "M1 mutation: het flip changed BUB1B classification to candidate compound-het"
else
    bad "M1 mutation: classification did not change on het flip (stage-4 logic may be a no-op)"
fi

# --- M2: stale/mismatched approval makes the pipeline refuse (no CSV) -------
DD2="$WORKROOT/data.m2"; build_data_dir "$DD2" "$FIX/proband.vcf"
run_pipeline "$DD2" noapprove
if [ ! -f "$CSV" ]; then
    ok "M2: no approval -> D6 gate refuses, no CSV written"
else
    bad "M2: a CSV was written without an approved HPO set (gate did not bite)"
fi
# A deliberately WRONG approval hash must also refuse.
run_pipeline "$DD2" noapprove
printf 'deadbeef\n' > "$WORKROOT/data.m2.wrong"
mkdir -p "$WORKDIR/phenotype"; printf 'deadbeef\n' > "$MVA_APPROVAL_FILE"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
if [ ! -f "$CSV" ]; then
    ok "M2: mismatched approval hash still refuses"
else
    bad "M2: mismatched approval hash produced a CSV"
fi

# --- M3: removing the CEP57 panel hits removes its candidate row -----------
# CEP57 carries two het variants (a candidate compound-het); dropping every
# chr11 record must remove the CEP57 candidate entirely.
grep -vP '^11\t' "$FIX/proband.vcf" > "$WORKROOT/m3.vcf"
DD3="$WORKROOT/data.m3"; build_data_dir "$DD3" "$WORKROOT/m3.vcf"
run_pipeline "$DD3" approve
if [ -f "$CSV" ] && ! grep -q 'CEP57' "$CSV"; then
    ok "M3: removing the CEP57 hit removed its row"
else
    bad "M3: CEP57 row still present after removing its variant"
fi

# --- M4: a schema-invalid candidate makes stage 6 refuse + name the rule ----
# Force an out-of-range EPCR by mutating the run copy's epcr ladder to 0.
DD4="$WORKROOT/data.m4"; build_data_dir "$DD4" "$FIX/proband.vcf"
run_pipeline "$DD4" approve
# Re-run with a corrupted ladder in the SAME run copy.
sed -i "s/epcr: 0.75/epcr: 0/" "$RUN/settings/epcr.yml"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
if [ ! -f "$CSV" ] && grep -q 'epcr-out-of-range' "$RUN/run.log"; then
    ok "M4: epcr=0 -> stage 6 refuses and names 'epcr-out-of-range'"
else
    bad "M4: schema-invalid candidate was not refused with a named rule"
fi

# --- M5: a FILTER-FAILED-only variant still reaches the panel artifact ------
DD5="$WORKROOT/data.m5"; build_data_dir "$DD5" "$FIX/proband.vcf"
run_pipeline "$DD5" approve
if grep -q 'LowVAF' "$WORKDIR/panel-review.tsv" 2>/dev/null; then
    ok "M5: the LowVAF (hard-filter-FAILED) record reached the panel-review artifact"
else
    bad "M5: the FILTER-failed record did not reach panel review (no-'-f PASS' path broken)"
fi

# --- M6: per-stage row counts stay under the .ag boundary limits -----------
if [ -f "$WORKDIR/stage-rows.tsv" ]; then
    overflow="$(awk -F'\t' '$2 > 500 {print}' "$WORKDIR/stage-rows.tsv" || true)"
    if [ -z "$overflow" ]; then
        ok "M6: every stage handed < 500 rows into .ag"
    else
        bad "M6: a stage streamed too many rows into .ag: $overflow"
    fi
else
    bad "M6: stage-rows.tsv was not produced"
fi

# ============================================================================
# G0-G7 (#2044): GTF fail-fast — a broken GTF wiring must REFUSE loudly, never
# emit a silently empty submission. One APPROVED run copy first proves the
# fixture GTF DOES produce a CSV (the mutation contrast, G0); each mutation
# then deletes the CSV, breaks the GTF wiring, re-runs the SAME copy, and must
# leave (a) NO regenerated CSV and (b) its guard token as the LAST entry of
# the PERSISTED abort memo (baseline:abort_reason; the memo appends, so
# `tail -1` attributes the abort to THIS mutation — with the bus_read fix the
# refusal also prints, but the memo is the stable test key). `empty-panel-bed`
# has no mutation: it is pure defense-in-depth, unreachable while the
# coordinator preflight uses the SAME panel_bed_line lookup as the panel stage.
# ============================================================================

DDG="$WORKROOT/data.gtf"; build_data_dir "$DDG" "$FIX/proband.vcf"
run_pipeline "$DDG" approve
if [ -f "$CSV" ]; then
    ok "G0 base: fixture GTF produces the baseline CSV (mutation contrast armed)"
else
    bad "G0 base: no CSV with a working GTF — G1-G7 would be vacuous"
fi
GRUN="$RUN"; GWORK="$WORKDIR"; GMEMO="$MEMODIR"; GCSV="$CSV"

# Re-run the SAME approved copy after a wiring mutation.
g_rerun() {
    rm -f "$GCSV"
    ( cd "$GRUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$GRUN/run.log" 2>&1 ) || true
}
g_check() { # $1 = expected token of THIS mutation, $2 = label
    if [ ! -f "$GCSV" ] \
       && tail -1 "$GMEMO/baseline:abort_reason.jsonl" 2>/dev/null | grep -q "$1"; then
        ok "$2"
    else
        bad "$2 — guard did not bite (CSV regenerated, or last abort memo entry is not '$1')"
    fi
}

export MVA_GTF=""
g_rerun; g_check "no-gtf" "G1: empty MVA_GTF -> coordinator refuses (no-gtf), CSV not regenerated"

export MVA_GTF="$GWORK/refdata/absent.gtf"
g_rerun; g_check "gtf-missing" "G2: absent MVA_GTF file -> coordinator refuses (gtf-missing)"

gzip -c "$GWORK/refdata/panel.gtf" > "$GWORK/refdata/panel.gtf.gz"
export MVA_GTF="$GWORK/refdata/panel.gtf.gz"
g_rerun; g_check "gtf-gzipped" "G3: gzipped MVA_GTF -> coordinator refuses (gtf-gzipped)"

printf 'chrZ\tSYNTH\tgene\t1\t100\t.\t+\t.\tgene_id "SYNGZ"; gene_name "NOTAPANELGENE";\n' \
    > "$GWORK/refdata/nogenes.gtf"
export MVA_GTF="$GWORK/refdata/nogenes.gtf"
g_rerun; g_check "panel-genes-unresolved" "G4: GTF resolving NO panel gene -> coordinator refuses (panel-genes-unresolved)"

mv "$GRUN/settings/mva-genes.tsv" "$GRUN/settings/mva-genes.tsv.off"
export MVA_GTF="$GWORK/refdata/panel.gtf"
g_rerun; g_check "empty-gene-panel" "G5: unreadable mva-genes.tsv -> coordinator refuses (empty-gene-panel)"
mv "$GRUN/settings/mva-genes.tsv.off" "$GRUN/settings/mva-genes.tsv"

# Shift every gene span past the 300 bp synthetic contigs: the preflight still
# resolves all four symbols, the BED is non-empty, but `bcftools view -R`
# matches 0 records over the non-empty normalized VCF.
sed -E 's/\tgene\t[0-9]+\t[0-9]+\t/\tgene\t400\t600\t/; s/\texon\t[0-9]+\t[0-9]+\t/\texon\t410\t590\t/' \
    "$GWORK/refdata/panel.gtf" > "$GWORK/refdata/shifted.gtf"
export MVA_GTF="$GWORK/refdata/shifted.gtf"
g_rerun; g_check "panel-zero-records" "G6: panel windows past every variant -> panel_reviewer refuses (panel-zero-records)"

# G7: PARTIAL resolution + the waiver knob — drop ONE gene (TRIP13) from the
# GTF: strict mode must refuse; MVA_PANEL_ALLOW_PARTIAL=1 must proceed to a
# CSV (one renamed GENCODE symbol must not hard-stop an otherwise-usable run)
# and log the waiver warning.
grep -v 'TRIP13' "$GWORK/refdata/panel.gtf" > "$GWORK/refdata/partial.gtf"
export MVA_GTF="$GWORK/refdata/partial.gtf"
g_rerun; g_check "panel-genes-unresolved" "G7a: one unresolved symbol, strict mode -> refuses (panel-genes-unresolved)"
export MVA_PANEL_ALLOW_PARTIAL=1
g_rerun
if [ -f "$GCSV" ] && grep -q 'MVA_PANEL_ALLOW_PARTIAL' "$GRUN/run.log"; then
    ok "G7b: MVA_PANEL_ALLOW_PARTIAL=1 proceeds to a CSV and logs the waiver warning"
else
    bad "G7b: the partial-panel waiver did not produce a CSV + warning"
fi
export MVA_PANEL_ALLOW_PARTIAL=0

# ============================================================================
# E1-E5 (#2054): Exomiser top-N merge. E1 pins BYTE-identity without a TSV;
# E2 plants an ADVERSARIAL TSV (unprefixed contigs, a readthrough symbol on a
# panel variant's position, a symbolic <DEL> allele, a comma-carrying gene) —
# one bad row must SKIP, never kill the whole submission; E3 pins the cap;
# E4 pins the manifest-pinned staleness guard (TSV without a matching .done
# marker must NOT merge); E5 pins panel precedence/dedup.
# ============================================================================

DDE="$WORKROOT/data.exo"; build_data_dir "$DDE" "$FIX/proband.vcf"
run_pipeline "$DDE" approve
if [ -f "$CSV" ] && cmp -s "$CSV" "$WORKROOT/m1-base.csv"; then
    ok "E1 base: no Exomiser TSV -> CSV byte-identical across runs (deterministic no-TSV path)"
else
    bad "E1 base: no-TSV output not deterministic (differs from the M1 base run of the same code)"
fi
# R1 (#2059): the submission is ranked by epcr — rows must be sorted desc.
if tail -n +2 "$CSV" | cut -d, -f10 | sort -rn -c 2>/dev/null; then
    ok "R1: rows are strictly EPCR-ordered (desc)"
else
    bad "R1: emitted rows are not EPCR-sorted (#2059 regression)"
fi
# R2 (#2059): no suppression — fixture BUB1B has a hom AND >=2 hets, so BOTH
# representations must be emitted: the comphet pair leads (primary), the
# hom-alt rides along as a secondary alternate representation.
if grep 'BUB1B candidate compound-het' "$CSV" | grep -q 'primary' \
   && grep 'BUB1B biallelic (hom-alt)' "$CSV" | grep -q 'alternate representation' \
   && grep 'BUB1B biallelic' "$CSV" | grep -q '0.15,secondary'; then
    ok "R2: pair leads primary, hom-alt kept as 0.15/secondary alternate (no suppression)"
else
    bad "R2: representation suppression or wrong tiers (#2059 regression)"
fi

# The canonical fallback is manifest-pinned: recreate exomiser_runner's
# nvcf|hpo|assembly hash for THIS run (draft file carries a trailing newline;
# the manifest hpo does not).
NVCF_E="$WORKDIR/preproc/normalized.vcf.gz"
HPO_E="$(tr -d '\n' < "$WORKDIR/phenotype/hpo-draft.txt")"
MH_E="$(printf '%s|%s|%s' "$NVCF_E" "$HPO_E" "hg38" | sha256sum | cut -d' ' -f1)"
mkdir -p "$WORKDIR/exomiser"

# E4 first: a TSV WITHOUT the matching marker must not merge (staleness guard).
{
    printf '#RANK\tEXOMISER_GENE_COMBINED_SCORE\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\n'
    printf '1\t0.85\tSYNNOVA\t11\t90\tC\tT\n'
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
if [ -f "$CSV" ] && ! grep -q 'novel-gene' "$CSV"; then
    ok "E4: TSV without a matching .done manifest marker -> panel-only (stale output never merges)"
else
    bad "E4: unpinned Exomiser TSV merged (or no CSV) — staleness guard broken"
fi

# E2: marker planted; adversarial rows. Panel BUB1B sits at chr15:120 (its
# hom-alt row), so the readthrough BUB1B-PAK6 at unprefixed 15:120 collides on
# the variant key and must be SKIPPED, not refused at emit.
touch "$WORKDIR/exomiser/.done.$MH_E"
{
    printf '#RANK\tEXOMISER_GENE_COMBINED_SCORE\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\n'
    printf '1\t0.99\tBUB1B-PAK6\t15\t120\tG\tA\n'
    printf '2\t0.90\tSYNDEL\t11\t80\tC\t<DEL>\n'
    printf '3\t0.88\tSYNCOMMA,ALT\t11\t85\tC\tT\n'
    printf '4\t0.85\tSYNNOVA\t11\t90\tC\tT\n'
    printf '5\t0.30\tSYNNOVB\t5\t150\tA\tG\n'
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
if grep 'SYNNOVA' "$CSV" 2>/dev/null | grep -q 'chr11,90' \
   && grep 'SYNNOVA' "$CSV" 2>/dev/null | grep -q '0.20,primary' \
   && grep 'SYNNOVB' "$CSV" 2>/dev/null | grep -q '0.05,secondary'; then
    ok "E2: adversarial TSV -> SYNNOVA merged chr-normalized (0.20,primary), SYNNOVB incidental (0.05,secondary)"
else
    bad "E2: novel genes missing, unnormalized contig, or wrong tiers"
fi
if [ -f "$CSV" ] && ! grep -q 'BUB1B-PAK6\|SYNDEL\|SYNCOMMA' "$CSV"; then
    ok "E2b: readthrough dup-key, <DEL> allele and comma symbol each SKIPPED (submission survives)"
else
    bad "E2b: an adversarial row leaked into the CSV or killed the whole submission"
fi
# BUB1B legitimately appears twice since #2059 (pair primary + hom alternate);
# the Exomiser dedup check is that NO row came from the planted TSV rows.
if [ "$(grep -c 'BUB1B' "$CSV" 2>/dev/null)" = "2" ] \
   && [ -n "$(gene_line BUB1B "$CSV")" ] && [ -n "$(gene_line SYNNOVA "$CSV")" ] \
   && [ "$(gene_line BUB1B "$CSV")" -lt "$(gene_line SYNNOVA "$CSV")" ]; then
    ok "E5: both BUB1B representations kept, none Exomiser-duplicated, primary precedes the novel gene"
else
    bad "E5: panel precedence/representation/dedup broken"
fi

# E3: 12 novel genes (unprefixed contigs) -> the cap (10) holds, every panel
# candidate survives, the Exomiser tail is trimmed.
{
    printf '#RANK\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\tEXOMISER_GENE_COMBINED_SCORE\n'
    for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
        printf '%s\tSYNN%s\t11\t%s\tC\tT\t0.9\n' "$i" "$i" "$((100 + 10#$i))"
    done
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
e3_rows="$(tail -n +2 "$CSV" 2>/dev/null | grep -c . || true)"
e3_panel=1
for gpanel in BUB1B CEP57 TRIP13 CENATAC; do
    grep -q "$gpanel" "$CSV" 2>/dev/null || e3_panel=0
done
if [ "$e3_rows" = "10" ] && [ "$e3_panel" = "1" ] \
   && grep -q 'SYNN01' "$CSV" 2>/dev/null && ! grep -q 'SYNN12' "$CSV" 2>/dev/null; then
    ok "E3: cap holds at 10, all panel candidates survive, Exomiser tail trimmed"
else
    bad "E3: cap/precedence broken (rows=$e3_rows panel_complete=$e3_panel)"
fi

# --- E6/E7 (#2059): Exomiser-ranked representative selection ----------------
# E6: a TSV ranking BUB1B's hets at chr15:160 + chr15:200 must re-pick the
# pair MEMBERS (old behaviour blindly took the first two hets, 90+160).
{
    printf '#RANK\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\tEXOMISER_GENE_COMBINED_SCORE\n'
    printf '1\tBUB1B\t15\t160\tA\tG\t0.95\n'
    printf '2\tBUB1B\t15\t200\tG\tA\t0.94\n'
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
e6_row="$(grep 'BUB1B candidate compound-het (unphased)' "$CSV" 2>/dev/null | grep primary || true)"
if printf '%s' "$e6_row" | grep -q ',160,' && printf '%s' "$e6_row" | grep -q ',200,' \
   && ! printf '%s' "$e6_row" | grep -q ',90,'; then
    ok "E6: Exomiser ranking re-picks the pair members (160+200, not first-two 90+160)"
else
    bad "E6: pair members not driven by the Exomiser ranking (#2059 regression)"
fi

# E7: when the TOP-ranked hit for the gene is the hom (chr15:120), the hom-alt
# representation must LEAD (primary, 0.90) and the pair becomes the secondary
# alternate.
{
    printf '#RANK\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\tEXOMISER_GENE_COMBINED_SCORE\n'
    printf '1\tBUB1B\t15\t120\tA\tG\t0.97\n'
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
if grep 'BUB1B biallelic (hom-alt)' "$CSV" 2>/dev/null | grep -v 'alternate' | grep -q '0.90,primary' \
   && grep 'BUB1B candidate compound-het' "$CSV" 2>/dev/null | grep -q 'alternate representation'; then
    ok "E7: top-ranked hom flips the leading representation (hom primary, pair alternate)"
else
    bad "E7: leading representation does not follow the top Exomiser hit (#2059 regression)"
fi

# --- E8 (#2060): same-position het+hom must never dup-key-kill the CSV ------
# BUB1B reduced to het@120 + het@160 + hom@120: the pair leads (a=120) and the
# hom alternate shares chrom_1:pos_1 with it — the alternate must be DROPPED
# and the submission must survive (pre-fix: emitter refused the whole CSV on
# the duplicate key and emitted nothing).
awk -v OFS="\t" '!/^15\t90\t/ && !/^15\t200\t/ {print} /^15\t120\t/ {$4="A"; $5="T"; $6=190; $10="0/1:30,28"; print}' \
    "$FIX/proband.vcf" > "$WORKROOT/e8.vcf"
DD8="$WORKROOT/data.e8"; build_data_dir "$DD8" "$WORKROOT/e8.vcf"
run_pipeline "$DD8" approve
e8_pair="$(grep 'BUB1B candidate compound-het' "$CSV" 2>/dev/null || true)"
if [ -f "$CSV" ] && [ "$(grep -c 'BUB1B' "$CSV")" = "1" ] \
   && printf '%s' "$e8_pair" | grep -q ',120,' && printf '%s' "$e8_pair" | grep -q ',160,' \
   && ! grep -q 'BUB1B.*alternate' "$CSV"; then
    ok "E8: same-pos het+hom -> colliding alternate dropped, submission survives (pair 120+160)"
else
    bad "E8: dup-key collision killed the CSV or the alternate leaked (#2060 regression)"
fi

# --- E9 (#2060): a multiallelic split is ONE site, never a pair --------------
# BUB1B's only hets are the two split alleles of a multiallelic 15:160
# (A->G,T; GT 1/2): het_b (distinct-position filter) is empty, so the gene
# must fall through to the hom representation — no compound-het row whose two
# members share a position.
sed -e 's#^15\t160\t\.\tA\tG\t180\tPASS\tGNOMAD_AF=0.0005\tGT:AD\t0/1:30,28#15\t160\t.\tA\tG,T\t180\tPASS\tGNOMAD_AF=0.0005,0.0005\tGT:AD\t1/2:0,28,30#' \
    "$FIX/proband.vcf" | grep -vP '^15\t90\t|^15\t200\t' > "$WORKROOT/e9.vcf"
DD9="$WORKROOT/data.e9"; build_data_dir "$DD9" "$WORKROOT/e9.vcf"
run_pipeline "$DD9" approve
if [ -f "$CSV" ] && grep 'BUB1B biallelic (hom-alt)' "$CSV" 2>/dev/null | grep -q '0.90,primary' \
   && ! grep -q 'BUB1B candidate compound-het' "$CSV"; then
    ok "E9: multiallelic split never forms a same-position pair — falls through to the hom (0.90,primary)"
else
    bad "E9: a one-site 'pair' leaked or the fall-through broke (#2060 regression)"
fi

# --- O1 (#2064): Exomiser gene rank breaks within-tier ties -----------------
# Self-contained copy (E8/E9 replaced $RUN, so the E-block marker is gone):
# fresh approved run = the no-TSV text tie-break (CEP57/chr11 sorts first);
# then a manifest-pinned TSV ranking TRIP13 top must lift TRIP13 above CEP57.
DDO="$WORKROOT/data.o1"; build_data_dir "$DDO" "$FIX/proband.vcf"
run_pipeline "$DDO" approve
o1_pre_c="$(gene_line CEP57 "$CSV")"; o1_pre_t="$(gene_line TRIP13 "$CSV")"
NVCF_O="$WORKDIR/preproc/normalized.vcf.gz"
HPO_O="$(tr -d '\n' < "$WORKDIR/phenotype/hpo-draft.txt")"
MH_O="$(printf '%s|%s|%s' "$NVCF_O" "$HPO_O" "hg38" | sha256sum | cut -d' ' -f1)"
mkdir -p "$WORKDIR/exomiser"
touch "$WORKDIR/exomiser/.done.$MH_O"
{
    printf '#RANK\tGENE_SYMBOL\tCONTIG\tSTART\tREF\tALT\tEXOMISER_GENE_COMBINED_SCORE\n'
    printf '1\tTRIP13\t5\t80\tG\tA\t0.98\n'
} > "$WORKDIR/exomiser/baseline.variants.tsv"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 ) || true
o1_post_c="$(gene_line CEP57 "$CSV")"; o1_post_t="$(gene_line TRIP13 "$CSV")"
if [ -n "$o1_pre_c" ] && [ -n "$o1_pre_t" ] && [ "$o1_pre_c" -lt "$o1_pre_t" ] \
   && [ -n "$o1_post_c" ] && [ -n "$o1_post_t" ] && [ "$o1_post_t" -lt "$o1_post_c" ]; then
    ok "O1: Exomiser rank lifts TRIP13 above CEP57 within the 0.75 tie (text order without a TSV)"
else
    bad "O1: within-tier ordering does not follow the Exomiser rank (pre C<$o1_pre_c> T<$o1_pre_t>, post C<$o1_post_c> T<$o1_post_t>)"
fi

# ============================================================================
# M3 lens mode (MVA_LENS_MODE=1): lens fan-out + refute gate + reconcile.
# Every assertion keys on an input-driven STRUCTURAL consequence (population-AF
# membership in refuted.tsv, VAF-driven promotion ordering), never on an exact
# LLM score — so the checks are deterministic under a mock/offline backend and
# genuine under a live one (the same M1-precedent).
# ============================================================================

# --- L1: wiring + schema — the fan-out runs end-to-end and emits a valid CSV --
DDL="$WORKROOT/data.lens"; build_data_dir "$DDL" "$FIX/proband.vcf"
run_pipeline "$DDL" approve 1
l1_ok=1
for a in lens_inheritance lens_mosaicism lens_hpo lens_known_gene lens_pathway; do
    grep -q "$a: scored" "$RUNLOG" || l1_ok=0
done
grep -q 'refuter:' "$RUNLOG" || l1_ok=0
grep -q 'lens_reconciler:' "$RUNLOG" || l1_ok=0
grep -q 'Verdict: LENS-EMITTED' "$RUNLOG" || l1_ok=0
for k in inheritance mosaicism hpo known_gene pathway; do
    [ -f "$MEMODIR/lens:score:$k.jsonl" ] || l1_ok=0
done
hdr="proband_id,chrom_1,pos_1,ref_1,alt_1,chrom_2,pos_2,ref_2,alt_2,epcr,finding_type,notes"
if [ -f "$LENSCSV" ] && [ "$(head -1 "$LENSCSV")" = "$hdr" ] \
   && [ -f "$WORKDIR/refuted.tsv" ] && [ "$l1_ok" -eq 1 ]; then
    rows="$(tail -n +2 "$LENSCSV" | grep -c . || true)"
    if [ "$rows" -le 10 ] && [ "$rows" -ge 1 ]; then
        ok "L1: five lenses + refuter + reconciler ran; schema-valid lens CSV ($rows rows) + refuted.tsv + score memos"
    else
        bad "L1: lens CSV row count out of range ($rows)"
    fi
else
    bad "L1: lens fan-out did not produce a schema-valid CSV + refuted.tsv + score memos"
fi

# --- L2: refute demotes — a common-population-AF candidate is REFUTED out ----
# Base (rare AF): TRIP13 survives into the lens CSV. Mutate its representative
# variant to a COMMON population AF: the benign-in-population axis must REFUTE it
# into refuted.tsv and OUT of the ranked CSV. A no-op refuter leaves it primary.
if [ -n "$(gene_line TRIP13 "$LENSCSV")" ]; then
    ok "L2 base: TRIP13 (rare AF) survives into the lens CSV"
else
    bad "L2 base: TRIP13 missing from the lens CSV before the AF mutation"
fi
sed '/^5\t80\t/ s/GNOMAD_AF=0.0005/GNOMAD_AF=0.2/' "$FIX/proband.vcf" > "$WORKROOT/l2.vcf"
DD2="$WORKROOT/data.l2"; build_data_dir "$DD2" "$WORKROOT/l2.vcf"
run_pipeline "$DD2" approve 1
if grep -q '^TRIP13.*REFUTED.*benign-in-population' "$WORKDIR/refuted.tsv" 2>/dev/null \
   && [ -z "$(gene_line TRIP13 "$LENSCSV")" ]; then
    ok "L2 mutation: common-AF TRIP13 REFUTED into refuted.tsv and dropped from the lens CSV"
else
    bad "L2 mutation: common-AF TRIP13 was not refuted out of the lens CSV (refute gate a no-op?)"
fi

# --- L3: lens agreement reorders — mutating away an upvote flips the ranking --
# Base: TRIP13's representative variant is low-VAF, so the mosaicism lens upvotes
# it -> lens agreement promotes it one rung ABOVE the normal-VAF CENATAC. Strip
# that upvote (low-VAF -> normal-VAF, still the same comphet tier) and the
# promotion is lost, so CENATAC out-ranks TRIP13: the CSV ordering flips. A
# no-op lens leaves the order unchanged.
run_pipeline "$DDL" approve 1   # base again (fresh run dir)
t_base="$(gene_line TRIP13 "$LENSCSV")"; c_base="$(gene_line CENATAC "$LENSCSV")"
sed '/^5\t80\t/ s#0/1:90,8#0/1:30,28#' "$FIX/proband.vcf" > "$WORKROOT/l3.vcf"
DD3="$WORKROOT/data.l3"; build_data_dir "$DD3" "$WORKROOT/l3.vcf"
run_pipeline "$DD3" approve 1
t_mut="$(gene_line TRIP13 "$LENSCSV")"; c_mut="$(gene_line CENATAC "$LENSCSV")"
if [ -n "$t_base" ] && [ -n "$c_base" ] && [ -n "$t_mut" ] && [ -n "$c_mut" ] \
   && [ "$t_base" -lt "$c_base" ] && [ "$t_mut" -gt "$c_mut" ]; then
    ok "L3: TRIP13 out-ranks CENATAC on lens agreement; stripping the low-VAF upvote flips the order"
else
    bad "L3: ordering did not flip on the agreement mutation (base T<$t_base> C<$c_base>, mut T<$t_mut> C<$c_mut>)"
fi

# --- L4: fail-open — an unassessable candidate is KEPT + refuter-error-tagged -
# Remove CENATAC's representative population AF: the refuter cannot judge
# benign-in-population, so it must KEEP the candidate (never silently drop it)
# and tag it refuter-error. Base (AF present) leaves it un-tagged.
if [ -n "$(gene_line CENATAC "$LENSCSV")" ] && ! grep -q 'CENATAC.*refuter-error' "$LENSCSV"; then
    ok "L4 base: CENATAC (AF present) is assessed and carries no refuter-error tag"
else
    bad "L4 base: CENATAC unexpectedly tagged refuter-error before the AF was removed"
fi
sed '/^5\t300\t/ s/GNOMAD_AF=0.0005/./' "$FIX/proband.vcf" > "$WORKROOT/l4.vcf"
DD4="$WORKROOT/data.l4"; build_data_dir "$DD4" "$WORKROOT/l4.vcf"
run_pipeline "$DD4" approve 1
if [ -n "$(gene_line CENATAC "$LENSCSV")" ] \
   && grep -q 'CENATAC.*\[refuter-error\]' "$LENSCSV" \
   && grep -q '^CENATAC.*refuter-error' "$WORKDIR/refuted.tsv" 2>/dev/null; then
    ok "L4: AF-less CENATAC is KEPT in the lens CSV, tagged refuter-error (fail-open, never dropped)"
else
    bad "L4: fail-open broken — the unassessable CENATAC was dropped or left untagged"
fi

# --- L5 (#2056): caller-style INFO/AF must NOT hard-refute ------------------
# The real-data trap: a raw caller VCF carries INFO/AF = the SAMPLE's allele
# fraction (~0.5 on every het). Swap the population tag for caller-style AF on
# TRIP13's representative variant: the benign axis must NOT fire (no
# population annotation -> LLM skeptic + fail-open KEEP), so TRIP13 stays in
# the lens CSV, tagged — never `REFUTED benign-in-population` (contrast: L2
# proved a genuine common POPULATION AF does refute).
sed '/^5\t80\t/ s/GNOMAD_AF=0.0005/AF=0.5/' "$FIX/proband.vcf" > "$WORKROOT/l5.vcf"
# Declare the caller AF tag with a COMPLETE header line (a prefix-match sed
# here once produced a truncated header that only htslib leniency survived).
sed -i 's/^##INFO=<ID=GNOMAD_AF,.*$/&\n##INFO=<ID=AF,Number=A,Type=Float,Description="caller allele fraction (synthetic)">/' "$WORKROOT/l5.vcf"
DD5L="$WORKROOT/data.l5"; build_data_dir "$DD5L" "$WORKROOT/l5.vcf"
run_pipeline "$DD5L" approve 1
# Determinism note: offline the mock prompt() cannot answer REFUTED, so the
# af-unknown path always lands on the fail-open refuter-error return; a REAL
# backend may legitimately refute — this check belongs to the offline suite.
if [ -n "$(gene_line TRIP13 "$LENSCSV")" ] \
   && grep -q 'TRIP13.*\[refuter-error\]' "$LENSCSV" \
   && ! grep -q '^TRIP13.*REFUTED.*benign-in-population' "$WORKDIR/refuted.tsv" 2>/dev/null; then
    ok "L5: caller-style AF=0.5 (no population tag) does NOT hard-refute — TRIP13 kept + fail-open-tagged (the #2056 real-data trap)"
else
    bad "L5: caller AF read as population AF (TRIP13 refuted/dropped/untagged) — #2056 regression"
fi

echo "grand-rounds/baseline live: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
