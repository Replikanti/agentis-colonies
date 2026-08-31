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
# apply. Exit codes: 0 ok, 2 usage, 3 missing gated data or missing/gzipped
# GTF (#2044), 4 unsafe work dir, 5 unwired managed .agentis/config keys (env
# allowlist / exec timeout / llm.cli_timeout_ms, incl. the lens-mode floor),
# 7 no real LLM backend (llm.backend is mock or unset; MVA_ALLOW_MOCK_BACKEND=1
# overrides for deterministic-stages-only runs, whose output is NOT a valid
# submission).

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
    # #2044: the partial-panel waiver knob must be allowlisted or it is
    # silently inert (getenv() reads the SANITIZED env) — force the re-install.
    grep -qE '^[[:space:]]*exec\.env_passthrough[[:space:]]*=.*MVA_PANEL_ALLOW_PARTIAL' "$CONFIG_FILE" || need_wire=1
    # The Track 2 tools read GR_* knobs; getenv() sees the SANITIZED env, so a
    # pre-PR install would pass this check and then report "GR_X is unset".
    grep -qE '^[[:space:]]*exec\.env_passthrough[[:space:]]*=.*GR_NAMPT_TSV' "$CONFIG_FILE" || need_wire=1
    # #2066: the proband-id knob must be allowlisted or it is silently inert.
    grep -qE '^[[:space:]]*exec\.env_passthrough[[:space:]]*=.*MVA_PROBAND_ID' "$CONFIG_FILE" || need_wire=1
    grep -qE '^[[:space:]]*exec\.default_timeout_ms[[:space:]]*=' "$CONFIG_FILE" || need_wire=1
    # #2046: without a raised llm.cli_timeout_ms the agentis-core 120 s default
    # aborts every heavy lens prompt on the real flat-cyborg backend, so the M3
    # differentiator silently degrades to the baseline-only ranking.
    grep -qE '^[[:space:]]*llm\.cli_timeout_ms[[:space:]]*=' "$CONFIG_FILE" || need_wire=1
fi
if [ "$need_wire" -ne 0 ]; then
    echo "start-colony.sh: the managed .agentis/config keys are not wired in $CONFIG_FILE." >&2
    echo "      Run ./install.sh (idempotent), or add these lines to $CONFIG_FILE:" >&2
    echo "  exec.env_passthrough = MVA_DATA_DIR,MVA_WORK_DIR,MVA_OUT_DIR,MVA_REF_FASTA,MVA_VCF,MVA_PHENOTYPE_DOC,MVA_HPO_OBO,MVA_GTF,MVA_PRIMARY_CONTIGS,MVA_BCFTOOLS,MVA_EXOMISER,MVA_EXOMISER_ASSEMBLY,MVA_RUN_EXOMISER,MVA_CONTAINER_CMD,MVA_APPROVAL_FILE,MVA_APPROACH,MVA_PROBAND_ID,MVA_LENS_MODE,MVA_PANEL_ALLOW_PARTIAL,GR_BIBLIOGRAPHY,GR_VERIFY_MARKER,GR_NAMPT_TSV,PANEL_PAD,EXOMISER_TIMEOUT_MS,EXOMISER_JAVA_OPTS,COLONY_DIR" >&2
    echo "  exec.default_timeout_ms = 21600000" >&2
    echo "  llm.cli_timeout_ms = 1800000" >&2
    exit 5
fi

# The backend itself. `agentis init` writes llm.backend = mock, and install.sh
# manages only the passthrough allowlist and the timeouts — so a colony can pass
# every check above and still have no LLM at all. Under mock, prompt() returns
# nothing: the phenotyper extracts zero HPO terms and (before the guard added
# alongside this check) the run would go on to offer that empty draft for
# approval and emit a schema-valid submission built on no phenotype evidence.
# Refuse here, where it costs seconds instead of an hour.
backend="$(sed -nE 's/^[[:space:]]*llm\.backend[[:space:]]*=[[:space:]]*//p' "$CONFIG_FILE" | tail -1 | tr -d '"'"'"' ')"
if [ -z "$backend" ] || [ "$backend" = "mock" ]; then
    echo "start-colony.sh: llm.backend is '${backend:-unset}' in $CONFIG_FILE." >&2
    echo "      The mock backend returns nothing from prompt(), so the phenotyper would" >&2
    echo "      extract zero HPO terms and this run would produce a submission with no" >&2
    echo "      phenotype evidence behind it. Refusing to start." >&2
    echo "      Wire a real backend (see doc/llm-backend.md), for example:" >&2
    echo "  llm.backend = claude" >&2
    echo "  llm.command = /path/to/your/llm-wrapper.sh" >&2
    echo "      To run the deterministic stages only, without any LLM, set" >&2
    echo "      MVA_ALLOW_MOCK_BACKEND=1 — the result is NOT a valid submission." >&2
    if [ "${MVA_ALLOW_MOCK_BACKEND:-0}" != "1" ]; then
        exit 7
    fi
    echo "start-colony.sh: MVA_ALLOW_MOCK_BACKEND=1 — continuing WITHOUT a real LLM." >&2
fi

# A PRESENT but stale llm.cli_timeout_ms (e.g. a hand-written 120000) passes
# the presence check above yet still aborts every heavy lens prompt — enforce
# a sanity floor when the lens fan-out is actually on. install.sh ships
# 1800000 (~630 s observed per prompt); anything below 600000 can only fail.
if [ "${MVA_LENS_MODE:-0}" = "1" ]; then
    cli_ms="$(grep -E '^[[:space:]]*llm\.cli_timeout_ms[[:space:]]*=' "$CONFIG_FILE" | tail -1 | sed 's/^[^=]*=[[:space:]]*//; s/#.*$//' | tr -d '[:space:]' || true)"
    case "$cli_ms" in
        ''|*[!0-9]*) cli_ms=0 ;;
    esac
    if [ "$cli_ms" -lt 600000 ]; then
        echo "start-colony.sh: llm.cli_timeout_ms = $cli_ms is below the lens floor (600000 ms)." >&2
        echo "      Heavy lens prompts take ~630 s on the real backend (#2046). Re-run ./install.sh" >&2
        echo "      (ships 1800000), raise the key, or run without MVA_LENS_MODE=1." >&2
        exit 5
    fi
fi

# --- Resolve the rest of the env contract ----------------------------------
: "${MVA_REF_FASTA:=$MVA_WORK_DIR/refdata/${MVA_REF_FASTA_NAME:-GCA_000001405.15_GRCh38_no_alt_analysis_set.fna}}"
: "${MVA_HPO_OBO:=$MVA_WORK_DIR/refdata/hp.obo}"
# DECOMPRESSED GENCODE GTF (#2044): the panel BED is derived from it by a
# plain-text grep in the .ag, so a .gz here resolves nothing — the old
# gencode.gtf.gz default was exactly the silent-empty-submission trap.
# fetch-reference-data.sh provisions the decompressed file.
: "${MVA_GTF:=$MVA_WORK_DIR/refdata/gencode.gtf}"
# Primary GRCh38 assembly (chr-prefixed, post-rename). The .ag also defaults
# this, but exporting it keeps the operator-visible contract explicit.
: "${MVA_PRIMARY_CONTIGS:=chr1,chr2,chr3,chr4,chr5,chr6,chr7,chr8,chr9,chr10,chr11,chr12,chr13,chr14,chr15,chr16,chr17,chr18,chr19,chr20,chr21,chr22,chrX,chrY,chrM}"
# The Exomiser stage is opt-in; since #2054 its output IS consumed by reconcile.
: "${MVA_RUN_EXOMISER:=0}"
: "${MVA_EXOMISER_ASSEMBLY:=hg38}"
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
# #2066: challenge-documented proband id literal (e.g. PROBAND01); empty =
# use the VCF sample name.
: "${MVA_PROBAND_ID:=}"
# M3 lens fan-out + refute gate — opt-in (default off; baseline output unchanged).
: "${MVA_LENS_MODE:=0}"
# #2044: waive a PARTIAL panel-symbol miss in the GTF preflight (gene-name
# drift across GENCODE releases). NOTHING resolving still refuses.
: "${MVA_PANEL_ALLOW_PARTIAL:=0}"
: "${PANEL_PAD:=${MVA_PANEL_PAD:-5000}}"
: "${EXOMISER_TIMEOUT_MS:=21600000}"
: "${EXOMISER_JAVA_OPTS:=-Xmx16g}"
# flat-cyborg wrapper-path latency knobs (#2046). A heavy lens prompt takes
# ~630 s on the real backend; the wrapper's own defaults (idle 30 s / total
# 240 s) abort it long before llm.cli_timeout_ms even matters. These reach the
# LLM subprocess via the daemon environment (NOT exec.env_passthrough — they
# are read by the wrapper, not by .ag getenv()), and an operator export wins.
: "${FLAT_CYBORG_TIMEOUT_MS:=1800000}"
: "${FLAT_CYBORG_IDLE_MS:=600000}"

# GTF fail-fast (#2044). The .ag coordinator re-checks this (and symbol
# coverage) as the authoritative gate; refusing here just fails minutes
# earlier, before agentis even launches.
if [ ! -f "$MVA_GTF" ]; then
    echo "start-colony.sh: MVA_GTF does not exist: $MVA_GTF" >&2
    echo "      Run ./scripts/fetch-reference-data.sh (fetches AND decompresses the GENCODE GTF)," >&2
    echo "      or export MVA_GTF pointing at a DECOMPRESSED GENCODE GTF." >&2
    exit 3
fi
case "$MVA_GTF" in
    *.gz)
        echo "start-colony.sh: MVA_GTF is gzip-compressed ($MVA_GTF) — the panel lookup greps" >&2
        echo "      plain text and would resolve NOTHING (empty submission). Decompress it" >&2
        echo "      (gzip -dk) and point MVA_GTF at the .gtf." >&2
        exit 3
        ;;
esac

export MVA_DATA_DIR MVA_WORK_DIR MVA_OUT_DIR MVA_REF_FASTA MVA_HPO_OBO MVA_GTF
export MVA_PRIMARY_CONTIGS
export MVA_BCFTOOLS MVA_EXOMISER MVA_EXOMISER_ASSEMBLY MVA_RUN_EXOMISER
export MVA_CONTAINER_CMD MVA_APPROVAL_FILE MVA_APPROACH MVA_LENS_MODE MVA_PANEL_ALLOW_PARTIAL
[ -n "${MVA_PROBAND_ID:-}" ] && export MVA_PROBAND_ID
export PANEL_PAD EXOMISER_TIMEOUT_MS EXOMISER_JAVA_OPTS
export FLAT_CYBORG_TIMEOUT_MS FLAT_CYBORG_IDLE_MS
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
