#!/bin/bash
# fetch-reference-data.sh: resolve the public reference data the baseline
# pipeline needs into $MVA_WORK_DIR/refdata/ and $MVA_WORK_DIR/tools/.
#
# Justification for this shim (not .ag logic): http_get in the runtime is
# domain-whitelisted and buffers into memory — unusable for the tens of GB of
# resumable, checksum-verified reference bundles here. This is mechanical
# tooling, not decision-shaped logic, so it stays a shell script.
#
# STRICTLY IDEMPOTENT — verify-then-skip on anything already present. A halted
# earlier run may have downloaded some of these; partial files are resumed
# (curl -C -), completed files (marked with a sibling `.complete`) are reused,
# never re-fetched. Fetches:
#   * Exomiser CLI distribution (unzipped)
#   * Exomiser hg38 variant/genome + phenotype data bundles (2406)
#   * chr-prefixed GRCh38 analysis-set FASTA (+ .fai, gunzipped)
#   * hp.obo (HPO ontology)
#   * GENCODE primary-assembly GTF
# and writes $MVA_WORK_DIR/refdata/RESOLVED.env for the .ag Exomiser stage.
#
# Exit codes: 0 ok, 2 usage, 3 missing prerequisite tool.

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
SETTINGS="$COLONY_DIR/settings"

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            echo "Usage: fetch-reference-data.sh"
            echo "  Idempotently fetches public reference data into \$MVA_WORK_DIR/refdata."
            exit 0
            ;;
        *)
            echo "fetch-reference-data.sh: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# shellcheck source=/dev/null
[ -f "$SETTINGS/tools.env" ] && . "$SETTINGS/tools.env"

: "${MVA_WORK_DIR:=$HOME/.mva-hackathon/work}"
REFDATA="$MVA_WORK_DIR/refdata"
TOOLS="$MVA_WORK_DIR/tools"
DOWNLOADS="$TOOLS/downloads"
BIN="$TOOLS/bin"
mkdir -p "$REFDATA" "$DOWNLOADS" "$BIN"

for tool in curl unzip gzip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "fetch: missing prerequisite: $tool" >&2; exit 3; }
done

log() { printf '[grand-rounds/fetch] %s\n' "$*"; }

# Resumable download with a completion marker. Skips when already complete.
fetch() {
    url="$1"
    dest="$2"
    if [ -f "$dest.complete" ] && [ -s "$dest" ]; then
        log "skip (complete): $(basename "$dest")"
        return 0
    fi
    log "fetch: $(basename "$dest")"
    curl -fL --retry 3 -C - -o "$dest" "$url"
    : > "$dest.complete"
}

# --- Exomiser CLI -----------------------------------------------------------
: "${MVA_EXOMISER_VERSION:=14.1.0}"
: "${MVA_EXOMISER_CLI_URL:=https://github.com/exomiser/Exomiser/releases/download/${MVA_EXOMISER_VERSION}/exomiser-cli-${MVA_EXOMISER_VERSION}-distribution.zip}"
CLI_ZIP="$DOWNLOADS/exomiser-cli-${MVA_EXOMISER_VERSION}-distribution.zip"
CLI_DIR="$TOOLS/exomiser-cli-${MVA_EXOMISER_VERSION}"
fetch "$MVA_EXOMISER_CLI_URL" "$CLI_ZIP"
if [ ! -d "$CLI_DIR" ]; then
    log "unzip Exomiser CLI"
    unzip -q -o "$CLI_ZIP" -d "$TOOLS"
fi

# --- Exomiser data bundles (2406) ------------------------------------------
: "${MVA_EXOMISER_DATA_VERSION:=2406}"
: "${MVA_EXOMISER_ASSEMBLY:=hg38}"
: "${MVA_EXOMISER_DATA_BASE_URL:=https://data.monarchinitiative.org/exomiser/data}"
DATA_DIR="$REFDATA/exomiser-data"
mkdir -p "$DATA_DIR"
for bundle in "${MVA_EXOMISER_DATA_VERSION}_${MVA_EXOMISER_ASSEMBLY}" "${MVA_EXOMISER_DATA_VERSION}_phenotype"; do
    zip="$DOWNLOADS/${bundle}.zip"
    fetch "${MVA_EXOMISER_DATA_BASE_URL}/${bundle}.zip" "$zip"
    if [ ! -d "$DATA_DIR/$bundle" ]; then
        log "unzip Exomiser data bundle: $bundle"
        unzip -q -o "$zip" -d "$DATA_DIR"
    fi
done
# --- Exomiser application.properties + wrapper (#2062) ----------------------
# The distribution boots ONLY with a data-directory + assembly data-version in
# application.properties, and its shipped default keeps hg19 ACTIVE (which we
# do not download) — without this block the exomiser stage dies at startup on
# a fresh install ("No GenomeAnalysisService instance provided"). Idempotent:
# managed keys are stripped and re-appended; hg19 defaults are commented out;
# every other distribution line is preserved.
PROPS="$CLI_DIR/application.properties"
if [ -f "$PROPS" ]; then
    tmp="$(mktemp)"
    trap 'rm -f "$tmp"' EXIT
    # || true: grep -vE selecting ZERO lines (empty / all-managed file) must
    # not abort the whole fetch under pipefail — the resume contract above.
    sed 's/^exomiser\.hg19\./#&/' "$PROPS" \
        | grep -vE "^(exomiser\.data-directory|exomiser\.${MVA_EXOMISER_ASSEMBLY}\.data-version|exomiser\.phenotype\.data-version)[= ]" > "$tmp" || true
    {
        echo "exomiser.data-directory=$DATA_DIR"
        echo "exomiser.${MVA_EXOMISER_ASSEMBLY}.data-version=${MVA_EXOMISER_DATA_VERSION}"
        echo "exomiser.phenotype.data-version=${MVA_EXOMISER_DATA_VERSION}"
    } >> "$tmp"
    mv "$tmp" "$PROPS"
    chmod 644 "$PROPS"
    trap - EXIT
    log "provisioned $PROPS (data-directory + ${MVA_EXOMISER_ASSEMBLY}/phenotype ${MVA_EXOMISER_DATA_VERSION}; hg19 defaults disabled)"
fi
# Spring Boot resolves ./application.properties from the WORKING DIRECTORY, so
# the wrapper must run with -w "$CLI_DIR" (the exact operator fix from #2062).
# ALWAYS (re)written: unlike bcftools, a native `exomiser` on PATH is not a
# drop-in (it would run without our properties/CWD), and rewriting self-heals
# the wrapper across version bumps. Generation-time paths are baked as the
# runtime DEFAULTS so a custom-MVA_WORK_DIR fetch keeps working later.
: "${MVA_CONTAINER_CMD:=podman}"
: "${MVA_JRE_IMAGE:=docker.io/library/eclipse-temurin:17-jre}"
: "${MVA_DATA_DIR:=$HOME/.mva-hackathon/data}"
cat > "$BIN/exomiser" <<WRAP
#!/usr/bin/env bash
# Generated by grand-rounds/baseline/scripts/fetch-reference-data.sh — do not edit.
set -euo pipefail
: "\${MVA_DATA_DIR:=$MVA_DATA_DIR}"
: "\${MVA_WORK_DIR:=$MVA_WORK_DIR}"
: "\${EXOMISER_JAVA_OPTS:=-Xmx16g}"
exec ${MVA_CONTAINER_CMD} run --rm --security-opt label=disable \\
    -v "\$MVA_DATA_DIR:\$MVA_DATA_DIR:ro" \\
    -v "\$MVA_WORK_DIR:\$MVA_WORK_DIR" \\
    -w "$CLI_DIR" \\
    "${MVA_JRE_IMAGE}" java \$EXOMISER_JAVA_OPTS \\
    -jar "$CLI_DIR/exomiser-cli-${MVA_EXOMISER_VERSION}.jar" "\$@"
WRAP
chmod +x "$BIN/exomiser"
log "wrote exomiser container wrapper: $BIN/exomiser"

# --- GRCh38 analysis-set FASTA (chr-prefixed) ------------------------------
: "${MVA_REF_BASE_URL:=https://ftp.ncbi.nlm.nih.gov/genomes/all/GCA/000/001/405/GCA_000001405.15_GRCh38/seqs_for_alignment_pipelines.ucsc_ids}"
: "${MVA_REF_FASTA_NAME:=GCA_000001405.15_GRCh38_no_alt_analysis_set.fna}"
FASTA_GZ="$DOWNLOADS/${MVA_REF_FASTA_NAME}.gz"
FASTA="$REFDATA/${MVA_REF_FASTA_NAME}"
fetch "${MVA_REF_BASE_URL}/${MVA_REF_FASTA_NAME}.gz" "$FASTA_GZ"
if [ ! -s "$FASTA" ]; then
    log "gunzip reference FASTA"
    gzip -dc "$FASTA_GZ" > "$FASTA"
fi
# The published .fai indexes the DECOMPRESSED file; fetch it beside the FASTA.
FAI="$REFDATA/${MVA_REF_FASTA_NAME}.fai"
if [ ! -s "$FAI" ]; then
    fetch "${MVA_REF_BASE_URL}/${MVA_REF_FASTA_NAME}.fai" "$FAI"
fi

# --- HPO ontology -----------------------------------------------------------
: "${MVA_HPO_OBO_URL:=https://purl.obolibrary.org/obo/hp.obo}"
fetch "$MVA_HPO_OBO_URL" "$REFDATA/hp.obo"

# --- GENCODE GTF ------------------------------------------------------------
: "${MVA_GENCODE_RELEASE:=45}"
: "${MVA_GENCODE_GTF_URL:=https://ftp.ebi.ac.uk/pub/databases/gencode/Gencode_human/release_${MVA_GENCODE_RELEASE}/gencode.v${MVA_GENCODE_RELEASE}.primary_assembly.annotation.gtf.gz}"
fetch "$MVA_GENCODE_GTF_URL" "$REFDATA/gencode.gtf.gz"
# The panel BED is derived from the GTF by a PLAIN-TEXT grep in the .ag; a
# gzipped GTF resolves nothing and the pipeline refuses it (#2044) — provision
# the decompressed form (same verify-then-skip idempotency as the FASTA above).
GTF="$REFDATA/gencode.gtf"
if [ ! -s "$GTF" ]; then
    log "gunzip GENCODE GTF (the panel lookup greps plain text)"
    # Decompress to .part then mv: an interrupted ~1.5 GB gunzip must not leave
    # a truncated gencode.gtf that passes the -s check on the next run.
    gzip -dc "$REFDATA/gencode.gtf.gz" > "$GTF.part"
    mv "$GTF.part" "$GTF"
fi

# --- Container wrappers for the binary tools --------------------------------
: "${MVA_CONTAINER_CMD:=podman}"
: "${MVA_BCFTOOLS_IMAGE:=quay.io/biocontainers/bcftools:1.19--h8b25389_0}"
: "${MVA_JRE_IMAGE:=docker.io/library/eclipse-temurin:17-jre}"
if ! command -v bcftools >/dev/null 2>&1; then
    cat > "$BIN/bcftools" <<WRAP
#!/usr/bin/env bash
# Generated by grand-rounds/baseline/scripts/fetch-reference-data.sh — do not edit.
set -euo pipefail
: "\${MVA_DATA_DIR:=\$HOME/.mva-hackathon/data}"
: "\${MVA_WORK_DIR:=\$HOME/.mva-hackathon/work}"
exec ${MVA_CONTAINER_CMD} run --rm --security-opt label=disable \\
    -v "\$MVA_DATA_DIR:\$MVA_DATA_DIR:ro" \\
    -v "\$MVA_WORK_DIR:\$MVA_WORK_DIR" \\
    -w "\$MVA_WORK_DIR" \\
    "${MVA_BCFTOOLS_IMAGE}" bcftools "\$@"
WRAP
    chmod +x "$BIN/bcftools"
    log "wrote bcftools container wrapper: $BIN/bcftools"
fi

# --- Record what was resolved ----------------------------------------------
RESOLVED="$REFDATA/RESOLVED.env"
{
    echo "# Resolved by fetch-reference-data.sh — public reference data only."
    echo "MVA_EXOMISER_VERSION=${MVA_EXOMISER_VERSION}"
    echo "MVA_EXOMISER_DATA_VERSION=${MVA_EXOMISER_DATA_VERSION}"
    echo "MVA_EXOMISER_ASSEMBLY=${MVA_EXOMISER_ASSEMBLY}"
    echo "MVA_EXOMISER_CLI_DIR=${CLI_DIR}"
    echo "MVA_EXOMISER_DATA_DIR=${DATA_DIR}"
    echo "MVA_REF_FASTA=${FASTA}"
    echo "MVA_HPO_OBO=${REFDATA}/hp.obo"
    echo "MVA_GTF=${GTF}"
} > "$RESOLVED"
log "wrote $RESOLVED"
log "Done."
