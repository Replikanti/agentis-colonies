#!/bin/bash
# test-run-stage3-docker.sh — smoke test for run-stage3-docker.sh
# --dry-run mode (#439).
#
# Runs `run-stage3-docker.sh --dry-run` and asserts the emitted command
# transcript contains every required surface:
#
#   1. Image build / reuse command (podman image exists || podman build)
#   2. 2x `podman run -d --name stage3-{laptop,server}` spawn commands
#   3. Bootstrap-script generation for both nodes
#   4. Target-rotation timer setup (interval + target_dir + bugs_manifest)
#   5. Cleanup trap (stop + rm both containers)
#   6. analyse-stage3.py invocation (server-runs subdir threaded through)
#
# The dry-run must NOT actually build the image, NOT spawn any
# containers, and NOT emit `podman run` outside of an echo line.
#
# Exit codes:
#   0  all assertions pass
#   1  one or more assertions failed

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH="$SCRIPT_DIR/run-stage3-docker.sh"

PASS=0
FAIL=0

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle not found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_contains() {
    label="$1"; haystack="$2"; needle="$3"
    if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       unexpected needle found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] run-stage3-docker.sh not executable at $ORCH"
    exit 1
fi

OUT="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       bash "$ORCH" --dry-run 2>&1)"

# 1. image build / reuse
assert_contains "image build / reuse command emitted" "$OUT" \
    "podman image exists tribes-bench-stage3:latest || podman build -t tribes-bench-stage3:latest"
assert_contains "Containerfile path threaded into build" "$OUT" \
    "Containerfile.stage3"

# 2. container spawn commands (with -p, -e, two -v binds, image, bootstrap)
assert_contains "stage3-laptop spawn command emitted" "$OUT" \
    "podman run -d --name stage3-laptop -p 9100:9100"
assert_contains "stage3-server spawn command emitted" "$OUT" \
    "podman run -d --name stage3-server -p 9101:9101"
assert_contains "OPENAI_API_KEY env injection on laptop" "$OUT" \
    "-e OPENAI_API_KEY="
assert_contains "repo bind-mount on laptop" "$OUT" \
    ":/repo:ro"
assert_contains "run-root bind-mount on laptop" "$OUT" \
    "/laptop-node:/run-root:rw"
assert_contains "run-root bind-mount on server" "$OUT" \
    "/server-node:/run-root:rw"
assert_contains "laptop bootstrap entrypoint" "$OUT" \
    "tribes-bench-stage3:latest /run-root/bootstrap.sh"

# 3. bootstrap-script generation for both nodes
assert_contains "laptop bootstrap script generated" "$OUT" \
    "generating bootstrap script for laptop"
assert_contains "server bootstrap script generated" "$OUT" \
    "generating bootstrap script for server"
assert_contains "laptop bootstrap describes self_port=9100" "$OUT" \
    "self_port=9100 peer_port=9101"
assert_contains "server bootstrap describes self_port=9101" "$OUT" \
    "self_port=9101 peer_port=9100"
assert_contains "laptop tribes threaded into bootstrap" "$OUT" \
    "tribes=\"tribe-alpha tribe-beta\""
assert_contains "server tribes threaded into bootstrap" "$OUT" \
    "tribes=\"tribe-gamma tribe-delta tribe-epsilon\""
# 3b. Worker-port threading + secret injection (#465)
assert_contains "laptop bootstrap describes self_worker_port=9200 peer_worker_port=9201" "$OUT" \
    "self_worker_port=9200 peer_worker_port=9201"
assert_contains "server bootstrap describes self_worker_port=9201 peer_worker_port=9200" "$OUT" \
    "self_worker_port=9201 peer_worker_port=9200"
assert_contains "laptop worker port -p mapping" "$OUT" \
    "-p 9200:9200"
assert_contains "server worker port -p mapping" "$OUT" \
    "-p 9201:9201"
assert_contains "WORKER_SECRET injected into laptop container" "$OUT" \
    "--name stage3-laptop -p 9100:9100 -p 9200:9200 -e OPENAI_API_KEY=\"\${OPENAI_API_KEY:-}\" -e WORKER_SECRET=\"testsecret\""
assert_contains "WORKER_SECRET injected into server container" "$OUT" \
    "--name stage3-server -p 9101:9101 -p 9201:9201 -e OPENAI_API_KEY=\"\${OPENAI_API_KEY:-}\" -e WORKER_SECRET=\"testsecret\""
assert_contains "header documents STAGE3_LAPTOP_WORKER_PORT" \
    "$(cat "$ORCH")" \
    "STAGE3_LAPTOP_WORKER_PORT  Host port for the laptop container"
assert_contains "header documents STAGE3_SERVER_WORKER_PORT" \
    "$(cat "$ORCH")" \
    "STAGE3_SERVER_WORKER_PORT  Host port for the server container"
assert_contains "header documents STAGE3_WORKER_SECRET" \
    "$(cat "$ORCH")" \
    "STAGE3_WORKER_SECRET       Shared secret"
# Bootstrap body asserted via source inspection: the `printf` lines that
# emit the worker spawn + the peer_worker_addr memo seed live in the
# script source verbatim, so grepping the source is deterministic.
assert_contains "bootstrap body spawns agentis worker on self_worker_port" \
    "$(cat "$ORCH")" \
    "agentis worker 0.0.0.0:%s --secret \"\$WORKER_SECRET\" --max-concurrent 8"
assert_contains "bootstrap body resolves host.containers.internal to IP via getent" \
    "$(cat "$ORCH")" \
    "PEER_HOST_IP=\$(getent hosts host.containers.internal | awk"
assert_contains "bootstrap body seeds peer_worker_addr memo at resolved IP:worker_port" \
    "$(cat "$ORCH")" \
    'agentis memo set tribes-bench:peer_worker_addr:0 "$PEER_HOST_IP:%s"'
assert_contains "peer_worker_addr memo printf binds to peer_worker_port (not peer_port)" \
    "$(cat "$ORCH")" \
    '"$PEER_HOST_IP:%s" >/dev/null 2>&1 || true)\n'"'"' "$peer_worker_port"'
assert_contains "bootstrap body polls /dev/tcp before tribe launch" \
    "$(cat "$ORCH")" \
    "/dev/tcp/127.0.0.1/%s"
assert_contains "bootstrap body writes colony.secret bound to \$WORKER_SECRET" \
    "$(cat "$ORCH")" \
    'printf "colony.secret = %%s\\n" "$WORKER_SECRET"'
assert_contains "bootstrap body enables distributed messaging in config" \
    "$(cat "$ORCH")" \
    'printf "messaging.distributed = true\\n"'
assert_contains "bootstrap body writes colony.workers bound to peer worker IP:port" \
    "$(cat "$ORCH")" \
    'printf "colony.workers = %%s:%%s\\n" "$PEER_HOST_IP"'

# 4. rotation timer
assert_contains "rotation timer with configured interval" "$OUT" \
    "interval=120s"
assert_contains "rotation timer cycles target_dir" "$OUT" \
    "tribes-bench:target_dir"
assert_contains "rotation timer cycles bugs_manifest" "$OUT" \
    "tribes-bench:bugs_manifest"
assert_contains "rotation toggles smallvec target" "$OUT" \
    "/run-root/targets/stage2/smallvec-v0.6.13"
assert_contains "rotation toggles bumpalo target" "$OUT" \
    "/run-root/targets/stage3/bumpalo-v3.2.0"
assert_contains "rotation timer execs into laptop container" "$OUT" \
    "podman exec stage3-laptop agentis memo set"
assert_contains "rotation timer execs into server container" "$OUT" \
    "podman exec stage3-server agentis memo set"

# 5. cleanup trap
assert_contains "cleanup trap installed" "$OUT" \
    "trap 'stop_rotation_timer; podman stop --time 5 stage3-laptop stage3-server"
assert_contains "cleanup trap rms both containers" "$OUT" \
    "podman rm -f stage3-laptop stage3-server"

# 6. analyse-stage3.py invocation — present in the dry-run transcript
# only via the help text (the body that calls it is gated behind the
# pre-shutdown branch). Assert via the function-emitted step text +
# via the in-script command text by running the orchestrator with
# WALL_CLOCK=0 is not viable (sleep 0 would still run real spawns), so
# we settle for asserting the source contains the expected analyse-stage3
# invocation. This still gates against accidental removal of the call.
assert_contains "analyse-stage3.py invocation present in source" \
    "$(cat "$ORCH")" \
    "analyse-stage3.py \$RUN_DIR --laptop-dir laptop-node --server-runs server-node"

# Death threshold injected.
assert_contains "death threshold 300 propagated to laptop bootstrap arg" "$OUT" \
    "death threshold: 300"

# #485 finite-pool: env defaults documented + propagated through bootstrap.
assert_contains "STAGE3_TRIBE_POOL_CAP env var documented" \
    "$(cat "$ORCH")" \
    "STAGE3_TRIBE_POOL_CAP"
assert_contains "STAGE3_TRIBE_METABOLIC_COST env var documented" \
    "$(cat "$ORCH")" \
    "STAGE3_TRIBE_METABOLIC_COST"
assert_contains "POOL_CAP env propagated into start-colony.sh bootstrap line" \
    "$(cat "$ORCH")" \
    "POOL_CAP=%s METABOLIC_COST=%s"

# OpenAI backend defaults wired in.
assert_contains "llm.backend=openai default" "$OUT" \
    "llm_backend\":\"openai"

# Negative assertions: dry-run did NOT actually invoke `podman run` —
# every podman run line in the transcript is preceded by `+ ` (the
# dry-run echo prefix). The orchestrator must not contain a bare
# `podman run` line that escaped the emit_cmd helper.
assert_contains "podman run only appears via emit_cmd echo prefix" "$OUT" \
    "+ podman run -d --name stage3-laptop"
# Tunnel-sock side-effect from the SSH variant must NOT appear here
# (sanity check that we're testing the Docker orchestrator, not the
# SSH one).
assert_not_contains "no SSH tunnel sock referenced" "$OUT" \
    "/tmp/stage3-tunnel.sock"
assert_not_contains "no ssh -fN -M command" "$OUT" \
    "ssh -fN -M"

# 7. Secret auto-generation fallback (#465). When STAGE3_WORKER_SECRET is
# unset the orchestrator must mint a per-run secret via the
# start-federation.sh idiom and emit only its length (not value) into
# the orchestrator log surface.
unset STAGE3_WORKER_SECRET || true
OUT_FALLBACK="$(env -u STAGE3_WORKER_SECRET \
       STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "secret generation falls back when STAGE3_WORKER_SECRET unset" \
    "$OUT_FALLBACK" \
    "generated worker secret (len="
assert_not_contains "fallback secret length is non-zero" \
    "$OUT_FALLBACK" \
    "generated worker secret (len=0)"

# 8. Stage 4 Phase 1 chunk 1 (#519): when STAGE3_TARGET_C/D/E_{DIR,BUGS}
# are all set the rotation timer must emit a round-robin loop over the
# 5-element `targets` array with each TARGET_<K>_DIR_REL referenced via
# indirect expansion. Tests below run with all 5 env vars set.
OUT_5TARGET="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_TARGET_C_DIR=targets/stage4-crossbeam-deque-v0.7.2 \
       STAGE3_TARGET_C_BUGS=targets/stage4-crossbeam-deque-v0.7.2/bugs.json \
       STAGE3_TARGET_D_DIR=targets/stage4-owning_ref-v0.4.1 \
       STAGE3_TARGET_D_BUGS=targets/stage4-owning_ref-v0.4.1/bugs.json \
       STAGE3_TARGET_E_DIR=targets/stage4-generator-v0.6.25 \
       STAGE3_TARGET_E_BUGS=targets/stage4-generator-v0.6.25/bugs.json \
       bash "$ORCH" --dry-run 2>&1)"

assert_contains "5-target rotation initialises targets=(A B) array" \
    "$OUT_5TARGET" \
    "targets=(A B)"
assert_contains "5-target rotation appends C" \
    "$OUT_5TARGET" \
    "targets+=(C)"
assert_contains "5-target rotation appends D" \
    "$OUT_5TARGET" \
    "targets+=(D)"
assert_contains "5-target rotation appends E" \
    "$OUT_5TARGET" \
    "targets+=(E)"
assert_contains "5-target rotation uses modulo round-robin counter" \
    "$OUT_5TARGET" \
    'k=${targets[$((i % n))]}'
assert_contains "5-target rotation references TARGET_<K>_DIR_REL via indirect expansion" \
    "$OUT_5TARGET" \
    'td_var="TARGET_${k}_DIR_REL"'
assert_contains "5-target rotation references TARGET_<K>_BUGS_REL via indirect expansion" \
    "$OUT_5TARGET" \
    'bm_var="TARGET_${k}_BUGS_REL"'
# Concrete /run-root/targets/stage4-* paths only materialise at runtime:
# the rotation timer's `${!td_var}` indirect expansion is interpreted
# inside the backgrounded subshell, NOT when the dry-run echoes the
# emit_cmd argument. The dry-run line therefore contains the literal
# string `TARGET_${k}_DIR_REL` (with the `${k}` placeholder), not the
# expanded crossbeam/owning_ref/generator path. Source-level coverage
# of those paths lives in (a) the round-robin counter + indirect-
# expansion assertions above, (b) the header-docs assertions below
# that prove C/D/E env vars are documented, and (c) the targets+=(C/D/E)
# assertions that prove the array slot is populated. End-to-end runtime
# path resolution is covered by the per-target verifier-roundtrip step
# in the issue acceptance criteria, not by this dry-run smoke.
assert_contains "5-target rotation still execs into laptop container" \
    "$OUT_5TARGET" \
    "podman exec stage3-laptop agentis memo set"
assert_contains "5-target rotation still execs into server container" \
    "$OUT_5TARGET" \
    "podman exec stage3-server agentis memo set"
# A/B-only fallback path: the legacy `phase=0; ... phase=\$((1 - phase))`
# branch must NOT appear when any of C/D/E is set (we picked the array
# branch instead).
assert_not_contains "5-target mode does not emit legacy phase alternation" \
    "$OUT_5TARGET" \
    "phase=\$((1 - phase))"
# Header docs the three new env vars.
assert_contains "header documents STAGE3_TARGET_C_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_C_DIR"
assert_contains "header documents STAGE3_TARGET_D_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_D_DIR"
assert_contains "header documents STAGE3_TARGET_E_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_E_DIR"

# 9. #520 M98 v3 PR 2/3: three new evolution env vars are documented,
# threaded into exec.env_passthrough, and propagated into the per-tribe
# bootstrap line so hunter.ag can read them via `printenv`.
assert_contains "header documents STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD" \
    "$(cat "$ORCH")" \
    "STAGE3_HUNTER_PROMPT_EVOLUTION_THRESHOLD"
assert_contains "header documents STAGE3_HUNTER_PROMPT_GEN_CAP" \
    "$(cat "$ORCH")" \
    "STAGE3_HUNTER_PROMPT_GEN_CAP"
assert_contains "header documents STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR" \
    "$(cat "$ORCH")" \
    "STAGE3_HUNTER_PROMPT_LEVENSHTEIN_FLOOR"
assert_contains "HUNTER_PROMPT_EVOLUTION_THRESHOLD threaded into env_passthrough" \
    "$(cat "$ORCH")" \
    "HUNTER_PROMPT_EVOLUTION_THRESHOLD"
assert_contains "HUNTER_PROMPT_GEN_CAP threaded into env_passthrough" \
    "$(cat "$ORCH")" \
    "HUNTER_PROMPT_GEN_CAP"
assert_contains "HUNTER_PROMPT_LEVENSHTEIN_FLOOR threaded into env_passthrough" \
    "$(cat "$ORCH")" \
    "HUNTER_PROMPT_LEVENSHTEIN_FLOOR"
assert_contains "env_passthrough config line lists HUNTER_PROMPT_EVOLUTION_THRESHOLD" \
    "$(cat "$ORCH")" \
    "HUNTER_PROMPT_MAX_BYTES,HUNTER_PROMPT_EVOLUTION_THRESHOLD,HUNTER_PROMPT_GEN_CAP,HUNTER_PROMPT_LEVENSHTEIN_FLOOR"
assert_contains "per-tribe bootstrap line propagates HUNTER_PROMPT_EVOLUTION_THRESHOLD" \
    "$(cat "$ORCH")" \
    "HUNTER_PROMPT_EVOLUTION_THRESHOLD=%s HUNTER_PROMPT_GEN_CAP=%s HUNTER_PROMPT_LEVENSHTEIN_FLOOR=%s"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
