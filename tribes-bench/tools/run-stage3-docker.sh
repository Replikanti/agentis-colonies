#!/bin/bash
# run-stage3-docker.sh — Docker-based Stage 3 multinode orchestrator (#439).
#
# Sibling-alternative to run-stage3-multinode.sh. Where the SSH variant
# drives a real laptop+server pair through an SSH master channel + a
# port-forward, this orchestrator boots two podman containers on the
# same host and federates them via podman's host loopback bridge
# (host.containers.internal). Same tribe split (2 laptop / 3 server),
# same target rotation, same death threshold, same OpenAI backend
# defaults; the SSH variant remains untouched for later operator use.
#
# Why Docker: nine SSH-tier network events in one pilot night (race on
# remote serve.pid mkdir, login-shell PATH lookup miss, rsync push
# colliding with the federation's own write of bug-ledger.jsonl, ...)
# pushed us to a fully local 2-container shape that exercises the same
# federation surface without the SSH surface area. The SSH-based pilot
# is still the production target for the cross-host shape; this
# orchestrator is the dev/iteration loop.
#
# Tribe split rationale: 2-on-laptop / 3-on-server reflects the
# operator's typical resource asymmetry. We preserve that split here so
# telemetry produced by Docker pilots is comparable to the SSH variant's
# output by row-shape (2 + 3 tribe rows, same per-node `node` column in
# telemetry-combined.csv).
#
# Containers communicate via podman's `host.containers.internal` alias,
# which resolves to the host's loopback bridge (10.0.2.2 / equivalent on
# rootless podman). Each container runs an `agentis serve` on a host-
# mapped port (laptop 9100 → host 9100, server 9101 → host 9101); their
# federation.peers list contains the OTHER node's host port via that
# alias so reachability is symmetric.
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
#   STAGE3_OPENAI_TIMEOUT_MS   Per-request timeout (ms). Default: 180000.
#   STAGE3_LAPTOP_PORT         Host port for the laptop container's
#                              agentis serve. Default: 9100.
#   STAGE3_SERVER_PORT         Host port for the server container's
#                              agentis serve. Default: 9101.
#   STAGE3_LAPTOP_WORKER_PORT  Host port for the laptop container's
#                              agentis worker (replicate dispatch target).
#                              Default: 9200.
#   STAGE3_SERVER_WORKER_PORT  Host port for the server container's
#                              agentis worker. Default: 9201.
#   STAGE3_WORKER_SECRET       Shared secret for cross-container worker
#                              auth. Default: auto-generated per run via
#                              the same idiom as start-federation.sh
#                              (16 bytes urandom, base64-trimmed).
#                              Override only for debugging — restarting
#                              one container with a stale value while the
#                              other holds the auto-generated secret will
#                              break replicate() auth.
#   STAGE3_IMAGE_TAG           Image tag built from Containerfile.stage3.
#                              Default: tribes-bench-stage3:latest.
#   STAGE3_LAPTOP_TRIBES       Space-separated tribe list for the laptop
#                              container. Default: "tribe-alpha tribe-beta".
#   STAGE3_SERVER_TRIBES       Space-separated tribe list for the server
#                              container.
#                              Default: "tribe-gamma tribe-delta tribe-epsilon".
#   STAGE3_TARGET_A_DIR        Repo-relative path to the rotation-A
#                              target dir. Default:
#                              targets/stage2/smallvec-v0.6.13.
#   STAGE3_TARGET_A_BUGS       Repo-relative path to the rotation-A
#                              bugs.json. Default: targets/stage2/bugs.json.
#   STAGE3_TARGET_B_DIR        Rotation-B target dir.
#                              Default: targets/stage3/bumpalo-v3.2.0.
#   STAGE3_TARGET_B_BUGS       Rotation-B bugs.json.
#                              Default: targets/stage3/bugs.json.
#   STAGE3_DRY_RUN             1 = echo every command (with `+ ` prefix),
#                              do not build the image, do not spawn
#                              containers, do not exec rotation memos,
#                              exit 0. Default: 0. Equivalent to passing
#                              the --dry-run flag.
#
# Flags:
#   --dry-run    See STAGE3_DRY_RUN.
#
# Output layout (under tribes-bench/runs/stage3-docker-<ts>/):
#   run-meta.json             start ts, end ts, wall clock, rotation
#                             interval, death threshold, llm backend,
#                             container ids
#   orchestrator.log          orchestrator's own log
#   laptop-node/              bind-mounted into stage3-laptop:/run-root
#     bootstrap.sh
#     .agentis/               hermetic agentis root (laptop-side)
#     <tribe>.log
#     bug-ledger.jsonl
#     knowledge-market.csv
#   server-node/              bind-mounted into stage3-server:/run-root
#     (same shape as laptop-node)
#   rotations.csv             one row per rotation event
#                             (ts,target_dir,bugs_manifest)
#
# Exit codes:
#   0   pilot completed
#   1   prerequisite missing (podman, jq, python3) or invalid env var
#   2   image build failed
#   3   container spawn failed

set -euo pipefail

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
TOOLS_DIR="$(dirname "$SCRIPT_PATH")"
FED_DIR="$(dirname "$TOOLS_DIR")"
REPO_ROOT="$(dirname "$FED_DIR")"

# --- Argument parsing ---
DRY_RUN="${STAGE3_DRY_RUN:-0}"
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            sed -n '2,98p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "run-stage3-docker: unknown argument: $1" >&2
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
LAPTOP_PORT="${STAGE3_LAPTOP_PORT:-9100}"
SERVER_PORT="${STAGE3_SERVER_PORT:-9101}"
LAPTOP_WORKER_PORT="${STAGE3_LAPTOP_WORKER_PORT:-9200}"
SERVER_WORKER_PORT="${STAGE3_SERVER_WORKER_PORT:-9201}"
IMAGE_TAG="${STAGE3_IMAGE_TAG:-tribes-bench-stage3:latest}"
LAPTOP_TRIBES_RAW="${STAGE3_LAPTOP_TRIBES:-tribe-alpha tribe-beta}"
SERVER_TRIBES_RAW="${STAGE3_SERVER_TRIBES:-tribe-gamma tribe-delta tribe-epsilon}"
TARGET_A_DIR_REL="${STAGE3_TARGET_A_DIR:-targets/stage2/smallvec-v0.6.13}"
TARGET_A_BUGS_REL="${STAGE3_TARGET_A_BUGS:-targets/stage2/bugs.json}"
TARGET_B_DIR_REL="${STAGE3_TARGET_B_DIR:-targets/stage3/bumpalo-v3.2.0}"
TARGET_B_BUGS_REL="${STAGE3_TARGET_B_BUGS:-targets/stage3/bugs.json}"

val=""
for var_name in WALL_CLOCK ROTATION_INTERVAL DEATH_THRESHOLD \
                OPENAI_TIMEOUT_MS LAPTOP_PORT SERVER_PORT \
                LAPTOP_WORKER_PORT SERVER_WORKER_PORT; do
    eval "val=\${$var_name}"
    case "$val" in
        ''|*[!0-9]*)
            echo "run-stage3-docker: $var_name must be a positive integer (got: $val)" >&2
            exit 1
            ;;
    esac
done
unset val

# Convert space-separated tribe lists into arrays (set -u + IFS-default
# splitting cooperate as long as we don't quote the expansion here).
# shellcheck disable=SC2206
LAPTOP_TRIBES=( $LAPTOP_TRIBES_RAW )
# shellcheck disable=SC2206
SERVER_TRIBES=( $SERVER_TRIBES_RAW )

# --- Per-run worker secret (#465) ---
# Mirrors the start-federation.sh:64 idiom so cross-container
# replicate() lands on a peer `agentis worker` with matching auth.
# Operator override via STAGE3_WORKER_SECRET is supported but
# discouraged outside debugging — see header.
WORKER_SECRET="${STAGE3_WORKER_SECRET:-$(head -c 16 /dev/urandom | base64 | tr -d '/+=' | head -c 16)}"

# --- Per-run hermetic dir ---
TS="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$FED_DIR/runs/stage3-docker-$TS"
ORCH_LOG="$RUN_DIR/orchestrator.log"
ROTATIONS_CSV="$RUN_DIR/rotations.csv"
RUN_META="$RUN_DIR/run-meta.json"

LAPTOP_DIR="$RUN_DIR/laptop-node"
SERVER_DIR="$RUN_DIR/server-node"

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
    for bin in podman jq python3; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            echo "run-stage3-docker: $bin not found on PATH" >&2
            exit 1
        fi
    done
    # OpenAI key pre-flight (only when openai backend is selected). We
    # check via `eval` so STAGE3_OPENAI_KEY_ENV can name a non-default
    # env var (e.g. OPENAI_API_KEY_PILOT).
    if [ "$LLM_BACKEND" = "openai" ]; then
        eval "openai_key_value=\${$OPENAI_KEY_ENV:-}"
        if [ -z "${openai_key_value:-}" ]; then
            echo "run-stage3-docker: \$$OPENAI_KEY_ENV is empty (required for llm.backend=openai)" >&2
            exit 1
        fi
        unset openai_key_value
    fi
    mkdir -p "$RUN_DIR" "$LAPTOP_DIR" "$SERVER_DIR"
    : >"$ORCH_LOG"
    : >"$ROTATIONS_CSV"
    printf 'ts,target_dir,bugs_manifest\n' >"$ROTATIONS_CSV"
fi

emit_step "run-stage3-docker: starting (dry_run=$DRY_RUN)"
emit_step "run dir: $RUN_DIR"
emit_step "wall clock: ${WALL_CLOCK}s, rotation: ${ROTATION_INTERVAL}s, death threshold: ${DEATH_THRESHOLD}"
emit_step "tribes: laptop=[${LAPTOP_TRIBES[*]}] server=[${SERVER_TRIBES[*]}]"
emit_step "image tag: $IMAGE_TAG"
emit_step "host ports: laptop=$LAPTOP_PORT server=$SERVER_PORT"
emit_step "worker ports: laptop=$LAPTOP_WORKER_PORT server=$SERVER_WORKER_PORT"
emit_step "generated worker secret (len=${#WORKER_SECRET})"

# --- 1) Build (or reuse) the container image ---
build_image() {
    emit_step "checking for existing image $IMAGE_TAG (build if missing)"
    emit_cmd "podman image exists $IMAGE_TAG || podman build -t $IMAGE_TAG -f $TOOLS_DIR/Containerfile.stage3 $FED_DIR"
}

# --- 2) Per-node bootstrap script generator ---
# write_bootstrap emits a self-contained bash script into <node-dir>/
# bootstrap.sh that, when executed inside the container, performs:
#   1. agentis init in /run-root (idempotent — already-initialised root
#      is a no-op)
#   2. Append federation/llm config lines to .agentis/config (peers
#      reach the other node via host.containers.internal:<peer-port>)
#   3. Copy tribe scaffolding + tools/ + targets/ + calibration.toml from
#      the read-only /repo bind-mount into /run-root
#   4. Spawn `agentis serve` on the in-container port
#   5. Spawn each tribe's start-colony.sh with DEATH_THRESHOLD +
#      AGENTIS_ROOT exported
#   6. Block until /run-root/.shutdown is touched by the host orchestrator
write_bootstrap() {
    role="$1"             # laptop | server
    node_dir="$2"         # $LAPTOP_DIR or $SERVER_DIR
    self_port="$3"        # in-container serve port (also host port)
    peer_port="$4"        # peer serve port (federation discovery)
    self_worker_port="$5" # in-container worker port (#465)
    peer_worker_port="$6" # peer worker port — replicate() target (#465)
    tribes_str="$7"       # space-separated

    bootstrap_path="$node_dir/bootstrap.sh"
    emit_step "generating bootstrap script for $role at $bootstrap_path"

    if [ "$DRY_RUN" = "1" ]; then
        # Echo a synthesised path-only command line so the dry-run
        # transcript covers each bootstrap.sh write without inflating
        # the dry-run output with the full multi-line file body.
        emit_cmd "write-bootstrap role=$role path=$bootstrap_path self_port=$self_port peer_port=$peer_port self_worker_port=$self_worker_port peer_worker_port=$peer_worker_port tribes=\"$tribes_str\""
        return
    fi

    {
        printf '#!/bin/bash\n'
        printf '# Auto-generated by run-stage3-docker.sh — runs inside the container.\n'
        printf 'set -euo pipefail\n'
        printf 'cd /run-root\n'
        printf 'agentis init >/dev/null 2>&1 || true\n'
        # Mirror run-stage2.sh lines 193-263 setup. Without these keys
        # the agent runtime silently degrades: exec sh in .ag agents
        # cannot see TARGET_DIR / VERIFIER_PATH (no env_passthrough),
        # learn() rows never land in .agentis/experience/ (experience
        # disabled), telemetry events vanish (telemetry disabled), and
        # slow LLM rounds trigger watchdog kill cascade (default
        # heartbeat = tick_interval * 2 = 120s; openai gpt-4o-mini at
        # 20k tokens can take 90+ seconds).
        printf '{\n'
        printf '  printf "federation.enabled = true\\n"\n'
        printf '  printf "federation.peers = host.containers.internal:%s\\n"\n' "$peer_port"
        printf '  printf "exec.env_passthrough = COLONY_DIR,TRIBE_NAME,TARGET_DIR,TARGET_FILE,BUGS_MANIFEST,VERIFIER_PATH,RUN_DIR,BUG_LEDGER_PATH,INITIAL_CB,BASE_COST,K_MALTHUSIAN,MAX_REPLICAS,REWARD_FULL,REWARD_SUBSEQUENT,DEATH_THRESHOLD,AGENTIS_ROOT\\n"\n'
        printf '  printf "experience.enabled = true\\n"\n'
        printf '  printf "telemetry.enabled = true\\n"\n'
        printf '  printf "daemon.heartbeat_interval_ms = 600000\\n"\n'
        printf '  printf "llm.backend = %s\\n"\n' "$LLM_BACKEND"
        if [ "$LLM_BACKEND" = "openai" ]; then
            printf '  printf "llm.openai.endpoint = %s\\n"\n' "$OPENAI_ENDPOINT"
            printf '  printf "llm.openai.model = %s\\n"\n' "$OPENAI_MODEL"
            printf '  printf "llm.openai.api_key_env = %s\\n"\n' "$OPENAI_KEY_ENV"
            printf '  printf "llm.openai.timeout_ms = %s\\n"\n' "$OPENAI_TIMEOUT_MS"
        fi
        printf '  printf "colony.secret = %%s\\n" "$WORKER_SECRET"\n'
        printf '} >> .agentis/config\n'
        # Bring tribes-bench/tools first, then merge in the repo-root tools/
        # which carries platform helpers (parse-toml.sh, kill-federation.sh)
        # that start-colony.sh's `<fed>/tools/parse-toml.sh` lookup needs.
        # The two source dirs have non-overlapping filenames so the order
        # is stable; cp -n is a defensive no-clobber in case a future
        # rename ever introduces a collision.
        printf 'cp -r /repo/tribes-bench/tools /run-root/tools\n'
        printf 'cp -rn /repo/tools/. /run-root/tools/\n'
        printf 'cp -r /repo/tribes-bench/targets /run-root/targets\n'
        printf 'cp /repo/tribes-bench/calibration.toml /run-root/calibration.toml\n'
        for tribe in $tribes_str; do
            printf 'cp -r /repo/tribes-bench/%s /run-root/%s\n' "$tribe" "$tribe"
        done
        # agentis sandbox refuses any path outside <agentis-root>/sandbox/.
        # run-stage2.sh handles this by copying targets INTO the sandbox
        # tree (see lines 187-190 of run-stage2.sh) and exporting
        # TARGET_DIR_SANDBOX as a relative path. Mirror that pattern here
        # so hunter agents can read the planted-bug source files at tick
        # time without "path outside sandbox" errors.
        printf 'mkdir -p /run-root/.agentis/sandbox\n'
        printf 'cp -r /run-root/targets/stage2 /run-root/.agentis/sandbox/targets-stage2\n'
        printf 'cp -r /run-root/targets/stage3 /run-root/.agentis/sandbox/targets-stage3 2>/dev/null || true\n'
        printf 'cp -r /run-root/targets/stage0 /run-root/.agentis/sandbox/targets-stage0 2>/dev/null || true\n'
        printf 'cp -r /run-root/targets/stage1 /run-root/.agentis/sandbox/targets-stage1 2>/dev/null || true\n'
        # Seed propose-tier confidence (default tier without seed is
        # dormant; tribes-bench Stage 2 convention is propose at 0.7,
        # mirrored from run-stage2.sh line 272). Without this seed the
        # hunter ticks at conf=0 → dormant → no LLM call → no findings.
        printf '(cd /run-root && agentis memo set hunter:confidence 0.7 >/dev/null 2>&1 || true)\n'
        # Stage 3 cross-node replication (#460 PR B + #465): seed the
        # peer-worker address list so hunter's
        # select_replication_target() rotates the replicate(target) call
        # across nodes. Each container gets exactly one peer (the other
        # node), reachable at host.containers.internal on the peer's
        # WORKER port (not the serve port — replicate dispatch needs an
        # `agentis worker` listener on the matching shared secret).
        # Indexed key + count memo shape is read by the hunter helper
        # via recall_latest("...:peer_worker_addr:0") plus
        # recall_latest("...:peer_worker_count").
        # #474: agentis-core perform_replication() parses target via
        # SocketAddr::parse() which rejects hostnames; resolve
        # host.containers.internal to its IP at container exec time and
        # seed the memo with IP:port so the parse succeeds.
        printf 'PEER_HOST_IP=$(getent hosts host.containers.internal | awk '\''{print $1}'\'')\n'
        printf '(cd /run-root && agentis memo set tribes-bench:peer_worker_addr:0 "$PEER_HOST_IP:%s" >/dev/null 2>&1 || true)\n' "$peer_worker_port"
        printf '(cd /run-root && agentis memo set tribes-bench:peer_worker_count 1 >/dev/null 2>&1 || true)\n'
        printf 'agentis serve 0.0.0.0:%s > /run-root/serve.log 2>&1 &\n' "$self_port"
        printf 'echo $! > /run-root/serve.pid\n'
        # Stage 3 cross-container replicate dispatch (#465): a peer's
        # replicate(target) call lands on this worker. WORKER_SECRET is
        # injected via `podman run -e WORKER_SECRET=...` and must match
        # on both nodes for auth to succeed. Bind 0.0.0.0 so podman's
        # host-bridge maps host:<self_worker_port> → container:<self_worker_port>.
        # Pure-bash poll on /dev/tcp avoids relying on iproute2 / netcat
        # being present in the base image (Containerfile.stage3 ships
        # only python3/jq/git/curl/ca-certificates). Cap at 30 iterations
        # (~15s) so a broken worker does not hang bootstrap forever.
        printf 'agentis worker 0.0.0.0:%s --secret "$WORKER_SECRET" --max-concurrent 8 > /run-root/worker.log 2>&1 &\n' "$self_worker_port"
        printf 'echo $! > /run-root/worker.pid\n'
        printf 'for _ in $(seq 1 30); do\n'
        printf '    if (exec 3<>/dev/tcp/127.0.0.1/%s) 2>/dev/null; then exec 3<&-; exec 3>&-; break; fi\n' "$self_worker_port"
        printf '    sleep 0.5\n'
        printf 'done\n'
        for tribe in $tribes_str; do
            # Pass TARGET_DIR + TARGET_FILE + BUGS_MANIFEST + VERIFIER_PATH
            # as env into start-colony.sh so the hunter resolves planted-
            # bug source files inside the sandbox. TARGET_DIR is a path
            # RELATIVE to /run-root/.agentis/sandbox/ (agentis sandbox
            # convention). The rotation timer overrides these via memo
            # writes once the first rotation interval elapses, but the
            # bootstrap default lets daemons land on a working Stage 2
            # target on tick 1 instead of the broken Stage 0 fallback.
            # BUG_LEDGER_PATH gives start-colony.sh the host-side ledger
            # file to seed the tribe-<name>:bug_ledger memo from. Without
            # it, hunters verify findings but the JSONL ledger never
            # grows (visible in experience but missing from bug-ledger).
            printf 'DEATH_THRESHOLD=%s AGENTIS_ROOT=/run-root/.agentis TARGET_DIR=targets-stage2/smallvec-v0.6.13 TARGET_FILE=lib.rs BUGS_MANIFEST=/run-root/.agentis/sandbox/targets-stage2/bugs.json VERIFIER_PATH=/run-root/tools/verify-finding-stage2.sh BUG_LEDGER_PATH=/run-root/bug-ledger.jsonl bash /run-root/%s/scripts/start-colony.sh > /run-root/%s.log 2>&1 &\n' \
                "$DEATH_THRESHOLD" "$tribe" "$tribe"
        done
        printf 'while [ ! -e /run-root/.shutdown ]; do sleep 5; done\n'
        printf 'exit 0\n'
    } >"$bootstrap_path"
    chmod +x "$bootstrap_path"
}

write_bootstraps() {
    write_bootstrap "laptop" "$LAPTOP_DIR" "$LAPTOP_PORT" "$SERVER_PORT" \
        "$LAPTOP_WORKER_PORT" "$SERVER_WORKER_PORT" "${LAPTOP_TRIBES[*]}"
    write_bootstrap "server" "$SERVER_DIR" "$SERVER_PORT" "$LAPTOP_PORT" \
        "$SERVER_WORKER_PORT" "$LAPTOP_WORKER_PORT" "${SERVER_TRIBES[*]}"
}

# --- 3) Spawn the two containers ---
# Note on host.containers.internal: this is podman's documented analog
# of docker's host.docker.internal and resolves to the host's loopback
# bridge under both rootful and rootless podman 4.x+. If a future host's
# podman setup misses this alias (some legacy CNI configs), pass
# --add-host host.containers.internal:<host-bridge-ip> to both runs.
spawn_containers() {
    emit_step "spawning stage3-laptop container (host port $LAPTOP_PORT, worker port $LAPTOP_WORKER_PORT)"
    emit_cmd "podman run -d --name stage3-laptop -p $LAPTOP_PORT:$LAPTOP_PORT -p $LAPTOP_WORKER_PORT:$LAPTOP_WORKER_PORT -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -e WORKER_SECRET=\"$WORKER_SECRET\" -v $REPO_ROOT:/repo:ro -v $LAPTOP_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
    emit_step "spawning stage3-server container (host port $SERVER_PORT, worker port $SERVER_WORKER_PORT)"
    emit_cmd "podman run -d --name stage3-server -p $SERVER_PORT:$SERVER_PORT -p $SERVER_WORKER_PORT:$SERVER_WORKER_PORT -e $OPENAI_KEY_ENV=\"\${$OPENAI_KEY_ENV:-}\" -e WORKER_SECRET=\"$WORKER_SECRET\" -v $REPO_ROOT:/repo:ro -v $SERVER_DIR:/run-root:rw $IMAGE_TAG /run-root/bootstrap.sh"
}

# --- 4) Target rotation timer (runs on the host, not inside containers) ---
# The rotation loop sleeps ROTATION_INTERVAL, alternates target_dir +
# bugs_manifest between the two planted-bug surfaces, and re-exports
# them into BOTH containers via `podman exec ... agentis memo set`.
# Daemons re-read on each tick. Path values use container-side absolute
# paths (/run-root/targets/...), since memos are read inside containers.
rotation_timer() {
    emit_step "starting target-rotation timer (interval=${ROTATION_INTERVAL}s)"
    emit_cmd "( phase=0; while true; do sleep $ROTATION_INTERVAL; phase=\$((1 - phase)); if [ \"\$phase\" = \"0\" ]; then td=/run-root/$TARGET_A_DIR_REL; bm=/run-root/$TARGET_A_BUGS_REL; else td=/run-root/$TARGET_B_DIR_REL; bm=/run-root/$TARGET_B_BUGS_REL; fi; printf '%s,%s,%s\\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" \"\$td\" \"\$bm\" >>$ROTATIONS_CSV; podman exec stage3-laptop agentis memo set tribes-bench:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-laptop agentis memo set tribes-bench:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set tribes-bench:target_dir \"\$td\" >/dev/null 2>&1 || true; podman exec stage3-server agentis memo set tribes-bench:bugs_manifest \"\$bm\" >/dev/null 2>&1 || true; done ) >>$RUN_DIR/rotation.log 2>&1 & echo \$! >$RUN_DIR/rotation.pid"
}

stop_rotation_timer() {
    emit_step "stopping target-rotation timer"
    emit_cmd "kill \$(cat $RUN_DIR/rotation.pid 2>/dev/null) 2>/dev/null || true"
}

# --- 5) Cleanup trap ---
# Cleanup is idempotent: stop sends SIGTERM with a 5s grace, rm -f
# nukes whatever's left. Both calls swallow errors so a partially-
# failed spawn (only one of the two containers up) still tears down
# whatever did come up.
install_cleanup_trap() {
    emit_step "installing cleanup trap (stop + rm both containers)"
    emit_cmd "trap 'stop_rotation_timer; podman stop --time 5 stage3-laptop stage3-server 2>/dev/null || true; podman rm -f stage3-laptop stage3-server 2>/dev/null || true' EXIT INT TERM"
}

# --- 6) Shutdown signal to both containers ---
signal_shutdown() {
    emit_step "signalling shutdown to both containers (touch /run-root/.shutdown)"
    emit_cmd "podman exec stage3-laptop touch /run-root/.shutdown 2>/dev/null || true"
    emit_cmd "podman exec stage3-server touch /run-root/.shutdown 2>/dev/null || true"
}

# --- 7) run-meta.json ---
write_run_meta() {
    emit_step "writing run-meta.json"
    started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    emit_cmd "python3 -c 'import json,sys; json.dump({\"started_at\":\"$started_at\",\"wall_clock_s\":$WALL_CLOCK,\"rotation_interval_s\":$ROTATION_INTERVAL,\"death_threshold\":$DEATH_THRESHOLD,\"llm_backend\":\"$LLM_BACKEND\",\"image_tag\":\"$IMAGE_TAG\",\"nodes\":[{\"role\":\"laptop\",\"container\":\"stage3-laptop\",\"host_port\":$LAPTOP_PORT,\"tribes\":\"${LAPTOP_TRIBES[*]}\".split()},{\"role\":\"server\",\"container\":\"stage3-server\",\"host_port\":$SERVER_PORT,\"tribes\":\"${SERVER_TRIBES[*]}\".split()}]}, open(\"$RUN_META\",\"w\"), indent=2)'"
}

# --- 8) Verify artefacts on host ---
verify_artefacts() {
    emit_step "verifying per-node artefacts on host (bug-ledger.jsonl + telemetry.csv)"
    emit_cmd "ls -la $LAPTOP_DIR/bug-ledger.jsonl $LAPTOP_DIR/telemetry.csv 2>/dev/null || true"
    emit_cmd "ls -la $SERVER_DIR/bug-ledger.jsonl $SERVER_DIR/telemetry.csv 2>/dev/null || true"
}

# --- 9) Stitch via analyse-stage3.py ---
# analyse-stage3.py takes the run-dir + --server-runs subdir. The
# laptop hermetic root is expected at <run-dir>/.agentis/, but in this
# Docker layout the laptop root lives at <run-dir>/laptop-node/.agentis/.
# Until analyse-stage3.py grows a --laptop-runs flag (follow-up issue),
# we still invoke it with --server-runs server-node so the server side
# is stitched correctly; the laptop side may report missing artefacts
# until the follow-up lands. Captured non-fatally with || true.
stitch_telemetry() {
    emit_step "running analyse-stage3.py to stitch laptop + server telemetry"
    emit_cmd "python3 $TOOLS_DIR/analyse-stage3.py $RUN_DIR --server-runs server-node >>$ORCH_LOG 2>&1 || true"
}

# --- Orchestration body ---
install_cleanup_trap
build_image
write_bootstraps
write_run_meta
spawn_containers
rotation_timer

if [ "$DRY_RUN" = "1" ]; then
    emit_step "dry-run complete; no containers spawned"
    exit 0
fi

emit_step "sleeping ${WALL_CLOCK}s for pilot wall clock"
sleep "$WALL_CLOCK"

signal_shutdown
verify_artefacts
stitch_telemetry

emit_step "run-stage3-docker: done"
echo "[run-stage3-docker] run dir: $RUN_DIR"
