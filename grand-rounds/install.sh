#!/bin/bash
# install.sh: idempotent setup for the grand-rounds federation.
#
# What it does (all idempotent — safe to re-run):
#   1. Prerequisite checks: agentis, a container runtime (podman/docker), and
#      bcftools (native, or a container wrapper written under $MVA_WORK_DIR).
#   2. Writes/patches baseline/.agentis/config with the exec.env_passthrough
#      allowlist every getenv() knob in agents/pipeline.ag depends on, plus a
#      raised exec.default_timeout_ms. getenv() reads the SANITIZED env, so a
#      knob missing from this allowlist is silently inert — this repo has a
#      documented history of that failure mode, so start-colony.sh re-asserts
#      the allowlist and refuses to launch if it drifts.
#   3. Offers to run the reference-data fetch (tens of GB — opt-in).
#
# Nothing here touches gated clinical data. Exit 0 when the federation is ready.

set -euo pipefail

FED_DIR="$(cd "$(dirname "$0")" && pwd)"
COLONY_DIR="$FED_DIR/baseline"
AGENTIS_DIR="$COLONY_DIR/.agentis"
CONFIG="$AGENTIS_DIR/config"

# The env knobs agents/pipeline.ag reads via getenv(). Keep this list in sync
# with the getenv() calls in the .ag and the [baseline] block in
# config/colony.example.toml. start-colony.sh asserts the same set.
ENV_PASSTHROUGH="MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_VCF,MVA_PHENOTYPE_DOC,MVA_HPO_OBO,MVA_GTF,MVA_BCFTOOLS,MVA_EXOMISER,MVA_CONTAINER_CMD,MVA_APPROVAL_FILE,MVA_APPROACH,PANEL_PAD,EXOMISER_TIMEOUT_MS,EXOMISER_JAVA_OPTS,COLONY_DIR"

# Exomiser is an hour-scale run; the sandboxed-exec default of 10 s would abort
# it. This raises the default so every exec sh stage has headroom; the Exomiser
# stage additionally carries an explicit inline timeout in the .ag.
DEFAULT_TIMEOUT_MS="21600000"

log() { printf '[grand-rounds/install] %s\n' "$*"; }
warn() { printf '[grand-rounds/install] warning: %s\n' "$*" >&2; }

log "Installing grand-rounds federation..."

# --- 1. Prerequisites -------------------------------------------------------

missing=0
if ! command -v agentis >/dev/null 2>&1; then
    warn "agentis not found on PATH — install it before running the pipeline."
    missing=1
fi

container_cmd="${MVA_CONTAINER_CMD:-}"
if [ -z "$container_cmd" ]; then
    if command -v podman >/dev/null 2>&1; then
        container_cmd="podman"
    elif command -v docker >/dev/null 2>&1; then
        container_cmd="docker"
    fi
fi
if [ -z "$container_cmd" ]; then
    warn "no container runtime (podman/docker) found — the Exomiser and bcftools"
    warn "container wrappers need one. Set MVA_CONTAINER_CMD or install podman."
else
    log "container runtime: $container_cmd"
fi

if command -v bcftools >/dev/null 2>&1; then
    log "bcftools: $(command -v bcftools)"
elif [ -n "$container_cmd" ]; then
    log "bcftools: not native — fetch-reference-data.sh will write a container wrapper."
else
    warn "bcftools not found and no container runtime to wrap it."
    missing=1
fi

if [ "$missing" -ne 0 ]; then
    warn "prerequisites incomplete; resolve the warnings above, then re-run."
fi

# --- 2. .agentis/config (exec.env_passthrough + timeout) --------------------

mkdir -p "$AGENTIS_DIR"
touch "$CONFIG"

# Rewrite the two managed keys idempotently: strip any prior line, then append
# the current value. Every other line the operator added is preserved.
tmp="$(mktemp)"
grep -vE '^[[:space:]]*(exec\.env_passthrough|exec\.default_timeout_ms)[[:space:]]*=' "$CONFIG" > "$tmp" || true
{
    printf 'exec.env_passthrough = %s\n' "$ENV_PASSTHROUGH"
    printf 'exec.default_timeout_ms = %s\n' "$DEFAULT_TIMEOUT_MS"
} >> "$tmp"
mv "$tmp" "$CONFIG"
log "wrote exec.env_passthrough allowlist + exec.default_timeout_ms to $CONFIG"

# --- 3. Reference data (opt-in) --------------------------------------------

if [ -t 0 ]; then
    printf '[grand-rounds/install] fetch reference data now (tens of GB)? [y/N] '
    read -r reply
    case "$reply" in
        y|Y|yes|YES)
            exec "$COLONY_DIR/scripts/fetch-reference-data.sh"
            ;;
    esac
fi

log "Done. Next:"
log "  1. ./baseline/scripts/fetch-reference-data.sh   # if not fetched above"
log "  2. export MVA_DATA_DIR=... MVA_WORK_DIR=... MVA_OUT_DIR=..."
log "  3. ./baseline/scripts/start-colony.sh"
