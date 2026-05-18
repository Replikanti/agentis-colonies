#!/bin/bash
# run-auditor.sh -- literature-verification orchestrator for the
# claim-auditor federation (#595).
#
# Tails a math-foundry discovery-ledger.jsonl file, picks rows where
# verdict in {NOVEL, BORDERLINE}, looks up the corresponding
# formulator memo keys (problem_text / answer / novelty_claim) from
# the upstream run, seeds them into the auditor container's memo as
# `claim:problem_text:tick-N` etc., and lets the five colonies (four
# searchers + auditor) tick through their phased pipeline.
#
# Architectural shape mirrors math-foundry/tools/run-foundry.sh
# (emit_step helper, run dir under claim-auditor/runs/<ts>/,
# `podman run --replace` idiom). The producer-consumer contract with
# math-foundry is documented in claim-auditor/README.md.
#
# Env vars (all optional except AUDITOR_SOURCE_RUN; defaults shown):
#   AUDITOR_SOURCE_RUN           Path to math-foundry run dir whose
#                                discovery-ledger.jsonl this audit
#                                consumes. Required when not dry-run.
#   AUDITOR_LLM_BACKEND          llm.backend value injected into hermetic
#                                config. Default: claude
#   AUDITOR_CLAUDE_MODEL         Default model for searchers. Default: sonnet
#   AUDITOR_CLAUDE_MODEL_AUDITOR Override model for the auditor colony.
#                                Default: opus
#   AUDITOR_CLAUDE_EFFORT        Default effort. Default: medium
#   AUDITOR_HOST_CLAUDE_DIR      Host path bind-mounted to /root/.claude.
#                                Default: $HOME/.claude
#   AUDITOR_TICK_INTERVAL_S      Seconds between auditor ticks.
#                                Default 120 (HTTPS fetch + LLM judgement).
#   AUDITOR_TOTAL_TICKS          Number of ticks to drive. Default 30.
#   AUDITOR_CONFIDENCE_FLOOR     Reject auditor verdicts below this floor
#                                (post-processed by the README's
#                                quality gate; the auditor.ag itself
#                                still writes the row). Default 0.7
#   AUDITOR_DAEMON_CB_PER_TICK   Per-tick CB replenishment written into
#                                hermetic .agentis/config as
#                                `daemon.cb_per_tick`. Default 2000
#                                (mirrors math-foundry which mirrors
#                                trading-binance #579).
#   AUDITOR_DAEMON_HEARTBEAT_MS  Watchdog heartbeat (ms). Default 1800000
#                                (mirrors trading-binance #583).
#   AUDITOR_RUN_DIR              Output dir override. Default:
#                                auto-timestamped under claim-auditor/runs/
#   AUDITOR_IMAGE_TAG            Container image tag built from
#                                Containerfile.auditor.
#                                Default: claim-auditor:latest
#   AUDITOR_DRY_RUN              1 = emit_step the plan, skip podman.
#                                Default: "" (real run).
#
# Flags:
#   --dry-run                 Same as AUDITOR_DRY_RUN=1.
#   --source-run <path>       Same as AUDITOR_SOURCE_RUN=<path>.
#
# Output layout (under claim-auditor/runs/<YYYYMMDDTHHMMSSZ>/):
#   orchestrator.log               orchestrator's own log
#   run-meta.json                  config dump (source run, ticks, knobs)
#   audit-ledger.jsonl             per-claim audit verdict rows
#   laptop-node/
#     bootstrap.sh                 container bootstrap (real run only)
#     .agentis/
#       sandbox/                   per-daemon scratch
#       logs/
#       spend/
#
# Exit codes:
#   0   audit run completed (or dry-run plan emitted)
#   1   prerequisite missing (podman, python3 outside dry-run)
#   2   invalid env (e.g. empty source run path)
#   3   source run unreadable / no NOVEL+BORDERLINE rows
#   4   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${AUDITOR_DRY_RUN:-0}"
SOURCE_RUN_FLAG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --source-run)
            if [ -z "${2:-}" ]; then
                echo "run-auditor: --source-run requires a path" >&2
                exit 2
            fi
            SOURCE_RUN_FLAG="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR==1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "$SCRIPT_PATH"
            exit 0
            ;;
        *)
            echo "run-auditor: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

# --- Env-var defaults ---
SOURCE_RUN="${SOURCE_RUN_FLAG:-${AUDITOR_SOURCE_RUN:-}}"
LLM_BACKEND="${AUDITOR_LLM_BACKEND:-claude}"
CLAUDE_MODEL="${AUDITOR_CLAUDE_MODEL:-sonnet}"
CLAUDE_MODEL_AUDITOR="${AUDITOR_CLAUDE_MODEL_AUDITOR:-opus}"
CLAUDE_EFFORT="${AUDITOR_CLAUDE_EFFORT:-medium}"
HOST_CLAUDE_DIR="${AUDITOR_HOST_CLAUDE_DIR:-$HOME/.claude}"
TICK_INTERVAL_S="${AUDITOR_TICK_INTERVAL_S:-120}"
TOTAL_TICKS="${AUDITOR_TOTAL_TICKS:-30}"
CONFIDENCE_FLOOR="${AUDITOR_CONFIDENCE_FLOOR:-0.7}"
DAEMON_CB_PER_TICK="${AUDITOR_DAEMON_CB_PER_TICK:-2000}"
DAEMON_HEARTBEAT_MS="${AUDITOR_DAEMON_HEARTBEAT_MS:-1800000}"
IMAGE_TAG="${AUDITOR_IMAGE_TAG:-claim-auditor:latest}"

# --- Validation ---
val=""
for var_name in TICK_INTERVAL_S TOTAL_TICKS; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-auditor: $var_name must be a positive integer (got: $val)" >&2
            exit 2
            ;;
    esac
done
unset val

if [ "$TICK_INTERVAL_S" -lt 1 ]; then
    echo "run-auditor: AUDITOR_TICK_INTERVAL_S must be >= 1 (got: $TICK_INTERVAL_S)" >&2
    exit 2
fi
if [ "$TOTAL_TICKS" -lt 1 ]; then
    echo "run-auditor: AUDITOR_TOTAL_TICKS must be >= 1 (got: $TOTAL_TICKS)" >&2
    exit 2
fi

# Source-run validation is skipped in dry-run mode so smoke tests can
# point at a synthetic fixture path that may not exist on the CI host.
if [ "$DRY_RUN" = "0" ]; then
    if [ -z "$SOURCE_RUN" ]; then
        echo "run-auditor: AUDITOR_SOURCE_RUN (or --source-run) is required" >&2
        exit 2
    fi
    if [ ! -d "$SOURCE_RUN" ] && [ ! -f "$SOURCE_RUN" ]; then
        echo "run-auditor: AUDITOR_SOURCE_RUN does not exist: $SOURCE_RUN" >&2
        exit 3
    fi
fi

# Resolve SOURCE_RUN to an absolute discovery-ledger.jsonl path.
SOURCE_LEDGER=""
if [ -n "$SOURCE_RUN" ]; then
    if [ -f "$SOURCE_RUN" ]; then
        SOURCE_LEDGER="$(cd "$(dirname "$SOURCE_RUN")" && pwd)/$(basename "$SOURCE_RUN")"
    elif [ -d "$SOURCE_RUN" ]; then
        SOURCE_LEDGER="$(cd "$SOURCE_RUN" && pwd)/discovery-ledger.jsonl"
    else
        SOURCE_LEDGER="$SOURCE_RUN"
    fi
fi

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="${AUDITOR_RUN_DIR:-$FED_DIR/runs/$TS}"
ORCH_LOG="$RUN_DIR/orchestrator.log"
RUN_META="$RUN_DIR/run-meta.json"
LAPTOP_DIR="$RUN_DIR/laptop-node"
AUDIT_LEDGER="$RUN_DIR/audit-ledger.jsonl"

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
            echo "run-auditor: $bin not found on PATH" >&2
            exit 1
        fi
    done
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$LAPTOP_DIR/.agentis/sandbox" "$LAPTOP_DIR/.agentis/logs" "$LAPTOP_DIR/.agentis/spend"
    : >"$ORCH_LOG"
    : >"$AUDIT_LEDGER"
fi

emit_step "run-auditor: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "source ledger: $SOURCE_LEDGER"
emit_step "tick interval: ${TICK_INTERVAL_S}s"
emit_step "total ticks: $TOTAL_TICKS"
emit_step "llm backend: $LLM_BACKEND"
emit_step "searcher model: $CLAUDE_MODEL"
emit_step "auditor model: $CLAUDE_MODEL_AUDITOR"
emit_step "confidence floor: $CONFIDENCE_FLOOR"
emit_step "image tag: $IMAGE_TAG"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.auditor $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
write_bootstrap() {
    bootstrap_path="$LAPTOP_DIR/bootstrap.sh"
    emit_step "generating bootstrap script at $bootstrap_path (colonies=5)"

    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "write-bootstrap path=$bootstrap_path colonies=arxiv-search,oeis-search,groupprops-search,scholar-search,auditor"
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-auditor.sh -- runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        printf '{\n'
        printf '  printf "exec.env_passthrough = DAEMON_ID,COLONY_NAME,DISCOVERY_LEDGER,ARXIV_MAX_QUERY_RESULTS,AGENTIS_ROOT\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        printf '  printf "daemon.cb_per_tick = %s\\n"\n' "$DAEMON_CB_PER_TICK"
        printf '  printf "daemon.heartbeat_interval_ms = %s\\n"\n' "$DAEMON_HEARTBEAT_MS"
        # PII allow: arxiv / OEIS responses contain long numeric strings
        # (issue ids, A-numbers, sequence runs) that the agentis-core PII
        # heuristic flags. Mirrors math-foundry / trading-binance #581.
        printf '  printf "pii_transmit = allow\\n"\n'
        # Bump memo cap; 5 colonies * 30 ticks * a handful of per-pid
        # keys per tick fills the default 500 quickly. Mirrors #587.
        printf '  printf "memo.max_keys = 50000\\n"\n'
        if [ "$LLM_BACKEND" = "claude" ]; then
            printf '  printf "llm.command = claude\\n"\n'
            # Phase 1: single backend block applies to all 5 colonies.
            # Per-colony model split (Sonnet for searchers vs Opus for
            # auditor) is a Phase 2 enhancement requiring per-colony
            # AGENTIS_ROOT; documented in README env-var matrix.
            printf '  printf "llm.args = -p --output-format json --model %s --tools \\"\\" --system-prompt \\"You are a research mathematician. Output only valid JSON.\\" --effort %s\\n"\n' "$CLAUDE_MODEL" "$CLAUDE_EFFORT"
        fi
        printf '} >> .agentis/config\n'
        printf 'for c in arxiv-search oeis-search groupprops-search scholar-search auditor; do\n'
        printf '    cp -r /repo/claim-auditor/$c /run-root/$c\n'
        printf 'done\n'
        printf 'cp -r /repo/claim-auditor/tools /run-root/tools\n'
        printf 'mkdir -p /run-root/.agentis/sandbox /run-root/.agentis/logs\n'
        printf ': > /run-root/audit-ledger.jsonl\n'
        # Seed propose-tier confidence for each colony.
        printf 'for c in arxiv_search oeis_search groupprops_search scholar_search auditor; do\n'
        printf '    (cd /run-root && agentis memo set $c:confidence 0.7 >/dev/null 2>&1 || true)\n'
        printf 'done\n'
        # Spawn one daemon per colony.
        printf 'AUDITOR_TICK_INTERVAL_MS=%s\n' "$((TICK_INTERVAL_S * 1000))"
        printf 'for c in arxiv-search oeis-search groupprops-search scholar-search; do\n'
        printf '    DAEMON_ID=1 COLONY_NAME=$c DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl ARXIV_MAX_QUERY_RESULTS=10 AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/$c/agents/$c.ag --colony $c --enable-exec --enable-messaging --tick-interval "$AUDITOR_TICK_INTERVAL_MS" > /run-root/.agentis/logs/$c-1.log 2>&1 &\n'
        printf 'done\n'
        printf 'DAEMON_ID=1 COLONY_NAME=auditor DISCOVERY_LEDGER=/run-root/audit-ledger.jsonl AGENTIS_ROOT=/run-root/.agentis agentis daemon /run-root/auditor/agents/auditor.ag --colony auditor --enable-exec --enable-messaging --tick-interval "$AUDITOR_TICK_INTERVAL_MS" > /run-root/.agentis/logs/auditor-1.log 2>&1 &\n'
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

# --- 3) Spawn the container ---
spawn_container() {
    emit_step "spawning claim-auditor container (image=$IMAGE_TAG)"
    if [ "$LLM_BACKEND" = "claude" ]; then
        emit_cmd "podman run -d --replace --name claim-auditor-laptop -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw -v $HOST_CLAUDE_DIR:/root/.claude:rw,z $IMAGE_TAG /run-root/bootstrap.sh"
    else
        emit_cmd "podman run -d --replace --name claim-auditor-laptop -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
    fi
}

# --- 4) Cleanup trap ---
AUTO_PROMOTE_PID=""
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm container; kill sidecars)"
    # shellcheck disable=SC2064  # Expand $AUTO_PROMOTE_PID at trigger time.
    emit_cmd "trap '[ -n \"\${AUTO_PROMOTE_PID:-}\" ] && kill \"\$AUTO_PROMOTE_PID\" 2>/dev/null; podman stop --time 5 claim-auditor-laptop 2>/dev/null || true; podman rm -f claim-auditor-laptop 2>/dev/null || true' EXIT INT TERM"
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
#   AUDITOR_AUTO_PROMOTE             1 enable (default), 0 disable
#   AUDITOR_AUTO_PROMOTE_INTERVAL_S  seconds between sidecar ticks
#                                    (default 300)
start_auto_promote_sidecar() {
    AP_ENABLED="${AUDITOR_AUTO_PROMOTE:-1}"
    AP_INTERVAL="${AUDITOR_AUTO_PROMOTE_INTERVAL_S:-300}"
    if [ "$AP_ENABLED" != "1" ]; then
        emit_step "auto-promote sidecar: disabled via AUDITOR_AUTO_PROMOTE=$AP_ENABLED"
        return 0
    fi
    AP_SCRIPT="$REPO_ROOT/tools/auto-promote.sh"
    AP_CONFIG="$REPO_ROOT/tools/auto-promote-config.claim-auditor.yaml"
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

# --- 5) Tick stream (main audit loop) ---
# For each tick:
#   1. Read the next NOVEL/BORDERLINE row from the upstream ledger.
#   2. Look up the matching formulator memo keys from the upstream
#      math-foundry run dir's `.agentis/` (best-effort -- if the run
#      is a frozen tarball without an agentis state dir, the .ag
#      agents fall back to the row content alone).
#   3. Seed `claim:problem_text:tick-N` etc. into the container's memo
#      and bump `replay:current_tick`.
#   4. Sleep AUDITOR_TICK_INTERVAL_S so the daemons can react.
tick_stream() {
    emit_step "starting tick stream (interval=${TICK_INTERVAL_S}s total=${TOTAL_TICKS})"
    if [ "$DRY_RUN" = "1" ]; then
        emit_cmd "python3 -c 'audit-loop placeholder: source=$SOURCE_LEDGER total_ticks=$TOTAL_TICKS interval=$TICK_INTERVAL_S' # tick loop runs in real mode"
        return
    fi
    python3 - "$SOURCE_LEDGER" "$TOTAL_TICKS" "$TICK_INTERVAL_S" "$RUN_DIR" <<'PYAUDIT'
import json
import os
import subprocess
import sys
import time

source_ledger, total_ticks, interval, run_dir = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4],
)

# Load all rows from the source ledger (it is append-only; reading the
# current snapshot once at the top of the loop matches the issue's
# "batch consume" mode -- the "tail incrementally" mode is the open
# question in #595 design notes).
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
    sys.stderr.write("run-auditor: source ledger not found: " + source_ledger + "\n")
    sys.exit(3)

# Filter to NOVEL + BORDERLINE rows on novelty_verdict events. The
# upstream math-foundry novelty.ag emits exactly this shape (see
# math-foundry/novelty/agents/novelty.ag's ledger row).
candidates = [
    r for r in rows
    if r.get("event") == "novelty_verdict"
    and r.get("verdict") in ("NOVEL", "BORDERLINE")
]

if not candidates:
    sys.stderr.write(
        "run-auditor: no NOVEL/BORDERLINE rows in " + source_ledger + "\n"
    )
    sys.exit(3)

log_path = os.path.join(run_dir, "orchestrator.log")

# The upstream run dir is the parent of the source ledger. We probe
# .agentis/ under it (best-effort) to recover the formulator memo
# values that math-foundry wrote during the original run. If the
# memo store is gone (frozen tarball, different host), fall back to
# whatever the row itself carries.
upstream_dir = os.path.dirname(source_ledger)
upstream_agentis = os.path.join(upstream_dir, ".agentis")
upstream_laptop_agentis = os.path.join(upstream_dir, "laptop-node", ".agentis")
# math-foundry writes its memo under <run-dir>/laptop-node/.agentis/, but
# `os.path.dirname(source_ledger)` lands on <run-dir>. Probe both shapes
# and pick whichever exists. Fall back to None when neither does so
# subsequent recalls cleanly return empty.
if os.path.isdir(upstream_agentis):
    upstream_recall_cwd = upstream_dir
elif os.path.isdir(upstream_laptop_agentis):
    upstream_recall_cwd = os.path.join(upstream_dir, "laptop-node")
else:
    upstream_recall_cwd = None
have_upstream_memo = upstream_recall_cwd is not None

def upstream_recall(key):
    if not have_upstream_memo:
        return ""
    try:
        out = subprocess.check_output(
            ["agentis", "memo", "get", key],
            cwd=upstream_recall_cwd,
            stderr=subprocess.DEVNULL,
        )
        return out.decode("utf-8", "replace").strip()
    except Exception:
        return ""

source_run_id = os.path.basename(upstream_dir) or "unknown"

# The ledger row's `pid` is the novelty daemon's pid (it emitted the
# verdict event), not the formulator's. Formulator/explorer write memo
# keys under their own daemon pids, so we look those up once from the
# upstream's self-registered replay keys.
upstream_formulator_pid = upstream_recall("replay:current_formulator_pid")
upstream_explorer_pid = upstream_recall("replay:current_explorer_pid")

for idx in range(total_ticks):
    if idx >= len(candidates):
        with open(log_path, "a") as log:
            log.write(
                "# tick " + str(idx) + "/" + str(total_ticks)
                + " -- no more candidate rows; idle\n"
            )
        time.sleep(interval)
        continue
    row = candidates[idx]
    source_tick = row.get("tick", 0)
    # source_pid here is the novelty daemon pid recorded in the ledger
    # row; we still pass it through to the searchers as
    # `claim:source_pid` for audit-trail purposes.
    source_pid = str(row.get("pid", ""))

    problem_text = upstream_recall(
        "formulator:" + upstream_formulator_pid + ":problem_text:tick-" + str(source_tick)
    ) if upstream_formulator_pid else ""
    answer = upstream_recall(
        "formulator:" + upstream_formulator_pid + ":answer:tick-" + str(source_tick)
    ) if upstream_formulator_pid else ""
    novelty_claim = upstream_recall(
        "formulator:" + upstream_formulator_pid + ":novelty_claim:tick-" + str(source_tick)
    ) if upstream_formulator_pid else ""
    # Fallback: if the upstream memo is unreachable, hand the .ag
    # agents the row JSON so they at least know which verdict
    # triggered the audit. The .ag's early-exit on empty
    # problem_text still applies.
    if not problem_text:
        problem_text = json.dumps(row)

    memo_pairs = [
        ("replay:current_tick", str(idx)),
        ("claim:problem_text:tick-" + str(idx), problem_text),
        ("claim:answer:tick-" + str(idx), answer or ""),
        ("claim:novelty_claim:tick-" + str(idx), novelty_claim or row.get("verdict", "")),
        ("claim:source_run:tick-" + str(idx), source_run_id),
        ("claim:source_tick:tick-" + str(idx), str(source_tick)),
        ("claim:source_pid:tick-" + str(idx), source_pid),
    ]
    for key, value in memo_pairs:
        subprocess.run(
            ["podman", "exec", "claim-auditor-laptop", "agentis", "memo", "set", key, value],
            check=False,
        )
    with open(log_path, "a") as log:
        log.write(
            "# tick " + str(idx) + "/" + str(total_ticks)
            + " source_pid=" + source_pid
            + " source_tick=" + str(source_tick)
            + " verdict=" + str(row.get("verdict"))
            + "\n"
        )
    time.sleep(interval)
PYAUDIT
}

# --- 6) Shutdown signal ---
signal_shutdown() {
    emit_step "signalling shutdown (touch /run-root/.shutdown)"
    emit_cmd "podman exec claim-auditor-laptop touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json; json.dump({\"started_at\":\"$started_at\",\"source_ledger\":\"$SOURCE_LEDGER\",\"total_ticks\":$TOTAL_TICKS,\"tick_interval_s\":$TICK_INTERVAL_S,\"llm_backend\":\"$LLM_BACKEND\",\"searcher_model\":\"$CLAUDE_MODEL\",\"auditor_model\":\"$CLAUDE_MODEL_AUDITOR\",\"confidence_floor\":$CONFIDENCE_FLOOR,\"image_tag\":\"$IMAGE_TAG\"}, open(\"$RUN_META\",\"w\"), indent=2)'"
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

emit_step "run-auditor: done"
echo "[run-auditor] run dir: $RUN_DIR"
