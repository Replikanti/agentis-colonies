#!/bin/bash
# Start the Baseline colony (part of the Grand Rounds federation).
#
# Usage:
#   ./scripts/start-colony.sh [path/to/colony.toml]
#
# The baseline colony is a one-shot `agentis go` pipeline (preprocess ->
# phenotype -> exomiser -> panel review -> reconcile -> emit), NOT a long-lived
# daemon. This launcher exists as the ONE thing outside the runtime that must
# assert the runtime's own preconditions before the pipeline is trusted with
# gated clinical data:
#
#   * resolve the three data directories (flag/env/default) and REFUSE if a
#     work/out dir resolves inside the git worktree (derived clinical artifacts
#     must never be written into the checkout);
#   * assert the exec.env_passthrough allowlist + raised default timeout are
#     present in .agentis/config — getenv() reads the SANITIZED env, so a
#     missing knob is silently inert (a documented failure mode in this repo);
#   * export the env contract agents/pipeline.ag reads via getenv(), then exec
#     the pipeline.
#
# It does NOT invoke `agentis daemon`, so the daemon-flag allowlist does not
# apply. Exit codes: 0 ok, 2 usage, 3 missing gated data, 4 unsafe work dir,
# 5 unwired exec.env_passthrough allowlist.

set -euo pipefail

POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            echo "start-colony.sh: unknown flag: $1" >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done
if [ ${#POSITIONAL[@]} -gt 0 ]; then
    set -- "${POSITIONAL[@]}"
else
    set --
fi

# Symlink-safe $0 resolution.
SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
COLONY_DIR="$(dirname "$SCRIPT_DIR")"
SETTINGS="$COLONY_DIR/settings"

CONFIG_ARG="${1:-$COLONY_DIR/config/colony.toml}"
if [ ! -f "$CONFIG_ARG" ]; then
    echo "Note: config not found ($CONFIG_ARG) — running with environment inputs only." >&2
    echo "      Copy config/colony.example.toml to config/colony.toml to silence this." >&2
fi

AGENT_FILE="$COLONY_DIR/agents/pipeline.ag"
if [ ! -f "$AGENT_FILE" ]; then
    echo "start-colony.sh: agent file not found: $AGENT_FILE" >&2
    exit 3
fi

if ! command -v agentis >/dev/null 2>&1; then
    echo "start-colony.sh: agentis not found on PATH — install it before running." >&2
    exit 3
fi

# --- Load the checked-in tool pins (public reference data only) ------------
if [ -f "$SETTINGS/tools.env" ]; then
    # shellcheck source=/dev/null
    . "$SETTINGS/tools.env"
fi

# --- Resolve the data directory contract (flag/env/default) ----------------
: "${MVA_DATA_DIR:=$HOME/.mva-hackathon/data}"
: "${MVA_WORK_DIR:=$HOME/.mva-hackathon/work}"
: "${MVA_OUT_DIR:=$MVA_WORK_DIR/out}"

abspath() {
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

MVA_DATA_DIR="$(abspath "$MVA_DATA_DIR")"
MVA_WORK_DIR="$(abspath "$MVA_WORK_DIR")"
MVA_OUT_DIR="$(abspath "$MVA_OUT_DIR")"

# Refuse to write derived clinical artifacts inside the repository checkout.
REPO_ROOT="$(git -C "$COLONY_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$REPO_ROOT" ]; then
    REPO_ROOT="$(abspath "$REPO_ROOT")"
    for d in "$MVA_WORK_DIR" "$MVA_OUT_DIR" "$MVA_DATA_DIR"; do
        case "$d" in
            "$REPO_ROOT"|"$REPO_ROOT"/*)
                echo "start-colony.sh: refusing — $d resolves inside the git worktree ($REPO_ROOT)." >&2
                echo "      Point MVA_WORK_DIR/MVA_OUT_DIR/MVA_DATA_DIR outside the checkout." >&2
                exit 4
                ;;
        esac
    done
fi

if [ ! -d "$MVA_DATA_DIR" ]; then
    echo "start-colony.sh: MVA_DATA_DIR does not exist: $MVA_DATA_DIR" >&2
    exit 3
fi
mkdir -p "$MVA_WORK_DIR" "$MVA_OUT_DIR"

# --- Assert the exec.env_passthrough allowlist ------------------------------
# getenv() in the .ag reads only allowlisted vars. If install.sh has not
# written them, the pipeline would run with every gated path silently empty.
CONFIG_FILE="$COLONY_DIR/.agentis/config"
need_wire=0
if [ ! -f "$CONFIG_FILE" ]; then
    need_wire=1
else
    grep -qE '^[[:space:]]*exec\.env_passthrough[[:space:]]*=.*MVA_DATA_DIR' "$CONFIG_FILE" || need_wire=1
    grep -qE '^[[:space:]]*exec\.default_timeout_ms[[:space:]]*=' "$CONFIG_FILE" || need_wire=1
fi
if [ "$need_wire" -ne 0 ]; then
    echo "start-colony.sh: exec.env_passthrough allowlist is not wired in $CONFIG_FILE." >&2
    echo "      Run ./install.sh, or add these lines to $CONFIG_FILE:" >&2
    echo "  exec.env_passthrough = MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_VCF,MVA_PHENOTYPE_DOC,MVA_HPO_OBO,MVA_GTF,MVA_BCFTOOLS,MVA_EXOMISER,MVA_CONTAINER_CMD,MVA_APPROVAL_FILE,MVA_APPROACH,PANEL_PAD,EXOMISER_TIMEOUT_MS,EXOMISER_JAVA_OPTS,COLONY_DIR" >&2
    echo "  exec.default_timeout_ms = 21600000" >&2
    exit 5
fi

# --- Resolve the rest of the env contract ----------------------------------
: "${MVA_REF_FASTA:=$MVA_WORK_DIR/refdata/${MVA_REF_FASTA_NAME:-GCA_000001405.15_GRCh38_no_alt_analysis_set.fna}}"
: "${MVA_HPO_OBO:=$MVA_WORK_DIR/refdata/hp.obo}"
: "${MVA_GTF:=$MVA_WORK_DIR/refdata/gencode.gtf.gz}"
: "${MVA_BCFTOOLS:=$MVA_WORK_DIR/tools/bin/bcftools}"
if [ ! -x "$MVA_BCFTOOLS" ]; then
    MVA_BCFTOOLS="bcftools"
fi
: "${MVA_EXOMISER:=$MVA_WORK_DIR/tools/bin/exomiser}"
if [ ! -x "$MVA_EXOMISER" ]; then
    MVA_EXOMISER="exomiser"
fi
: "${MVA_CONTAINER_CMD:=podman}"
: "${MVA_APPROVAL_FILE:=$MVA_WORK_DIR/phenotype/hpo-approved.txt}"
: "${MVA_APPROACH:=baseline}"
: "${PANEL_PAD:=${MVA_PANEL_PAD:-5000}}"
: "${EXOMISER_TIMEOUT_MS:=21600000}"
: "${EXOMISER_JAVA_OPTS:=-Xmx16g}"

export MVA_DATA_DIR MVA_WORK_DIR MVA_OUT_DIR MVA_REF_FASTA MVA_HPO_OBO MVA_GTF
export MVA_BCFTOOLS MVA_EXOMISER MVA_CONTAINER_CMD MVA_APPROVAL_FILE MVA_APPROACH
export PANEL_PAD EXOMISER_TIMEOUT_MS EXOMISER_JAVA_OPTS
export COLONY_DIR
[ -n "${MVA_VCF:-}" ] && export MVA_VCF
[ -n "${MVA_PHENOTYPE_DOC:-}" ] && export MVA_PHENOTYPE_DOC

echo "Starting baseline pipeline: agentis go agents/pipeline.ag"
echo "  MVA_DATA_DIR=$MVA_DATA_DIR (read-only gated inputs)"
echo "  MVA_WORK_DIR=$MVA_WORK_DIR"
echo "  MVA_OUT_DIR=$MVA_OUT_DIR"

cd "$COLONY_DIR"
exec agentis go "$AGENT_FILE" \
    --enable-exec \
    --enable-messaging
