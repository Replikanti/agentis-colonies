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
# Stage 3 (Exomiser) is deliberately NOT covered here (multi-tens-of-GB bundle,
# hour-scale run) — it is covered by the operator end-to-end run on real data.
# The panel -> reconcile -> emit chain does not depend on the Exomiser output,
# so these checks exercise stages 1, 2, 4, 5, 6.
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
# Populates $RUN and $OUTDIR; approval is applied when $2 = "approve".
run_pipeline() {
    dd="$1"; approve="$2"
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
exec.env_passthrough = MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_APPROVAL_FILE,MVA_APPROACH,PANEL_PAD,EXOMISER_TIMEOUT_MS,COLONY_DIR
exec.default_timeout_ms = 120000
CFG
    export MVA_DATA_DIR="$dd" MVA_WORK_DIR="$WORKDIR" MVA_OUT_DIR="$OUTDIR"
    export MVA_REF_FASTA="$WORKDIR/refdata/ref.fa" MVA_HPO_OBO="$WORKDIR/refdata/hp.obo"
    export MVA_GTF="$WORKDIR/refdata/panel.gtf" MVA_BCFTOOLS="$BCFTOOLS_BIN"
    export MVA_APPROVAL_FILE="$WORKDIR/phenotype/hpo-approved.txt"
    export MVA_APPROACH="baseline" PANEL_PAD="10" EXOMISER_TIMEOUT_MS="1000"
    export COLONY_DIR="$RUN"
    # Small panel windows: the synthetic contigs are 300 bp.
    ( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 || true )
    if [ "$approve" = "approve" ] && [ -f "$WORKDIR/phenotype/hpo-draft.txt" ]; then
        sha256sum "$WORKDIR/phenotype/hpo-draft.txt" | cut -d' ' -f1 > "$MVA_APPROVAL_FILE"
        ( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 || true )
    fi
    CSV="$OUTDIR/agentis-federation_baseline.csv"
}

echo "grand-rounds/baseline: live-agent mutation test"

# --- baseline + M1: het -> hom-alt flips the stage-4 classification --------
DD="$WORKROOT/data.base"; build_data_dir "$DD" "$FIX/proband.vcf"
run_pipeline "$DD" approve
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
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 || true )
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
sed -i 's/epcr: 0.90/epcr: 0/' "$RUN/settings/epcr.yml"
rm -f "$CSV"
( cd "$RUN" && agentis go agents/pipeline.ag --enable-exec --enable-messaging >"$RUN/run.log" 2>&1 || true )
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

echo "grand-rounds/baseline live: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
