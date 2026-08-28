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
exec.env_passthrough = MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_APPROVAL_FILE,MVA_APPROACH,MVA_LENS_MODE,PANEL_PAD,EXOMISER_TIMEOUT_MS,COLONY_DIR
exec.default_timeout_ms = 120000
experience.enabled = true
CFG
    export MVA_DATA_DIR="$dd" MVA_WORK_DIR="$WORKDIR" MVA_OUT_DIR="$OUTDIR"
    export MVA_REF_FASTA="$WORKDIR/refdata/ref.fa" MVA_HPO_OBO="$WORKDIR/refdata/hp.obo"
    export MVA_GTF="$WORKDIR/refdata/panel.gtf" MVA_BCFTOOLS="$BCFTOOLS_BIN"
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
sed -i 's/epcr: 0.90/epcr: 0/' "$RUN/settings/epcr.yml"
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
sed '/^5\t80\t/ s/AF=0.0005/AF=0.2/' "$FIX/proband.vcf" > "$WORKROOT/l2.vcf"
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
sed '/^5\t300\t/ s/AF=0.0005/./' "$FIX/proband.vcf" > "$WORKROOT/l4.vcf"
DD4="$WORKROOT/data.l4"; build_data_dir "$DD4" "$WORKROOT/l4.vcf"
run_pipeline "$DD4" approve 1
if [ -n "$(gene_line CENATAC "$LENSCSV")" ] \
   && grep -q 'CENATAC.*\[refuter-error\]' "$LENSCSV" \
   && grep -q '^CENATAC.*refuter-error' "$WORKDIR/refuted.tsv" 2>/dev/null; then
    ok "L4: AF-less CENATAC is KEPT in the lens CSV, tagged refuter-error (fail-open, never dropped)"
else
    bad "L4: fail-open broken — the unassessable CENATAC was dropped or left untagged"
fi

echo "grand-rounds/baseline live: $pass ok, $fail failed"
[ "$fail" -eq 0 ]
