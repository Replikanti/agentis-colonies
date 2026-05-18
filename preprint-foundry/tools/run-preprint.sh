#!/bin/bash
# run-preprint.sh -- preprint-generation orchestrator for the
# preprint-foundry federation (#596).
#
# Tails a claim-auditor `audit-ledger.jsonl` file, picks rows where
# audit_verdict == VERIFIED_NEW AND confidence >= AUDITOR_CONFIDENCE_FLOOR,
# resolves the cross-federation memo context (formulator problem +
# answer + novelty + explorer code/output from the original
# math-foundry run, plus claim-auditor's per-searcher reports), seeds
# them into the preprint container's memo as `claim:*:tick-N` keys,
# and lets the five colonies (introducer / theorist / computer /
# editor / submitter) tick through their phased pipeline.
#
# Architectural shape mirrors claim-auditor/tools/run-auditor.sh
# (emit_step helper, run dir under preprint-foundry/runs/<ts>/,
# `podman run --replace` idiom) which itself mirrors math-foundry/
# tools/run-foundry.sh. The producer-consumer contract is:
#   math-foundry → claim-auditor → preprint-foundry → arXiv (via HITL)
#
# Env vars (all optional except the two SOURCE paths; defaults shown):
#   PREPRINT_SOURCE_AUDIT_RUN   Path to claim-auditor run dir whose
#                               audit-ledger.jsonl this preprint run
#                               consumes. Required when not dry-run.
#   PREPRINT_SOURCE_FOUNDRY_RUN Path to original math-foundry run dir
#                               referenced by the audit row's
#                               `source_run` field. Required when not
#                               dry-run (the orchestrator probes its
#                               `.agentis/memo/` for formulator +
#                               explorer keys).
#   PREPRINT_LLM_BACKEND        llm.backend value injected into hermetic
#                               config. Default: claude
#   PREPRINT_CLAUDE_MODEL       Default model. Default: opus (drafting
#                               needs reasoning).
#   PREPRINT_CLAUDE_EFFORT      Default effort. Default: medium
#   PREPRINT_HOST_CLAUDE_DIR    Host path bind-mounted to /root/.claude.
#                               Default: $HOME/.claude
#   PREPRINT_TICK_INTERVAL_S    Seconds between ticks. Default 180
#                               (LaTeX compile + Opus call is slow).
#   PREPRINT_TOTAL_TICKS        Number of ticks to drive. Default 30.
#   PREPRINT_AUDITOR_CONFIDENCE_FLOOR
#                               Skip audit rows below this confidence.
#                               Default 0.7
#   PREPRINT_AUTHOR_CONFIG      Path to authors.toml (required for the
#                               submitter colony's arxiv-metadata.json).
#                               Default: <fed>/config/authors.toml
#   PREPRINT_DAEMON_CB_PER_TICK Per-tick CB replenishment.
#                               Default 2000 (mirrors trading-binance #579).
#   PREPRINT_DAEMON_HEARTBEAT_MS
#                               Watchdog heartbeat (ms). Default 1800000.
#   PREPRINT_LATEXMK_MAX_PASSES Max latexmk attempts inside editor.ag.
#                               Default 3 (initial + one repair pass).
#   PREPRINT_RUN_DIR            Output dir override. Default:
#                               auto-timestamped under preprint-foundry/runs/
#   PREPRINT_IMAGE_TAG          Container image tag built from
#                               Containerfile.preprint.
#                               Default: preprint-foundry:latest
#   PREPRINT_ARXIV_GATEWAY      arXiv submission email. Default:
#                               submit@arxiv.org
#   PREPRINT_ARXIV_FROM         From: header for the SMTP message.
#                               Default: read from authors.toml first author.
#   PREPRINT_SMTP_HOST          SMTP relay host. Default: localhost
#   PREPRINT_SMTP_PORT          SMTP relay port. Default: 25
#   PREPRINT_DRY_RUN            1 = emit_step the plan, skip podman.
#                               Default: "" (real run).
#
# Flags:
#   --dry-run                  Same as PREPRINT_DRY_RUN=1.
#   --source-audit-run <path>  Same as PREPRINT_SOURCE_AUDIT_RUN.
#   --source-foundry-run <path> Same as PREPRINT_SOURCE_FOUNDRY_RUN.
#
# Output layout (under preprint-foundry/runs/<YYYYMMDDTHHMMSSZ>/):
#   orchestrator.log              orchestrator's own log
#   run-meta.json                 config dump
#   preprint-ledger.jsonl         per-claim status rows (DRAFTED / SUBMITTED / ...)
#   laptop-node/
#     bootstrap.sh                container bootstrap (real run only)
#     .agentis/
#       sandbox/                  per-daemon scratch
#       logs/
#       spend/
#     preprints/<claim-id>/       per-claim main.tex / main.pdf /
#                                 reproducibility.* / arxiv-metadata.json /
#                                 submission.tar.gz
#
# Exit codes:
#   0   preprint run completed (or dry-run plan emitted)
#   1   prerequisite missing (podman, python3 outside dry-run)
#   2   invalid env / flag
#   3   source ledger unreadable / no VERIFIED_NEW rows above floor
#   4   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${PREPRINT_DRY_RUN:-0}"
SOURCE_AUDIT_FLAG=""
SOURCE_FOUNDRY_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --source-audit-run)
            if [ -z "${2:-}" ]; then
                echo "run-preprint: --source-audit-run requires a path" >&2
                exit 2
            fi
            SOURCE_AUDIT_FLAG="$2"
            shift 2
            ;;
        --source-foundry-run)
            if [ -z "${2:-}" ]; then
                echo "run-preprint: --source-foundry-run requires a path" >&2
                exit 2
            fi
            SOURCE_FOUNDRY_FLAG="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "run-preprint: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
SOURCE_AUDIT_RUN="${SOURCE_AUDIT_FLAG:-${PREPRINT_SOURCE_AUDIT_RUN:-}}"
SOURCE_FOUNDRY_RUN="${SOURCE_FOUNDRY_FLAG:-${PREPRINT_SOURCE_FOUNDRY_RUN:-}}"
LLM_BACKEND="${PREPRINT_LLM_BACKEND:-claude}"
CLAUDE_MODEL="${PREPRINT_CLAUDE_MODEL:-opus}"
CLAUDE_EFFORT="${PREPRINT_CLAUDE_EFFORT:-medium}"
HOST_CLAUDE_DIR="${PREPRINT_HOST_CLAUDE_DIR:-$HOME/.claude}"
TICK_INTERVAL_S="${PREPRINT_TICK_INTERVAL_S:-180}"
TOTAL_TICKS="${PREPRINT_TOTAL_TICKS:-30}"
CONFIDENCE_FLOOR="${PREPRINT_AUDITOR_CONFIDENCE_FLOOR:-0.7}"
AUTHOR_CONFIG="${PREPRINT_AUTHOR_CONFIG:-$FED_DIR/config/authors.toml}"
DAEMON_CB_PER_TICK="${PREPRINT_DAEMON_CB_PER_TICK:-2000}"
DAEMON_HEARTBEAT_MS="${PREPRINT_DAEMON_HEARTBEAT_MS:-1800000}"
LATEXMK_MAX_PASSES="${PREPRINT_LATEXMK_MAX_PASSES:-3}"
IMAGE_TAG="${PREPRINT_IMAGE_TAG:-preprint-foundry:latest}"
ARXIV_GATEWAY="${PREPRINT_ARXIV_GATEWAY:-submit@arxiv.org}"
ARXIV_FROM="${PREPRINT_ARXIV_FROM:-}"
SMTP_HOST="${PREPRINT_SMTP_HOST:-localhost}"
SMTP_PORT="${PREPRINT_SMTP_PORT:-25}"

# --- Validation ---
val=""
for var_name in TICK_INTERVAL_S TOTAL_TICKS LATEXMK_MAX_PASSES SMTP_PORT; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-preprint: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

if [ "$TICK_INTERVAL_S" -lt 1 ]; then
    echo "run-preprint: PREPRINT_TICK_INTERVAL_S must be >= 1 (got: $TICK_INTERVAL_S)" >&2
    exit 2
fi
if [ "$TOTAL_TICKS" -lt 1 ]; then
    echo "run-preprint: PREPRINT_TOTAL_TICKS must be >= 1 (got: $TOTAL_TICKS)" >&2
    exit 2
fi

if [ "$DRY_RUN" = "0" ]; then
    if [ -z "$SOURCE_AUDIT_RUN" ]; then
        echo "run-preprint: PREPRINT_SOURCE_AUDIT_RUN (or --source-audit-run) is required" >&2
        exit 2
    fi
    if [ -z "$SOURCE_FOUNDRY_RUN" ]; then
        echo "run-preprint: PREPRINT_SOURCE_FOUNDRY_RUN (or --source-foundry-run) is required" >&2
        exit 2
    fi
    if [ ! -d "$SOURCE_AUDIT_RUN" ] && [ ! -f "$SOURCE_AUDIT_RUN" ]; then
        echo "run-preprint: PREPRINT_SOURCE_AUDIT_RUN does not exist: $SOURCE_AUDIT_RUN" >&2
        exit 3
    fi
    if [ ! -d "$SOURCE_FOUNDRY_RUN" ]; then
        echo "run-preprint: PREPRINT_SOURCE_FOUNDRY_RUN does not exist: $SOURCE_FOUNDRY_RUN" >&2
        exit 3
    fi
fi

# Resolve audit-ledger path.
SOURCE_AUDIT_LEDGER=""
if [ -n "$SOURCE_AUDIT_RUN" ]; then
    if [ -f "$SOURCE_AUDIT_RUN" ]; then
        SOURCE_AUDIT_LEDGER="$(cd "$(dirname "$SOURCE_AUDIT_RUN")" && pwd)/$(basename "$SOURCE_AUDIT_RUN")"
    elif [ -d "$SOURCE_AUDIT_RUN" ]; then
        SOURCE_AUDIT_LEDGER="$(cd "$SOURCE_AUDIT_RUN" && pwd)/audit-ledger.jsonl"
    else
        SOURCE_AUDIT_LEDGER="$SOURCE_AUDIT_RUN"
    fi
fi

SOURCE_FOUNDRY_DIR=""
if [ -n "$SOURCE_FOUNDRY_RUN" ] && [ -d "$SOURCE_FOUNDRY_RUN" ]; then
    SOURCE_FOUNDRY_DIR="$(cd "$SOURCE_FOUNDRY_RUN" && pwd)"
elif [ -n "$SOURCE_FOUNDRY_RUN" ]; then
    SOURCE_FOUNDRY_DIR="$SOURCE_FOUNDRY_RUN"
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${PREPRINT_RUN_DIR:-$FED_DIR/runs/$TS}"
ORCH_LOG="$RUN_DIR/orchestrator.log"
RUN_META="$RUN_DIR/run-meta.json"
LAPTOP_DIR="$RUN_DIR/laptop-node"
PREPRINT_LEDGER="$RUN_DIR/preprint-ledger.jsonl"

# --- Dry-run / real-run dispatch helpers ---
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$ORCH_LOG"
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

emit_step() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '# %s\n' "$*"
    else
        printf '# %s\n' "$*" >>"$ORCH_LOG"
    fi
}

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    for bin in podman python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-preprint: $bin not found on PATH" >&2
            exit 1
        fi
    done
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$LAPTOP_DIR/.agentis/sandbox" "$LAPTOP_DIR/.agentis/logs" "$LAPTOP_DIR/.agentis/spend" "$LAPTOP_DIR/preprints"
    : >"$ORCH_LOG"
    : >"$PREPRINT_LEDGER"
fi

emit_step "run-preprint: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "source audit ledger: $SOURCE_AUDIT_LEDGER"
emit_step "source foundry dir: $SOURCE_FOUNDRY_DIR"
emit_step "tick interval: ${TICK_INTERVAL_S}s"
emit_step "total ticks: $TOTAL_TICKS"
emit_step "llm backend: $LLM_BACKEND"
emit_step "claude model: $CLAUDE_MODEL"
emit_step "confidence floor: $CONFIDENCE_FLOOR"
emit_step "latexmk max passes: $LATEXMK_MAX_PASSES"
emit_step "image tag: $IMAGE_TAG"
emit_step "arxiv gateway: $ARXIV_GATEWAY (HITL-gated; never auto-sent)"
emit_step "author config: $AUTHOR_CONFIG"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.preprint $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
write_bootstrap() {
    bootstrap_path="$LAPTOP_DIR/bootstrap.sh"
    emit_step "generating bootstrap script at $bootstrap_path (colonies=5)"

    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "write-bootstrap path=$bootstrap_path colonies=introducer,theorist,computer,editor,submitter"
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-preprint.sh -- runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        printf '{\n'
        printf '  printf "exec.env_passthrough = DAEMON_ID,COLONY_NAME,DISCOVERY_LEDGER,AGENTIS_ROOT,PREPRINT_OUTPUT_ROOT,PREPRINT_AUTHOR_CONFIG,PREPRINT_LATEXMK_MAX_PASSES,PREPRINT_ARXIV_GATEWAY,PREPRINT_ARXIV_FROM,PREPRINT_SMTP_HOST,PREPRINT_SMTP_PORT\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        printf '  printf "daemon.heartbeat_interval_ms = %s\\n"\n' "$DAEMON_HEARTBEAT_MS"
        # PII allow: LaTeX bodies + arxiv abstracts + GAP output all
        # contain long numeric runs that the agentis-core PII heuristic
        # flags. Mirrors math-foundry / claim-auditor (#581).
        printf '  printf "pii_transmit = allow\\n"\n'
        # Memo cap bump: 5 colonies x 30 ticks x per-pid keys + per-claim
        # status keys fills the default 500 fast. Mirrors #587.
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "claude" ]; then
            printf '  printf "llm.command = claude\\n"\n'
            # Phase 1: single backend block applies to all 5 colonies.
            # Per-colony split (Opus for introducer/theorist/editor,
            # Sonnet for computer/submitter) is Phase 2 and requires
            # per-colony AGENTIS_ROOT.
            printf '  printf "llm.args = -p --output-format json --model %s --tools \\"\\" --system-prompt \\"You are a research mathematician drafting an arXiv preprint. Output only valid JSON.\\" --effort %s\\n"\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT"
        fi
        printf '} >> .agentis/config\n'
        printf 'for c in introducer theorist computer editor submitter; do\n'
        printf '    cp -r /repo/preprint-foundry/$c /run-root/$c\n'
        printf 'done\n'
        printf 'cp -r /repo/preprint-foundry/tools /run-root/tools\n'
        printf 'mkdir -p /run-root/.agentis/sandbox /run-root/.agentis/logs /run-root/config /run-root/preprints\n'
        printf 'if [ -f /repo/preprint-foundry/config/authors.toml ]; then cp /repo/preprint-foundry/config/authors.toml /run-root/config/authors.toml; fi\n'
        printf ': > /run-root/preprint-ledger.jsonl\n'
        printf 'for c in introducer theorist computer editor submitter; do\n'
        printf '    (cd /run-root && agentis memo set $c:confidence 0.7 >/dev/null 2>&1 || true)\n'
        printf 'done\n'
        # Daemon tick intervals are intentionally much shorter than the
        # orchestrator's tick (= the rate at which replay:current_tick
        # advances). If daemon tick == orchestrator tick, daemons race
        # the orchestrator and consistently miss state changes — they
        # poll right before the orchestrator writes the new
        # current_tick and then sleep for the full interval, so the
        # first useful read is one cycle late or more. Daemons polling
        # at 30s catch any orchestrator advance within 30s.
        # The submitter polls fast anyway (waits for the
        # human-approval memo flip; #596 §HITL).
        printf 'DAEMON_TICK_INTERVAL_MS=30000\n'
        printf 'EDITOR_TICK_INTERVAL_MS=30000\n'
        printf 'SUBMITTER_TICK_INTERVAL_MS=30000\n'
        printf 'for c in introducer theorist computer; do\n'
        printf '    DAEMON_ID=1 COLONY_NAME=$c DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/$c/agents/$c.ag --colony $c --enable-exec --enable-messaging --tick-interval "$DAEMON_TICK_INTERVAL_MS" > /run-root/.agentis/logs/$c-1.log 2>&1 &\n' "$LATEXMK_MAX_PASSES"
        printf 'done\n'
        printf 'DAEMON_ID=1 COLONY_NAME=editor DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_LATEXMK_MAX_PASSES=%s agentis daemon /run-root/editor/agents/editor.ag --colony editor --enable-exec --enable-messaging --tick-interval "$EDITOR_TICK_INTERVAL_MS" > /run-root/.agentis/logs/editor-1.log 2>&1 &\n' "$LATEXMK_MAX_PASSES"
        printf 'DAEMON_ID=1 COLONY_NAME=submitter DISCOVERY_LEDGER=/run-root/preprint-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis PREPRINT_OUTPUT_ROOT=/run-root/preprints PREPRINT_AUTHOR_CONFIG=/run-root/config/authors.toml PREPRINT_ARXIV_GATEWAY=%s PREPRINT_ARXIV_FROM=%s PREPRINT_SMTP_HOST=%s PREPRINT_SMTP_PORT=%s agentis daemon /run-root/submitter/agents/submitter.ag --colony submitter --enable-exec --enable-messaging --tick-interval "$SUBMITTER_TICK_INTERVAL_MS" > /run-root/.agentis/logs/submitter-1.log 2>&1 &\n' \
            "$ARXIV_GATEWAY" "$ARXIV_FROM" "$SMTP_HOST" "$SMTP_PORT"
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

# --- 3) Spawn the container ---
spawn_container() {
    emit_step "spawning preprint-foundry container (image=$IMAGE_TAG)"
    if [ "$LLM_BACKEND" = "claude" ]; then
        emit_cmd "podman run -d --replace --name preprint-foundry-laptop -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw -v $HOST_CLAUDE_DIR:/root/.claude:rw,z $IMAGE_TAG /run-root/bootstrap.sh"
    else
        emit_cmd "podman run -d --replace --name preprint-foundry-laptop -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
    fi
}

# --- 4) Cleanup trap ---
AUTO_PROMOTE_PID=""
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm container; kill sidecars)"
    # shellcheck disable=SC2064  # Expand $AUTO_PROMOTE_PID at trigger time.
    emit_cmd "trap '[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; podman stop --time 5 preprint-foundry-laptop 2>/dev/null || true; podman rm -f preprint-foundry-laptop 2>/dev/null || true' EXIT INT TERM"
}

# --- 4.5) Auto-promote sidecar (#622) ---
# Spawns a background loop that invokes tools/auto-promote.sh in
# --containerized mode every AP_INTERVAL seconds. Cwd is the host-side
# bind-mount root ($LAPTOP_DIR == <run-dir>/laptop-node/) where the
# container's .agentis/ state materialises. Self-terminates when no
# daemons report `state="running"`. The cleanup trap installed above
# kills it on orchestrator EXIT/INT/TERM.
#
# Env knobs:
#   PREPRINT_AUTO_PROMOTE             1 enable (default), 0 disable
#   PREPRINT_AUTO_PROMOTE_INTERVAL_S  seconds between sidecar ticks
#                                     (default 300)
start_auto_promote_sidecar() {
    AP_ENABLED="${PREPRINT_AUTO_PROMOTE:-1}"
    AP_INTERVAL="${PREPRINT_AUTO_PROMOTE_INTERVAL_S:-300}"
    if [ "$AP_ENABLED" != "1" ]; then
        emit_step "auto-promote sidecar: disabled via PREPRINT_AUTO_PROMOTE=$AP_ENABLED"
        return 0
    fi
    AP_SCRIPT="$REPO_ROOT/tools/auto-promote.sh"
    AP_CONFIG="$REPO_ROOT/tools/auto-promote-config.preprint-foundry.yaml"
    AP_LOG_DIR="$LAPTOP_DIR/.agentis/logs"
    AP_LOG="$AP_LOG_DIR/auto-promote.log"
    AP_STAMP="$AP_LOG_DIR/auto-promote.sidecar_started_at"
    if [ ! -x "$AP_SCRIPT" ]; then
        emit_step "auto-promote sidecar: $AP_SCRIPT not executable, skipping"
        return 0
    fi
    if [ ! -f "$AP_CONFIG" ]; then
        emit_step "auto-promote sidecar: $AP_CONFIG missing, skipping"
        return 0
    fi
    emit_step "starting auto-promote sidecar (interval=${AP_INTERVAL}s, log=$AP_LOG)"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "auto-promote-sidecar placeholder: cwd=$LAPTOP_DIR config=$AP_CONFIG interval=${AP_INTERVAL}s"
        return 0
    fi
    mkdir -p "$AP_LOG_DIR"
    date +%s > "$AP_STAMP"
    (
        cd "$LAPTOP_DIR"
        while :; do
            if ! agentis daemon list --json 2>/dev/null | grep -Fq '"state":"running"'; then
                printf '=== %s: no running daemons; sidecar exiting ===\n' \
                    "$(date -Iseconds)" >> "$AP_LOG"
                exit 0
            fi
            {
                printf '=== %s: sidecar tick ===\n' "$(date -Iseconds)"
                "$AP_SCRIPT" "$LAPTOP_DIR" --containerized --config "$AP_CONFIG" 2>&1 \
                    || printf '[sidecar] auto-promote.sh exited %s\n' "$?"
            } >> "$AP_LOG"
            sleep "$AP_INTERVAL"
        done
    ) &
    AUTO_PROMOTE_PID=$!
    emit_step "auto-promote sidecar PID=$AUTO_PROMOTE_PID"
}

# --- 5) Tick stream (main preprint loop) ---
# For each tick:
#   1. Read the next VERIFIED_NEW row from the upstream audit ledger
#      whose confidence >= floor.
#   2. Resolve cross-federation memo keys:
#      - claim-auditor's auditor memo (audit reasoning / evidence)
#      - claim-auditor's per-searcher memos (4 search reports)
#      - math-foundry's formulator memo (problem / answer / novelty)
#      - math-foundry's explorer memo (code / output / goal)
#   3. Seed `claim:*:tick-N` into the container's memo.
#   4. Sleep PREPRINT_TICK_INTERVAL_S so the colonies can react.
tick_stream() {
    emit_step "starting tick stream (interval=${TICK_INTERVAL_S}s total=${TOTAL_TICKS})"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 -c 'preprint-loop placeholder: audit=$SOURCE_AUDIT_LEDGER foundry=$SOURCE_FOUNDRY_DIR total_ticks=$TOTAL_TICKS interval=$TICK_INTERVAL_S floor=$CONFIDENCE_FLOOR' # tick loop runs in real mode"
        return
    fi
    python3 - "$SOURCE_AUDIT_LEDGER" "$SOURCE_FOUNDRY_DIR" "$TOTAL_TICKS" "$TICK_INTERVAL_S" "$RUN_DIR" "$CONFIDENCE_FLOOR" <<'PYPREPRINT'
import json
import os
import subprocess
import sys
import time

(
    source_ledger,
    source_foundry_dir,
    total_ticks,
    interval,
    run_dir,
    confidence_floor_raw,
) = (
    sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]),
    sys.argv[5], sys.argv[6],
)

try:
    confidence_floor = float(confidence_floor_raw)
except Exception:
    confidence_floor = 0.7

rows = []
try:
    with open(source_ledger) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except Exception:
                continue
except FileNotFoundError:
    sys.stderr.write("run-preprint: audit ledger not found: " + source_ledger + "\n")
    sys.exit(3)

candidates = [
    r for r in rows
    if r.get("audit_verdict") == "VERIFIED_NEW"
    and float(r.get("confidence", 0.0)) >= confidence_floor
]

if not candidates:
    sys.stderr.write(
        "run-preprint: no VERIFIED_NEW rows >= "
        + str(confidence_floor) + " in " + source_ledger + "\n"
    )
    sys.exit(3)

log_path = os.path.join(run_dir, "orchestrator.log")

# --- Cross-federation memo recall ---
# We probe two upstream run dirs:
#   (a) the claim-auditor run dir for auditor + per-searcher reports
#       (parent of source_ledger),
#   (b) the math-foundry run dir for formulator + explorer keys
#       (source_foundry_dir).
auditor_upstream_dir = os.path.dirname(source_ledger)
auditor_agentis = os.path.join(auditor_upstream_dir, ".agentis")
auditor_laptop_agentis = os.path.join(auditor_upstream_dir, "laptop-node", ".agentis")
have_auditor_memo = os.path.isdir(auditor_agentis) or os.path.isdir(auditor_laptop_agentis)
auditor_recall_cwd = auditor_upstream_dir if os.path.isdir(auditor_agentis) else (
    os.path.join(auditor_upstream_dir, "laptop-node") if os.path.isdir(auditor_laptop_agentis) else None
)

foundry_agentis = os.path.join(source_foundry_dir, ".agentis")
foundry_laptop_agentis = os.path.join(source_foundry_dir, "laptop-node", ".agentis")
have_foundry_memo = os.path.isdir(foundry_agentis) or os.path.isdir(foundry_laptop_agentis)
foundry_recall_cwd = source_foundry_dir if os.path.isdir(foundry_agentis) else (
    os.path.join(source_foundry_dir, "laptop-node") if os.path.isdir(foundry_laptop_agentis) else None
)

def upstream_recall(cwd, key):
    if not cwd:
        return ""
    try:
        out = subprocess.check_output(
            ["agentis", "memo", "get", key],
            cwd=cwd,
            stderr=subprocess.DEVNULL,
        )
        return out.decode("utf-8", "replace").strip()
    except Exception:
        return ""

audit_run_id = os.path.basename(auditor_upstream_dir) or "unknown"

for idx in range(total_ticks):
    if idx >= len(candidates):
        # Idle tick: no new candidate to seed, but we still bump
        # replay:current_tick so already-seeded claims keep
        # progressing through the phased pipeline (introducer/theorist/
        # computer read tick-1, editor reads tick-2, submitter reads
        # tick-3 — each needs the orchestrator to keep advancing the
        # current_tick value even when no new claim is queued).
        subprocess.run(
            ["podman", "exec", "preprint-foundry-laptop",
             "agentis", "memo", "set", "replay:current_tick", str(idx)],
            check=False,
        )
        with open(log_path, "a") as log:
            log.write(
                "# tick " + str(idx) + "/" + str(total_ticks)
                + " -- no more candidate rows; idle\n"
            )
        time.sleep(interval)
        continue
    row = candidates[idx]
    audit_source_run = str(row.get("source_run", ""))
    audit_source_tick = int(row.get("source_tick", 0))
    audit_source_pid = str(row.get("source_pid", ""))
    audit_reasoning = str(row.get("reasoning", ""))
    evidence = row.get("evidence", {}) or {}
    audit_problem_summary = str(row.get("problem_summary", ""))

    # Stable claim id: derive from source-run + source-pid + source-tick.
    claim_id = "claim-" + str(audit_source_pid or "x") + "-t" + str(audit_source_tick)

    # math-foundry: formulator + explorer keys.
    # audit_source_pid in the audit-ledger row is the novelty daemon
    # pid (the agent that emitted the verdict event), NOT the
    # formulator's. Formulator writes its memos under its own pid;
    # recover it from upstream's self-registered replay key
    # (same lesson as claim-auditor PR #604).
    foundry_formulator_pid = upstream_recall(
        foundry_recall_cwd, "replay:current_formulator_pid"
    )
    fpid = foundry_formulator_pid or audit_source_pid
    problem_text = upstream_recall(
        foundry_recall_cwd,
        "formulator:" + fpid + ":problem_text:tick-" + str(audit_source_tick),
    ) if fpid else ""
    answer = upstream_recall(
        foundry_recall_cwd,
        "formulator:" + fpid + ":answer:tick-" + str(audit_source_tick),
    ) if fpid else ""
    novelty_claim = upstream_recall(
        foundry_recall_cwd,
        "formulator:" + fpid + ":novelty_claim:tick-" + str(audit_source_tick),
    ) if fpid else ""
    # math-foundry explorer pid is not necessarily the same as formulator
    # pid; the formulator memo `formulator:<pid>:explorer_pid:tick-N` would
    # ideally carry it but is not guaranteed. As a robust fallback we
    # probe `replay:current_explorer_pid` which the explorer self-registers.
    explorer_pid = upstream_recall(foundry_recall_cwd, "replay:current_explorer_pid")
    explorer_code = ""
    explorer_output = ""
    explorer_goal = ""
    if explorer_pid:
        explorer_code = upstream_recall(
            foundry_recall_cwd,
            "explorer:" + explorer_pid + ":code:tick-" + str(audit_source_tick),
        )
        explorer_output = upstream_recall(
            foundry_recall_cwd,
            "explorer:" + explorer_pid + ":output:tick-" + str(audit_source_tick),
        )
        explorer_goal = upstream_recall(
            foundry_recall_cwd,
            "explorer:" + explorer_pid + ":goal:tick-" + str(audit_source_tick),
        )

    # claim-auditor: per-searcher reports. Auditor wrote at
    # `<colony>:<pid>:report:tick-N`; we need the auditor's view of which
    # pids it consulted. As a robust path we recall the auditor's
    # `replay:current_<colony>_pid` registry keys.
    auditor_tick = audit_source_tick  # auditor's upstream_tick mirrors the audit row's source_tick path; the row itself does not carry auditor's local tick. Fall back to source_tick.
    # Best-effort: try to read auditor's verdict json's tick by scanning
    # for `replay:current_auditor_pid`.
    arxiv_pid = upstream_recall(auditor_recall_cwd, "replay:current_arxiv_search_pid")
    oeis_pid = upstream_recall(auditor_recall_cwd, "replay:current_oeis_search_pid")
    groupprops_pid = upstream_recall(auditor_recall_cwd, "replay:current_groupprops_search_pid")
    scholar_pid = upstream_recall(auditor_recall_cwd, "replay:current_scholar_search_pid")
    report_arxiv = ""
    report_oeis = ""
    report_groupprops = ""
    report_scholar = ""
    # Probe the same tick index the auditor used; if that is empty,
    # scan a small window of recent ticks (auditor's run dir may not
    # carry the source-tick alignment). The .ag agents tolerate empty
    # report strings.
    for candidate_tick in [auditor_tick] + list(range(max(0, auditor_tick - 4), auditor_tick + 4)):
        if not report_arxiv and arxiv_pid:
            report_arxiv = upstream_recall(
                auditor_recall_cwd,
                "arxiv_search:" + arxiv_pid + ":report:tick-" + str(candidate_tick),
            )
        if not report_oeis and oeis_pid:
            report_oeis = upstream_recall(
                auditor_recall_cwd,
                "oeis_search:" + oeis_pid + ":report:tick-" + str(candidate_tick),
            )
        if not report_groupprops and groupprops_pid:
            report_groupprops = upstream_recall(
                auditor_recall_cwd,
                "groupprops_search:" + groupprops_pid + ":report:tick-" + str(candidate_tick),
            )
        if not report_scholar and scholar_pid:
            report_scholar = upstream_recall(
                auditor_recall_cwd,
                "scholar_search:" + scholar_pid + ":report:tick-" + str(candidate_tick),
            )
        if report_arxiv and report_oeis and report_groupprops and report_scholar:
            break

    # Fallbacks: if upstream memo is unreachable we still want the .ag
    # agents to have *something* to work with. Hand them the audit row
    # JSON as the problem context.
    if not problem_text:
        problem_text = json.dumps(row)

    memo_pairs = [
        ("replay:current_tick", str(idx)),
        ("claim:claim_id:tick-" + str(idx), claim_id),
        ("claim:problem_text:tick-" + str(idx), problem_text),
        ("claim:answer:tick-" + str(idx), answer or ""),
        ("claim:novelty_claim:tick-" + str(idx), novelty_claim or audit_problem_summary),
        ("claim:audit_reasoning:tick-" + str(idx), audit_reasoning),
        ("claim:audit_evidence_arxiv:tick-" + str(idx), str(evidence.get("arxiv", ""))),
        ("claim:audit_evidence_oeis:tick-" + str(idx), str(evidence.get("oeis", ""))),
        ("claim:audit_evidence_groupprops:tick-" + str(idx), str(evidence.get("groupprops", ""))),
        ("claim:audit_evidence_scholar:tick-" + str(idx), str(evidence.get("scholar", ""))),
        ("claim:report_arxiv:tick-" + str(idx), report_arxiv),
        ("claim:report_oeis:tick-" + str(idx), report_oeis),
        ("claim:report_groupprops:tick-" + str(idx), report_groupprops),
        ("claim:report_scholar:tick-" + str(idx), report_scholar),
        ("claim:explorer_code:tick-" + str(idx), explorer_code),
        ("claim:explorer_output:tick-" + str(idx), explorer_output),
        ("claim:explorer_goal:tick-" + str(idx), explorer_goal),
        ("claim:source_audit_run:tick-" + str(idx), audit_run_id),
        ("claim:source_foundry_run:tick-" + str(idx), audit_source_run),
        ("claim:source_tick:tick-" + str(idx), str(audit_source_tick)),
        ("claim:source_pid:tick-" + str(idx), audit_source_pid),
    ]
    for key, value in memo_pairs:
        subprocess.run(
            ["podman", "exec", "preprint-foundry-laptop", "agentis", "memo", "set", key, value],
            check=False,
        )
    with open(log_path, "a") as log:
        log.write(
            "# tick " + str(idx) + "/" + str(total_ticks)
            + " claim_id=" + claim_id
            + " confidence=" + str(row.get("confidence"))
            + "\n"
        )
    time.sleep(interval)
PYPREPRINT
}

# --- 6) Shutdown signal ---
signal_shutdown() {
    emit_step "signalling shutdown (touch /run-root/.shutdown)"
    emit_cmd "podman exec preprint-foundry-laptop touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json; json.dump({\"started_at\":\"$started_at\",\"source_audit_ledger\":\"$SOURCE_AUDIT_LEDGER\",\"source_foundry_dir\":\"$SOURCE_FOUNDRY_DIR\",\"total_ticks\":$TOTAL_TICKS,\"tick_interval_s\":$TICK_INTERVAL_S,\"llm_backend\":\"$LLM_BACKEND\",\"claude_model\":\"$CLAUDE_MODEL\",\"confidence_floor\":$CONFIDENCE_FLOOR,\"latexmk_max_passes\":$LATEXMK_MAX_PASSES,\"image_tag\":\"$IMAGE_TAG\",\"arxiv_gateway\":\"$ARXIV_GATEWAY\",\"hitl_required\":True}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- Orchestration body ---
install_cleanup_trap
build_image
write_bootstrap
write_run_meta
spawn_container
start_auto_promote_sidecar
tick_stream

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no container spawned"
    exit 0
fi

signal_shutdown

emit_step "run-preprint: done"
echo "[run-preprint] run dir: $RUN_DIR"
