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
ENV_PASSTHROUGH="MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_VCF,MVA_PHENOTYPE_DOC,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_EXOMISER,MVA_EXOMISER_ASSEMBLY,MVA_RUN_EXOMISER,MVA_CONTAINER_CMD,MVA_APPROVAL_FILE,MVA_APPROACH,MVA_PROBAND_ID,MVA_LENS_MODE,MVA_PANEL_ALLOW_PARTIAL,GR_BIBLIOGRAPHY,GR_VERIFY_MARKER,GR_NAMPT_TSV,PANEL_PAD,EXOMISER_TIMEOUT_MS,EXOMISER_JAVA_OPTS,COLONY_DIR"

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
# the config (an operator tuning survives re-runs, but only a NUMERIC one at
# or above the floor — keeping a sub-floor value would deadlock against
# start-colony.sh's exit-5 "re-run install.sh" remediation) > shipped default.
prior_key() { grep -E "^[[:space:]]*$1[[:space:]]*=" "$CONFIG" 2>/dev/null | tail -1 | sed 's/^[^=]*=[[:space:]]*//; s/#.*$//' | tr -d '[:space:]' || true; }
# Echo $1 only when it is a plain integer >= $2; empty otherwise.
numeric_at_least() {
    case "$1" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$1" -ge "$2" ]; then printf '%s' "$1"; fi
    return 0
}

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

# --- 2. .agentis repo + config (exec.env_passthrough + timeouts) ------------

# `agentis init` REFUSES when .agentis/ already exists, so creating the
# directory before initialising it permanently prevents initialisation: the
# colony ends up with a config and objects/ but no HEAD, and every `agentis go`
# dies with "refs error: no current branch (HEAD not set)". Earlier revisions
# of this script did exactly that, so repair such a checkout as well as
# initialising a fresh one. The config is the only thing worth preserving.
# `agentis init` REFUSES when .agentis/ already exists, so creating the directory
# before initialising it permanently prevents initialisation: the colony ends up
# with a config and objects/ but no HEAD, and every `agentis go` dies with
# "refs error: no current branch (HEAD not set)". Earlier revisions of this
# script did exactly that, so repair such a checkout as well as initialising a
# fresh one.
#
# Repair is deliberately paranoid. .agentis/ can hold an Ed25519 keypair, memos,
# audit and decision logs, experience and snapshots — none of which this script
# can rebuild. So it repairs ONLY what is provably the empty stub, refuses
# anything else, and never deletes.
#
# -s not -e: agentis treats an EMPTY HEAD as NoCurrentBranch too, so a truncated
# HEAD must be repaired rather than skipped.
if [ ! -s "$AGENTIS_DIR/HEAD" ]; then
    # agentis must be present BEFORE anything is moved. Without this the init
    # below aborts under `set -e` AFTER the mv, leaving no .agentis at all and
    # the only copy of the operator's config inside the backup — and the next
    # run would then init a default config with llm.backend = mock, which the
    # start-colony gate cannot detect because the managed keys are all present.
    if ! command -v agentis >/dev/null 2>&1; then
        echo "install: FATAL — agentis is not on PATH; refusing to touch $AGENTIS_DIR" >&2
        exit 2
    fi

    if [ -d "$AGENTIS_DIR" ]; then
        # An unreadable directory cannot be judged. `[ -e ]` is FALSE on EACCES,
        # so without this every content guard below silently passes and a
        # healthy colony would be moved aside and re-keyed.
        if [ ! -r "$AGENTIS_DIR" ] || [ ! -x "$AGENTIS_DIR" ]; then
            echo "install: FATAL — $AGENTIS_DIR is not readable; refusing to touch it." >&2
            echo "  Fix its permissions and re-run (a previous sudo run is the usual cause)." >&2
            exit 6
        fi

        # Whitelist, not blacklist: a stub is a config and at most an EMPTY
        # objects/. Anything else — identity, memo, audit, decisions, refs,
        # sandbox, experience, snapshots, library, knowledge, prompt_stats — is
        # real state, or a half-finished init, and is not ours to rebuild.
        unexpected=""
        for entry in "$AGENTIS_DIR"/* "$AGENTIS_DIR"/.[!.]*; do
            [ -e "$entry" ] || continue
            base="${entry##*/}"
            case "$base" in
                config) continue ;;
                objects)
                    if [ -z "$(ls -A "$entry" 2>/dev/null)" ]; then continue; fi
                    ;;
            esac
            unexpected="$unexpected $base"
        done
        if [ -n "$unexpected" ]; then
            echo "install: FATAL — $AGENTIS_DIR has no usable HEAD but is not an empty stub." >&2
            echo "  Unexpected entries:$unexpected" >&2
            echo "  This is either a repository holding real state (identity keys, memos," >&2
            echo "  audit or decision logs) or an interrupted \`agentis init\`. Neither is" >&2
            echo "  safe for this script to rebuild. Inspect it, and if you are certain it" >&2
            echo "  is disposable, move it aside yourself and re-run:" >&2
            echo "    mv $AGENTIS_DIR $AGENTIS_DIR.old && ./install.sh" >&2
            exit 6
        fi

        # Save the config BEFORE the mv, so a failing init cannot strand it.
        saved=""
        if [ -s "$CONFIG" ]; then
            saved="$(mktemp)"
            cp "$CONFIG" "$saved"
        fi
        broken="$AGENTIS_DIR.broken-$(date +%Y%m%d%H%M%S)"
        echo "install: $AGENTIS_DIR is an empty stub with no HEAD — moving it to $broken"
        mv "$AGENTIS_DIR" "$broken"
        if ! ( cd "$COLONY_DIR" && agentis init >/dev/null ); then
            echo "install: FATAL — agentis init failed; restoring $broken" >&2
            rm -rf "$AGENTIS_DIR"
            mv "$broken" "$AGENTIS_DIR"
            [ -n "$saved" ] && rm -f "$saved"
            exit 2
        fi
        if [ -n "$saved" ]; then
            cp "$saved" "$CONFIG"
            rm -f "$saved"
        fi
    else
        if ! ( cd "$COLONY_DIR" && agentis init >/dev/null ); then
            echo "install: FATAL — agentis init failed in $COLONY_DIR" >&2
            exit 2
        fi
    fi

    # Post-condition: the whole point of this block. Never continue into the
    # config rewrite on a colony that still cannot run anything.
    if [ ! -s "$AGENTIS_DIR/HEAD" ]; then
        echo "install: FATAL — agentis init produced no usable HEAD in $AGENTIS_DIR" >&2
        exit 2
    fi
fi

mkdir -p "$AGENTIS_DIR"
touch "$CONFIG"

# Resolve the two LLM-timeout values BEFORE the rewrite: an existing operator
# tuning is kept across re-runs; the MVA_* env override always wins. A prior
# value that is non-numeric or below the lens floor start-colony.sh enforces
# (600000) is MIGRATED to the shipped default — otherwise "re-run install.sh"
# would be a no-op against the exit-5 refusal.
prior_cli="$(prior_key 'llm\.cli_timeout_ms')"
kept_cli="$(numeric_at_least "${prior_cli:-}" 600000)"
LLM_CLI_TIMEOUT_MS="${MVA_LLM_CLI_TIMEOUT_MS:-${kept_cli:-1800000}}"
if [ -n "${prior_cli:-}" ] && [ -z "$kept_cli" ]; then
    log "migrating llm.cli_timeout_ms = $prior_cli (non-numeric or below the 600000 ms lens floor) -> $LLM_CLI_TIMEOUT_MS"
fi
kept_idle="$(numeric_at_least "$(prior_key 'llm\.flat_cyborg\.idle_ms')" 1)"
LLM_FC_IDLE_MS="${MVA_LLM_FC_IDLE_MS:-${kept_idle:-600000}}"

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
log "     (provisions the GENCODE GTF *decompressed* — the pipeline refuses a"
log "      .gz MVA_GTF and refuses to run without one, #2044)"
log "  2. export MVA_DATA_DIR=... MVA_WORK_DIR=... MVA_OUT_DIR=..."
log "  3. ./baseline/scripts/start-colony.sh"
