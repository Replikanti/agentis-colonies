#!/bin/bash
# run-stage3-multinode.sh — Stage 3 multinode orchestrator (#439).
#
# Drives a 2-node Stage 3 pilot:
#
#   * Laptop  (local):   tribe-alpha + tribe-beta
#   * Server  (remote):  tribe-gamma + tribe-delta + tribe-epsilon
#
# Tribe split rationale: 2-on-laptop / 3-on-server reflects the operator's
# typical resource asymmetry (server has ~2x cores + 24/7 power, laptop is
# a worktree-development machine that may sleep). Concentrating the
# heavier slice on the server keeps a tribe-down event on the laptop side
# from killing federation-wide replicate() flow.
#
# Transport: the orchestrator opens an SSH master channel + a local
# port-forward (9101 → remote 9100) so the laptop's `agentis` colony
# worker can reach the remote `agentis serve` instance under
# loopback-only addresses (no public firewall changes required on the
# server). Both sides set `federation.enabled = true` in their hermetic
# `.agentis/config`.
#
# Target rotation: every STAGE3_ROTATION_INTERVAL_S the orchestrator
# rotates TARGET_DIR + BUGS_MANIFEST between Stage 2's smallvec target
# and the freshly-vendored bumpalo target (#446) so the pilot exercises
# both planted-bug surfaces inside the same 6h window.
#
# Death threshold: bumped to 300 CB (vs Stage 2's 100) so a hunter that
# spends one expensive Claude round + one verifier round doesn't get
# culled before the cognitive market clears.
#
# Env vars:
#   STAGE3_WALL_CLOCK_S        Wall-clock cap in seconds. Default: 21600
#                              (6h full pilot). 30-min smoke runs at 1800.
#   STAGE3_ROTATION_INTERVAL_S Seconds between TARGET_DIR rotations.
#                              Default: 1200 (20 min).
#   STAGE3_DEATH_THRESHOLD     CB level at which a hunter is culled.
#                              Default: 300 (Stage 2 was 100).
#   STAGE3_LLM_BACKEND         llm.backend value injected into both
#                              hermetic configs. Default: openai (#445).
#   STAGE3_OPENAI_MODEL        Model id when STAGE3_LLM_BACKEND=openai.
#                              Default: gpt-4o-mini.
#   STAGE3_OPENAI_ENDPOINT     Chat-completions URL.
#                              Default: https://api.openai.com/v1/chat/completions.
#   STAGE3_OPENAI_KEY_ENV      Name of the env var that carries the
#                              OpenAI API key. Default: OPENAI_API_KEY.
#                              Both nodes must have this var exported at
#                              daemon-spawn time.
#   STAGE3_OPENAI_TIMEOUT_MS   Per-request timeout (ms). Default: 180000.
#   STAGE3_REMOTE_HOST         SSH login string (user@host or alias) for
#                              the remote node. Default: ylohnitram@94.112.2.177.
#   STAGE3_REMOTE_AGENTIS      Remote agentis binary path (login-shell PATH).
#                              Default: agentis (resolved via `bash -lc`).
#   STAGE3_TUNNEL_LOCAL_PORT   Local end of the port-forward.
#                              Default: 9101.
#   STAGE3_TUNNEL_REMOTE_PORT  Remote end of the port-forward (loopback
#                              on server). Default: 9100.
#   STAGE3_TUNNEL_SOCK         SSH master control-socket path.
#                              Default: /tmp/stage3-tunnel.sock.
#   STAGE3_REMOTE_RUN_ROOT     Remote run-dir parent on the server.
#                              Default: ~/tribes-bench-stage3-runs.
#
# Flags:
#   --dry-run    Echo every command the orchestrator would run (with
#                a leading "+ " prefix), do not open the SSH tunnel,
#                do not spawn any daemons, exit 0.
#
# Output layout (under tribes-bench/runs/stage3-<ts>/):
#   run-meta.json             start ts, end ts, wall clock, rotation
#                             interval, death threshold, llm backend,
#                             list of nodes
#   multinode.log             orchestrator's own log
#   tunnel.log                SSH tunnel state log
#   .agentis/                 hermetic agentis root (laptop-side)
#   server-runs/<server-ts>/  rsync of the server's hermetic .agentis/
#                             pulled back at end-of-pilot
#   telemetry.csv             combined per-node telemetry (analyse-stage2
#                             schema + a "node" column)
#   bug-ledger.jsonl          combined ledger from both nodes
#   rotations.csv             one row per rotation event
#                             (ts,target_dir,bugs_manifest)
#
# Exit codes:
#   0   pilot completed
#   1   prerequisite missing (agentis CLI, ssh, jq, python3) or invalid
#       env var
#   2   SSH tunnel could not be established
#   3   remote `agentis serve` failed to start
#   4   local `agentis serve` failed to start
#   5   federation launch failed (laptop or server side)

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            sed -n '2,90p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run-stage3-multinode: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# --- Env-var defaults + validation ---
WALL_CLOCK="${STAGE3_WALL_CLOCK_S:-21600}"
ROTATION_INTERVAL="${STAGE3_ROTATION_INTERVAL_S:-1200}"
DEATH_THRESHOLD="${STAGE3_DEATH_THRESHOLD:-300}"
LLM_BACKEND="${STAGE3_LLM_BACKEND:-openai}"
OPENAI_MODEL="${STAGE3_OPENAI_MODEL:-gpt-4o-mini}"
OPENAI_ENDPOINT="${STAGE3_OPENAI_ENDPOINT:-https://api.openai.com/v1/chat/completions}"
OPENAI_KEY_ENV="${STAGE3_OPENAI_KEY_ENV:-OPENAI_API_KEY}"
OPENAI_TIMEOUT_MS="${STAGE3_OPENAI_TIMEOUT_MS:-180000}"
REMOTE_HOST="${STAGE3_REMOTE_HOST:-ylohnitram@94.112.2.177}"
REMOTE_AGENTIS="${STAGE3_REMOTE_AGENTIS:-agentis}"
TUNNEL_LOCAL_PORT="${STAGE3_TUNNEL_LOCAL_PORT:-9101}"
TUNNEL_REMOTE_PORT="${STAGE3_TUNNEL_REMOTE_PORT:-9100}"
TUNNEL_SOCK="${STAGE3_TUNNEL_SOCK:-/tmp/stage3-tunnel.sock}"
REMOTE_RUN_ROOT="${STAGE3_REMOTE_RUN_ROOT:-~/tribes-bench-stage3-runs}"

val=""
for var_name in WALL_CLOCK ROTATION_INTERVAL DEATH_THRESHOLD \
                OPENAI_TIMEOUT_MS TUNNEL_LOCAL_PORT TUNNEL_REMOTE_PORT; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-stage3-multinode: $var_name must be a positive integer (got: $val)" >&2
            exit 1
            ;;
    esac
done
unset val

# --- Tribe split (editorial; documented in the script header) ---
LAPTOP_TRIBES=(tribe-alpha tribe-beta)
SERVER_TRIBES=(tribe-gamma tribe-delta tribe-epsilon)

# --- Stage 2 + Stage 3 target pair (rotated every ROTATION_INTERVAL) ---
# TARGET_*_FILE are documented for the operator (TARGET_FILE is the env
# var the hunter reads inside the .ag scenario) but the rotation timer
# only swaps TARGET_DIR + BUGS_MANIFEST: the hunter discovers TARGET_FILE
# via tribes-bench:target_file memo, which run-stage2.sh already seeds.
TARGET_A_DIR="$FED_DIR/targets/stage2/smallvec-v0.6.13"
TARGET_A_FILE="lib.rs"
TARGET_A_BUGS="$FED_DIR/targets/stage2/bugs.json"
TARGET_B_DIR="$FED_DIR/targets/stage3/bumpalo-v3.2.0"
TARGET_B_FILE="src/lib.rs"
TARGET_B_BUGS="$FED_DIR/targets/stage3/bugs.json"
# shellcheck disable=SC2034
_unused_target_files=("$TARGET_A_FILE" "$TARGET_B_FILE")

# --- Per-run hermetic dir (laptop side) ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/stage3-$TS"
TUNNEL_LOG="$RUN_DIR/tunnel.log"
ORCH_LOG="$RUN_DIR/multinode.log"
ROTATIONS_CSV="$RUN_DIR/rotations.csv"
RUN_META="$RUN_DIR/run-meta.json"

# --- Dry-run / real-run dispatch helpers ---
# emit_cmd echoes the command (with `+ ` prefix) when DRY_RUN=1; otherwise
# runs it. emit_step is for non-command narrative lines.
emit_cmd() {
    if [ "$DRY_RUN" = "1" ]; then
        printf '+ %s\n' "$*"
    else
        printf '+ %s\n' "$*" >>"$ORCH_LOG"
        # shellcheck disable=SC2294
        # We deliberately eval the composed string so embedded redirections
        # (>>logfile) and backgrounding (&) take effect; commands here are
        # constructed by us, not user input.
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

# In dry-run mode we also want the trap and rotation timer setup to
# surface in the emitted output, so we group them in helpers and run
# the helpers regardless of dry-run; they internally call emit_cmd.

# --- Prerequisite checks (skipped in dry-run for portability) ---
if [ "$DRY_RUN" = "0" ]; then
    for bin in agentis ssh jq python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-stage3-multinode: $bin not found on PATH" >&2
            exit 1
        fi
    done
    mkdir -p "$RUN_DIR" "$RUN_DIR/server-runs"
    : >"$ORCH_LOG"
    : >"$TUNNEL_LOG"
    : >"$ROTATIONS_CSV"
    printf 'ts,target_dir,bugs_manifest\n' >"$ROTATIONS_CSV"
fi

emit_step "run-stage3-multinode: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "wall clock: ${WALL_CLOCK}s, rotation: ${ROTATION_INTERVAL}s, death threshold: ${DEATH_THRESHOLD}"
emit_step "tribes: laptop=[${LAPTOP_TRIBES[*]}] server=[${SERVER_TRIBES[*]}]"

# --- 1) SSH tunnel ---
open_tunnel() {
    emit_step "opening SSH master + port-forward to $REMOTE_HOST"
    emit_cmd "ssh -fN -M -S $TUNNEL_SOCK -L $TUNNEL_LOCAL_PORT:127.0.0.1:$TUNNEL_REMOTE_PORT $REMOTE_HOST"
}

close_tunnel() {
    emit_step "closing SSH master channel $TUNNEL_SOCK"
    emit_cmd "ssh -S $TUNNEL_SOCK -O exit $REMOTE_HOST"
}

# --- 2) agentis serve (remote + local) ---
start_remote_serve() {
    emit_step "starting remote agentis serve on 127.0.0.1:$TUNNEL_REMOTE_PORT"
    # mkdir -p $REMOTE_RUN_ROOT must run before serve.log/serve.pid writes
    # — the dir is otherwise created later by configure_remote_node, but
    # the writes here would fail with "no such file or directory".
    emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'mkdir -p $REMOTE_RUN_ROOT && $REMOTE_AGENTIS serve 127.0.0.1:$TUNNEL_REMOTE_PORT >>$REMOTE_RUN_ROOT/serve.log 2>&1 & echo \$! >$REMOTE_RUN_ROOT/serve.pid'"
}

stop_remote_serve() {
    emit_step "stopping remote agentis serve"
    emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'kill \$(cat $REMOTE_RUN_ROOT/serve.pid 2>/dev/null) 2>/dev/null || true'"
}

start_local_serve() {
    emit_step "starting local agentis serve on 127.0.0.1:$TUNNEL_REMOTE_PORT"
    emit_cmd "agentis serve 127.0.0.1:$TUNNEL_REMOTE_PORT >>$RUN_DIR/serve-local.log 2>&1 & echo \$! >$RUN_DIR/serve-local.pid"
}

stop_local_serve() {
    emit_step "stopping local agentis serve"
    emit_cmd "kill \$(cat $RUN_DIR/serve-local.pid 2>/dev/null) 2>/dev/null || true"
}

# --- 3) hermetic .agentis/config injection (federation.enabled = true) ---
configure_local_node() {
    emit_step "configuring laptop hermetic .agentis/config (federation.enabled=true, llm.backend=$LLM_BACKEND)"
    emit_cmd "cd $RUN_DIR && agentis init >/dev/null 2>&1 || true"
    emit_cmd "python3 $TOOLS_DIR/run-stage2-rewrite-cb.py --noop-if-missing $RUN_DIR/.agentis/config || true"
    emit_cmd "printf 'federation.enabled = true\\n' >>$RUN_DIR/.agentis/config"
    emit_cmd "printf 'llm.backend = $LLM_BACKEND\\n' >>$RUN_DIR/.agentis/config"
    if [ "$LLM_BACKEND" = "openai" ]; then
        emit_cmd "printf 'llm.openai.endpoint = $OPENAI_ENDPOINT\\nllm.openai.model = $OPENAI_MODEL\\nllm.openai.api_key_env = $OPENAI_KEY_ENV\\nllm.openai.timeout_ms = $OPENAI_TIMEOUT_MS\\n' >>$RUN_DIR/.agentis/config"
    fi
}

configure_remote_node() {
    emit_step "configuring server hermetic .agentis/config (federation.enabled=true, llm.backend=$LLM_BACKEND)"
    emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'mkdir -p $REMOTE_RUN_ROOT && cd $REMOTE_RUN_ROOT && $REMOTE_AGENTIS init >/dev/null 2>&1 || true'"
    emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'printf \"federation.enabled = true\\nllm.backend = $LLM_BACKEND\\n\" >>$REMOTE_RUN_ROOT/.agentis/config'"
    if [ "$LLM_BACKEND" = "openai" ]; then
        emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'printf \"llm.openai.endpoint = $OPENAI_ENDPOINT\\nllm.openai.model = $OPENAI_MODEL\\nllm.openai.api_key_env = $OPENAI_KEY_ENV\\nllm.openai.timeout_ms = $OPENAI_TIMEOUT_MS\\n\" >>$REMOTE_RUN_ROOT/.agentis/config'"
    fi
}

# Push tribe scaffolding (agents/, scripts/, config/) plus tools/ and
# targets/ over the SSH tunnel so spawn_server_daemons() can resolve
# $REMOTE_RUN_ROOT/$tribe/scripts/start-colony.sh + the verifier + the
# bug manifests on the server side. Without this step the remote
# daemons would have no source files and target rotation could not
# resolve TARGET_DIR / BUGS_MANIFEST. rsync --delete keeps the remote
# tree byte-identical to the laptop's tribes-bench source.
push_server_scaffolding() {
    emit_step "pushing tribe scaffolding to server: ${SERVER_TRIBES[*]}"
    for tribe in "${SERVER_TRIBES[@]}"; do
        emit_cmd "rsync -az --delete -e 'ssh -S $TUNNEL_SOCK' $FED_DIR/$tribe/ $REMOTE_HOST:$REMOTE_RUN_ROOT/$tribe/"
    done
    emit_cmd "rsync -az --delete -e 'ssh -S $TUNNEL_SOCK' $FED_DIR/tools/ $REMOTE_HOST:$REMOTE_RUN_ROOT/tools/"
    emit_cmd "rsync -az --delete -e 'ssh -S $TUNNEL_SOCK' $FED_DIR/targets/ $REMOTE_HOST:$REMOTE_RUN_ROOT/targets/"
}

# --- 4 + 5) daemon spawns (laptop + server) ---
# Laptop side reuses run-stage2.sh's --enable-replication infrastructure
# by exporting STAGE2_RESUME_RUN_DIR-equivalent state and calling the
# tribe start-colony.sh scripts directly. The remote side runs them via
# `bash -lc` over SSH so $HOME/.profile sources the v1.7.0 binary into
# PATH (non-interactive SSH otherwise misses ~/.local/bin).
spawn_laptop_daemons() {
    emit_step "spawning laptop daemons: ${LAPTOP_TRIBES[*]}"
    for tribe in "${LAPTOP_TRIBES[@]}"; do
        emit_cmd "DEATH_THRESHOLD=$DEATH_THRESHOLD AGENTIS_ROOT=$RUN_DIR/.agentis $FED_DIR/$tribe/scripts/start-colony.sh >>$RUN_DIR/$tribe.log 2>&1 &"
    done
}

spawn_server_daemons() {
    emit_step "spawning server daemons: ${SERVER_TRIBES[*]}"
    for tribe in "${SERVER_TRIBES[@]}"; do
        emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'cd $REMOTE_RUN_ROOT && DEATH_THRESHOLD=$DEATH_THRESHOLD AGENTIS_ROOT=$REMOTE_RUN_ROOT/.agentis $REMOTE_RUN_ROOT/$tribe/scripts/start-colony.sh >>$REMOTE_RUN_ROOT/$tribe.log 2>&1 &'"
    done
}

stop_all_daemons() {
    emit_step "stopping all daemons (laptop + server)"
    KILL_SCRIPT="$REPO_ROOT/tools/kill-federation.sh"
    emit_cmd "bash $KILL_SCRIPT --fed-dir $RUN_DIR --no-backup >>$RUN_DIR/kill-federation.log 2>&1 || true"
    emit_cmd "ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc 'cd $REMOTE_RUN_ROOT && for t in ${SERVER_TRIBES[*]}; do pkill -f \"agentis daemon-inner.*\$t\" 2>/dev/null || true; done'"
}

# --- 6) target rotation timer ---
# The rotation loop runs in the background, sleeps ROTATION_INTERVAL,
# alternates exporting TARGET_DIR + BUGS_MANIFEST between the two
# planted-bug surfaces, and re-exports them into both hermetic .agentis
# environments via memo writes. (Daemons re-read on each tick.)
rotation_timer() {
    emit_step "starting target-rotation timer (interval=${ROTATION_INTERVAL}s)"
    emit_cmd "( phase=0; while true; do sleep $ROTATION_INTERVAL; phase=\$((1 - phase)); if [ \"\$phase\" = \"0\" ]; then td=$TARGET_A_DIR; bm=$TARGET_A_BUGS; else td=$TARGET_B_DIR; bm=$TARGET_B_BUGS; fi; printf '%s,%s,%s\\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$td\" \"\$bm\" >>$ROTATIONS_CSV; agentis memo set tribes-bench:target_dir \"\$td\" >/dev/null 2>&1 || true; agentis memo set tribes-bench:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; ssh -S $TUNNEL_SOCK $REMOTE_HOST bash -lc \"cd $REMOTE_RUN_ROOT && agentis memo set tribes-bench:target_dir '\$td' >/dev/null 2>&1 || true; agentis memo set tribes-bench:bugs_manifest '\$bm' >/dev/null 2>&1 || true\"; done ) >>$RUN_DIR/rotation.log 2>&1 & echo \$! >$RUN_DIR/rotation.pid"
}

stop_rotation_timer() {
    emit_step "stopping target-rotation timer"
    emit_cmd "kill \$(cat $RUN_DIR/rotation.pid 2>/dev/null) 2>/dev/null || true"
}

# --- 7) tear-down trap ---
install_cleanup_trap() {
    emit_step "installing cleanup trap (kill daemons → kill serves → close tunnel)"
    emit_cmd "trap 'stop_rotation_timer; stop_all_daemons; stop_local_serve; stop_remote_serve; close_tunnel' EXIT INT TERM"
}

# --- run-meta.json + telemetry stitching ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json,sys; json.dump({\"started_at\":\"$started_at\",\"wall_clock_s\":$WALL_CLOCK,\"rotation_interval_s\":$ROTATION_INTERVAL,\"death_threshold\":$DEATH_THRESHOLD,\"llm_backend\":\"$LLM_BACKEND\",\"nodes\":[{\"role\":\"laptop\",\"tribes\":[\"${LAPTOP_TRIBES[0]}\",\"${LAPTOP_TRIBES[1]}\"]},{\"role\":\"server\",\"host\":\"$REMOTE_HOST\",\"tribes\":[\"${SERVER_TRIBES[0]}\",\"${SERVER_TRIBES[1]}\",\"${SERVER_TRIBES[2]}\"]}]}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

pull_server_artifacts() {
    emit_step "rsyncing server hermetic .agentis/ back to $RUN_DIR/server-runs/"
    emit_cmd "rsync -az -e 'ssh -S $TUNNEL_SOCK' $REMOTE_HOST:$REMOTE_RUN_ROOT/.agentis/ $RUN_DIR/server-runs/$TS/.agentis/"
    emit_cmd "rsync -az -e 'ssh -S $TUNNEL_SOCK' $REMOTE_HOST:$REMOTE_RUN_ROOT/bug-ledger.jsonl $RUN_DIR/server-runs/$TS/bug-ledger.jsonl || true"
}

stitch_telemetry() {
    # analyse-stage2.py runs against the laptop run-dir (Stage 2 schema).
    # Server-side artefacts live at $RUN_DIR/server-runs/$TS/.agentis/ +
    # bug-ledger.jsonl after pull_server_artifacts(). The combined
    # telemetry-combined.csv (Stage 2 schema + node column) plus the
    # lineage / mutation / survivor / comparison-stage3.md outputs are
    # produced by analyse-stage3.py (Stage 3 piece 4, #439).
    emit_step "running analyse-stage3.py to stitch laptop + server telemetry"
    emit_cmd "python3 $TOOLS_DIR/analyse-stage3.py $RUN_DIR >>$ORCH_LOG 2>&1 || true"
}

# --- Orchestration body ---
install_cleanup_trap
open_tunnel
start_remote_serve
start_local_serve
configure_local_node
configure_remote_node
push_server_scaffolding
write_run_meta
spawn_laptop_daemons
spawn_server_daemons
rotation_timer

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no daemons spawned"
    exit 0
fi

emit_step "sleeping ${WALL_CLOCK}s for pilot wall clock"
sleep "$WALL_CLOCK"

# --- Tear-down (the trap also fires on EXIT, but we run the explicit
# pull-artifacts step before relinquishing the tunnel) ---
pull_server_artifacts
stitch_telemetry

emit_step "run-stage3-multinode: done"
echo "[run-stage3-multinode] run dir: $RUN_DIR"
