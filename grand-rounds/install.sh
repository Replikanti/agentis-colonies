#!/bin/bash
# install.sh: idempotent setup for the grand-rounds federation.
#
# What it does (all idempotent — safe to re-run):
#   1. Prerequisite checks: agentis, a container runtime (podman/docker), and
#      bcftools (native, or a container wrapper written under $MVA_WORK_DIR).
#   2. Writes/patches baseline/.agentis/config with the exec.env_passthrough
#      allowlist every getenv() knob in agents/pipeline.ag depends on, plus a
#      raised exec.default_timeout_ms and a lens-viable llm.cli_timeout_ms
#      (#2046 — the agentis-core 120 s default aborts every heavy lens prompt
#      on the real flat-cyborg backend). getenv() reads the SANITIZED env, so a
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
ENV_PASSTHROUGH="MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_VCF,MVA_PHENOTYPE_DOC,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_EXOMISER,MVA_EXOMISER_ASSEMBLY,MVA_RUN_EXOMISER,MVA_CONTAINER_CMD,MVA_APPROVAL_FILE,MVA_APPROACH,MVA_LENS_MODE,PANEL_PAD,EXOMISER_TIMEOUT_MS,EXOMISER_JAVA_OPTS,COLONY_DIR"

# Exomiser is an hour-scale run; the sandboxed-exec default of 10 s would abort
# it. This raises the default so every exec sh stage has headroom; the Exomiser
# stage additionally carries an explicit inline timeout in the .ag.
DEFAULT_TIMEOUT_MS="21600000"

# LLM timeouts (#2046). agentis-core's llm.cli_timeout_ms defaults to 120 s,
# but a heavy clinical-genetics lens prompt driven through the real flat-cyborg
# backend takes ~630 s — every M3 lens prompt aborted with [llm.timeout] until
# the operator raised this to 1800 s. Ship lens-viable values for BOTH backend
# styles: llm.cli_timeout_ms caps the whole subprocess either way, and
# llm.flat_cyborg.idle_ms is the native-backend idle cap (the env knobs
# FLAT_CYBORG_TIMEOUT_MS / FLAT_CYBORG_IDLE_MS only reach the WRAPPER path;
# start-colony.sh defaults+exports those, env overrides win).
#
# Precedence per key: MVA_* install-time override > value already present in
# the config (an operator tuning survives re-runs) > the shipped default.
prior_key() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null | tail -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]' || true; }

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

# --- 2. .agentis/config (exec.env_passthrough + timeouts) -------------------

mkdir -p "$AGENTIS_DIR"
touch "$CONFIG"

# Resolve the two LLM-timeout values BEFORE the rewrite: an existing operator
# tuning is kept across re-runs; the MVA_* env override always wins.
LLM_CLI_TIMEOUT_MS="${MVA_LLM_CLI_TIMEOUT_MS:-$(prior_key 'llm\.cli_timeout_ms')}"
LLM_CLI_TIMEOUT_MS="${LLM_CLI_TIMEOUT_MS:-1800000}"
LLM_FC_IDLE_MS="${MVA_LLM_FC_IDLE_MS:-$(prior_key 'llm\.flat_cyborg\.idle_ms')}"
LLM_FC_IDLE_MS="${LLM_FC_IDLE_MS:-600000}"

# Rewrite the managed keys idempotently: strip any prior line, then append
# the current value. Every other line the operator added is preserved.
tmp="$(mktemp)"
grep -vE '^[[:space:]]*(exec\.env_passthrough|exec\.default_timeout_ms|llm\.cli_timeout_ms|llm\.flat_cyborg\.idle_ms|experience\.enabled)[[:space:]]*=' "$CONFIG" > "$tmp" || true
{
    printf 'exec.env_passthrough = %s\n' "$ENV_PASSTHROUGH"
    printf 'exec.default_timeout_ms = %s\n' "$DEFAULT_TIMEOUT_MS"
    printf 'llm.cli_timeout_ms = %s\n' "$LLM_CLI_TIMEOUT_MS"
    printf 'llm.flat_cyborg.idle_ms = %s\n' "$LLM_FC_IDLE_MS"
    # M3 lens mode's refute gate records a best-effort learn() outcome; enabling
    # the experience store lets that telemetry persist (a no-op when lens mode is
    # off, and the refuter wraps learn() in try/catch so it is never fatal).
    printf 'experience.enabled = true\n'
} >> "$tmp"
mv "$tmp" "$CONFIG"
log "wrote exec.env_passthrough allowlist + exec.default_timeout_ms + experience.enabled to $CONFIG"
log "  llm.cli_timeout_ms = $LLM_CLI_TIMEOUT_MS, llm.flat_cyborg.idle_ms = $LLM_FC_IDLE_MS (existing values kept on re-runs; override via MVA_LLM_CLI_TIMEOUT_MS / MVA_LLM_FC_IDLE_MS)"

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
