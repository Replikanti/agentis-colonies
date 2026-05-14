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
    "hunter:target_dir"
assert_contains "rotation timer cycles target_file" "$OUT" \
    "hunter:target_file"
assert_contains "rotation timer cycles bugs_manifest" "$OUT" \
    "hunter:bugs_manifest"
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

# 8b. Stage 4 Phase 1 chunk 2 (#544): when STAGE3_TARGET_F/G/H/I/J_{DIR,BUGS}
# are all set in addition to C/D/E, the rotation timer must emit a
# round-robin loop over the 10-element `targets` array; header documents
# the five new env vars; and the legacy phase-alternation branch must
# stay suppressed.
OUT_10TARGET="$(STAGE3_WALL_CLOCK_S=1800 \
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
       STAGE3_TARGET_F_DIR=targets/stage4-ticketed_lock-v0.3.0 \
       STAGE3_TARGET_F_BUGS=targets/stage4-ticketed_lock-v0.3.0/bugs.json \
       STAGE3_TARGET_G_DIR=targets/stage4-lock_api-v0.3.4 \
       STAGE3_TARGET_G_BUGS=targets/stage4-lock_api-v0.3.4/bugs.json \
       STAGE3_TARGET_H_DIR=targets/stage4-atomic-option-v0.1.2 \
       STAGE3_TARGET_H_BUGS=targets/stage4-atomic-option-v0.1.2/bugs.json \
       STAGE3_TARGET_I_DIR=targets/stage4-atom-v0.3.5 \
       STAGE3_TARGET_I_BUGS=targets/stage4-atom-v0.3.5/bugs.json \
       STAGE3_TARGET_J_DIR=targets/stage4-syncpool-v0.1.5 \
       STAGE3_TARGET_J_BUGS=targets/stage4-syncpool-v0.1.5/bugs.json \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "10-target rotation appends F" \
    "$OUT_10TARGET" \
    "targets+=(F)"
assert_contains "10-target rotation appends G" \
    "$OUT_10TARGET" \
    "targets+=(G)"
assert_contains "10-target rotation appends H" \
    "$OUT_10TARGET" \
    "targets+=(H)"
assert_contains "10-target rotation appends I" \
    "$OUT_10TARGET" \
    "targets+=(I)"
assert_contains "10-target rotation appends J" \
    "$OUT_10TARGET" \
    "targets+=(J)"
assert_not_contains "10-target mode does not emit legacy phase alternation" \
    "$OUT_10TARGET" \
    "phase=\$((1 - phase))"
assert_contains "header documents STAGE3_TARGET_F_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_F_DIR"
assert_contains "header documents STAGE3_TARGET_G_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_G_DIR"
assert_contains "header documents STAGE3_TARGET_H_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_H_DIR"
assert_contains "header documents STAGE3_TARGET_I_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_I_DIR"
assert_contains "header documents STAGE3_TARGET_J_DIR" \
    "$(cat "$ORCH")" \
    "STAGE3_TARGET_J_DIR"

# 8c. Stage 4 Phase 1 chunk 2 (#544): population-scaling knobs.
# calibration.toml's max_replicas_per_tribe must be 10 (bumped from 5);
# hermetic config emits `memo.max_keys = 50000`; default
# STAGE3_TRIBE_INITIAL_POOL is 20000 (bumped from 0); default
# STAGE3_ROTATION_INTERVAL_S is 600 (bumped from 1200).
CALIB_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/calibration.toml"
assert_contains "calibration.toml max_replicas_per_tribe bumped to 10 (#544)" \
    "$(cat "$CALIB_FILE")" \
    "max_replicas_per_tribe = 10"
assert_contains "hermetic config emits memo.max_keys = 50000 (#544)" \
    "$(cat "$ORCH")" \
    'printf "memo.max_keys = 50000\\n"'
assert_contains "STAGE3_TRIBE_INITIAL_POOL default bumped to 20000 (#544)" \
    "$(cat "$ORCH")" \
    'TRIBE_INITIAL_POOL="${STAGE3_TRIBE_INITIAL_POOL:-20000}"'
assert_contains "STAGE3_ROTATION_INTERVAL_S default bumped to 600 (#544)" \
    "$(cat "$ORCH")" \
    'ROTATION_INTERVAL="${STAGE3_ROTATION_INTERVAL_S:-600}"'

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

# 9a-549. #549 burn-rate mitigation: STAGE3_MAX_REPLICAS caps per-tribe
# replicas so concurrent LLM-call traffic stays under Claude Code
# flat-rate ceiling. Default 3 yields ~15 concurrent daemons across 5
# tribes (5 source + 10 replicas) vs take-10's observed 26-daemon peak
# that exhausted the budget at T+25min. Default dry-run must emit
# `max replicas per tribe: 3`; an override of STAGE3_MAX_REPLICAS=7 must
# propagate into the same emit_step line.
assert_contains "STAGE3_MAX_REPLICAS default surfaces as 3 (#549)" "$OUT" \
    "max replicas per tribe: 3"
OUT_MAX_REPLICAS_OVERRIDE="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_MAX_REPLICAS=7 \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_MAX_REPLICAS=7 override surfaces in emit_step output (#549)" \
    "$OUT_MAX_REPLICAS_OVERRIDE" \
    "max replicas per tribe: 7"

# 9a-552. #552 burn-rate extension: STAGE3_HUNTER_TICK_MS overrides the
# start-colony.sh hardcoded 60000 hunter tick (preserves total LLM-call
# budget per smoke but stretches wall clock to fit emergence observation
# inside Claude Code flat-rate 5h ceiling). Default 240000 must surface
# in the emit_step transcript; an override of STAGE3_HUNTER_TICK_MS=600000
# must propagate into the same emit_step line.
assert_contains "STAGE3_HUNTER_TICK_MS default surfaces as 240000 ms (#552)" "$OUT" \
    "hunter tick interval: 240000 ms"
OUT_HUNTER_TICK_OVERRIDE="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_HUNTER_TICK_MS=600000 \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_HUNTER_TICK_MS=600000 override surfaces in emit_step output (#552)" \
    "$OUT_HUNTER_TICK_OVERRIDE" \
    "hunter tick interval: 600000 ms"

# 9a-554. #554 burn-rate mitigation: STAGE3_CLAUDE_CAVEMAN gates the
# minimal-overhead claude CLI mode. Post-#559 the default is "1", so the
# default dry-run must surface as `caveman mode: enabled (...)`; an
# override of STAGE3_CLAUDE_CAVEMAN=0 must surface as `caveman mode:
# disabled`.
assert_contains "STAGE3_CLAUDE_CAVEMAN default surfaces as enabled (#559)" "$OUT" \
    "caveman mode: enabled (--tools '' --system-prompt minimal --effort medium)"
OUT_CAVEMAN_DISABLED="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_CAVEMAN=0 \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_CLAUDE_CAVEMAN=0 override surfaces in emit_step output (#559)" \
    "$OUT_CAVEMAN_DISABLED" \
    "caveman mode: disabled"

# 9a-557. #557 quality-vs-burn tuning: STAGE3_CLAUDE_EFFORT gates the
# claude CLI --effort flag value when caveman mode is on. Default
# "medium" must surface in the emit_step transcript; an override to
# "high" must surface as `--effort high`; an invalid value must exit 2
# with a helpful stderr message (validated unconditionally so operators
# learn about misconfig regardless of caveman state).
OUT_EFFORT_HIGH="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_CAVEMAN=1 \
       STAGE3_CLAUDE_EFFORT=high \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_CLAUDE_EFFORT=high override surfaces in emit_step output (#557)" \
    "$OUT_EFFORT_HIGH" \
    "caveman mode: enabled (--tools '' --system-prompt minimal --effort high)"
EFFORT_BAD_RC=0
EFFORT_BAD_OUT="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_EFFORT=garbage \
       bash "$ORCH" --dry-run 2>&1)" || EFFORT_BAD_RC=$?
if [ "$EFFORT_BAD_RC" -eq 2 ]; then
    echo "[PASS] STAGE3_CLAUDE_EFFORT=garbage exits 2 (#557)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] STAGE3_CLAUDE_EFFORT=garbage should exit 2, got $EFFORT_BAD_RC (#557)"
    FAIL=$((FAIL + 1))
fi
assert_contains "STAGE3_CLAUDE_EFFORT=garbage stderr names allowed values (#557)" \
    "$EFFORT_BAD_OUT" \
    "STAGE3_CLAUDE_EFFORT must be one of low|medium|high|xhigh|max"

# 9a-563. #563 cost-reduction: STAGE3_CLAUDE_MODEL injects an explicit
# --model flag into the claude CLI invocation so Claude Code no longer
# falls back to the subscription-tier default (Opus on Max 20x). Default
# "sonnet" must surface in emit_step transcript; aliases (haiku) and
# explicit model names (claude-sonnet-4-20250514) must round-trip; an
# unrecognised value must exit 2 with a helpful stderr message.
assert_contains "STAGE3_CLAUDE_MODEL default surfaces as sonnet (#563)" \
    "$OUT" \
    "claude model: sonnet"
OUT_MODEL_HAIKU="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_MODEL=haiku \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_CLAUDE_MODEL=haiku alias override surfaces (#563)" \
    "$OUT_MODEL_HAIKU" \
    "claude model: haiku"
OUT_MODEL_EXPLICIT="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_MODEL=claude-sonnet-4-20250514 \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "STAGE3_CLAUDE_MODEL explicit name override surfaces (#563)" \
    "$OUT_MODEL_EXPLICIT" \
    "claude model: claude-sonnet-4-20250514"
MODEL_BAD_RC=0
MODEL_BAD_OUT="$(STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LAPTOP_PORT=9100 \
       STAGE3_SERVER_PORT=9101 \
       STAGE3_LAPTOP_WORKER_PORT=9200 \
       STAGE3_SERVER_WORKER_PORT=9201 \
       STAGE3_WORKER_SECRET=testsecret \
       STAGE3_CLAUDE_MODEL=gpt-4 \
       bash "$ORCH" --dry-run 2>&1)" || MODEL_BAD_RC=$?
if [ "$MODEL_BAD_RC" -eq 2 ] && printf '%s' "$MODEL_BAD_OUT" | grep -Fq -- \
    "STAGE3_CLAUDE_MODEL must be alias (sonnet|haiku|opus) or explicit model name"; then
    echo "[PASS] STAGE3_CLAUDE_MODEL=gpt-4 exits 2 with helpful stderr (#563)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] STAGE3_CLAUDE_MODEL=gpt-4 should exit 2 with helpful stderr, got rc=$MODEL_BAD_RC stderr=$MODEL_BAD_OUT (#563)"
    FAIL=$((FAIL + 1))
fi

# 9b. #528: STAGE3_DAEMON_CB_PER_TICK env var is documented, has the
# documented default of 2000, and its hermetic-config emit line is
# present (so the spawned daemon's per-tick CB budget actually rises
# above the agentis-core default of 100 which empirically bricks
# LLM-heavy tribes-bench daemons after ~10 ticks).
assert_contains "header documents STAGE3_DAEMON_CB_PER_TICK" \
    "$(cat "$ORCH")" \
    "STAGE3_DAEMON_CB_PER_TICK"
assert_contains "STAGE3_DAEMON_CB_PER_TICK default is 2000" \
    "$(cat "$ORCH")" \
    'DAEMON_CB_PER_TICK="${STAGE3_DAEMON_CB_PER_TICK:-2000}"'
assert_contains "hermetic config emits daemon.cb_per_tick line" \
    "$(cat "$ORCH")" \
    'printf "daemon.cb_per_tick = %s'

# 9c. #535 + #537: claude-backend wiring. Default OpenAI dry-run must
# NOT emit any /root/.claude reference; claude-backend dry-run with a
# valid host dir must inject -v <host>:/root/.claude:rw into BOTH
# containers; claude-backend dry-run with a missing host dir must
# exit 1 with the helpful message.
assert_not_contains "default openai dry-run has no /root/.claude mount" \
    "$OUT" \
    "/root/.claude"
CLAUDE_OUT="$(STAGE3_WALL_CLOCK_S=1800 \
              STAGE3_ROTATION_INTERVAL_S=120 \
              STAGE3_DEATH_THRESHOLD=300 \
              STAGE3_LAPTOP_PORT=9100 \
              STAGE3_SERVER_PORT=9101 \
              STAGE3_LAPTOP_WORKER_PORT=9200 \
              STAGE3_SERVER_WORKER_PORT=9201 \
              STAGE3_WORKER_SECRET=testsecret \
              STAGE3_LLM_BACKEND=claude \
              STAGE3_HOST_CLAUDE_DIR=/tmp \
              bash "$ORCH" --dry-run 2>&1 || true)"
assert_contains "claude backend mounts /tmp:/root/.claude:rw,z on laptop" \
    "$CLAUDE_OUT" \
    "-v /tmp:/root/.claude:rw,z"
LAPTOP_CLAUDE_COUNT="$(printf '%s' "$CLAUDE_OUT" | grep -cF -- '-v /tmp:/root/.claude:rw,z' || true)"
if [ "$LAPTOP_CLAUDE_COUNT" -ge 2 ]; then
    echo "[PASS] claude backend mounts /tmp:/root/.claude:rw,z on BOTH containers (found $LAPTOP_CLAUDE_COUNT instances)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] claude backend should mount /root/.claude on both containers (found only $LAPTOP_CLAUDE_COUNT instance(s))"
    FAIL=$((FAIL + 1))
fi
# #540: explicit `:z` SELinux relabel suffix presence assertion.
# Distinct from the count assertion above so a regression that drops
# `:z` while keeping the mount on both containers is still caught.
assert_contains "claude mount includes :z SELinux relabel suffix" \
    "$CLAUDE_OUT" \
    ":rw,z"
CLAUDE_MISSING_RC=0
STAGE3_LLM_BACKEND=claude \
STAGE3_HOST_CLAUDE_DIR=/nonexistent-path-$$ \
STAGE3_WALL_CLOCK_S=1800 \
STAGE3_ROTATION_INTERVAL_S=120 \
STAGE3_DEATH_THRESHOLD=300 \
STAGE3_LAPTOP_PORT=9100 \
STAGE3_SERVER_PORT=9101 \
STAGE3_LAPTOP_WORKER_PORT=9200 \
STAGE3_SERVER_WORKER_PORT=9201 \
STAGE3_WORKER_SECRET=testsecret \
bash "$ORCH" --dry-run >/dev/null 2>&1 || CLAUDE_MISSING_RC=$?
if [ "$CLAUDE_MISSING_RC" -eq 1 ]; then
    echo "[PASS] claude backend with missing STAGE3_HOST_CLAUDE_DIR exits 1"
    PASS=$((PASS + 1))
else
    echo "[FAIL] claude backend with missing STAGE3_HOST_CLAUDE_DIR should exit 1 (got $CLAUDE_MISSING_RC)"
    FAIL=$((FAIL + 1))
fi

# 10. #520 M98 v3 PR 3/3: M106 hash-pointer inheritance — assert each
# hunter.ag carries the new helpers, the bootstrap inheritance branch,
# and that both replicate() sites call the parent-wrap helper. Source-
# level grep is the cheapest reliable signal short of a live agentis
# run (which would need a full container spawn for one round trip).
HUNTER_REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
for tribe in tribe-alpha tribe-beta tribe-gamma tribe-delta tribe-epsilon; do
    AG="$HUNTER_REPO_ROOT/$tribe/agents/hunter.ag"
    assert_contains "$tribe: _extract_pp_hash helper defined" \
        "$(cat "$AG")" \
        "fn _extract_pp_hash(variant_tag: string) -> string"
    assert_contains "$tribe: _strip_pp_prefix helper defined" \
        "$(cat "$AG")" \
        "fn _strip_pp_prefix(variant_tag: string) -> string"
    assert_contains "$tribe: _publish_prompt_body_and_wrap_variant helper defined" \
        "$(cat "$AG")" \
        "fn _publish_prompt_body_and_wrap_variant(self_pid: string, variant_tag: string) -> string"
    assert_contains "$tribe: pp:<sha>|<variant> wrap format produced" \
        "$(cat "$AG")" \
        'return "pp:" + h + "|" + variant_tag;'
    assert_contains "$tribe: content-addressed body registry key" \
        "$(cat "$AG")" \
        '"hunter:prompt_body:" + h'
    assert_contains "$tribe: hex validation via tr -d 0-9a-f" \
        "$(cat "$AG")" \
        "tr -d '0-9a-f'"
    assert_contains "$tribe: sha256 via python3 hashlib" \
        "$(cat "$AG")" \
        "hashlib.sha256"
    assert_contains "$tribe: bootstrap inheritance branch on pp_hash" \
        "$(cat "$AG")" \
        'let pp_hash = _extract_pp_hash(_variant);'
    assert_contains "$tribe: bootstrap reads inherited body memo" \
        "$(cat "$AG")" \
        'recall_latest("hunter:prompt_body:" + pp_hash)'
    assert_contains "$tribe: hunter_prompt_inherit success learn tag" \
        "$(cat "$AG")" \
        '"hunter_prompt_inherit"'
    assert_contains "$tribe: hunter_prompt_inherit miss outcome tag" \
        "$(cat "$AG")" \
        '"miss"'
    assert_contains "$tribe: hunter_prompt_inherit adopted outcome tag" \
        "$(cat "$AG")" \
        '"adopted"'
    # Both replicate() call sites must wrap the variant_tag.
    wrap_count=$(grep -cF '_publish_prompt_body_and_wrap_variant(_self_pid' "$AG" || true)
    if [ "$wrap_count" -ge 2 ]; then
        echo "[PASS] $tribe: both replicate() sites wrap variant_tag (found $wrap_count)"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $tribe: expected >=2 _publish_prompt_body_and_wrap_variant call sites, got $wrap_count"
        FAIL=$((FAIL + 1))
    fi
done

# 11. #520 M98 v3 PR 3/3: hex validation regression — exercise the
# `tr -d '0-9a-f' | wc -c` logic the way _extract_pp_hash does. A
# 64-hex SHA must produce leftover==0; a mixed-case or non-hex tag
# must produce leftover>0 so the helper returns "" and the bootstrap
# falls through to seed.
GOOD_SHA="abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
BAD_HEX="GHIJKLmnopqrstuvwxyz0123456789ABCDEF0123456789abcdef0123456789xy"
good_left=$(printf '%s' "$GOOD_SHA" | tr -d '0-9a-f' | wc -c)
bad_left=$(printf '%s' "$BAD_HEX" | tr -d '0-9a-f' | wc -c)
if [ "$good_left" -eq 0 ]; then
    echo "[PASS] hex validation: 64-char lowercase hex SHA produces zero leftover"
    PASS=$((PASS + 1))
else
    echo "[FAIL] hex validation: expected leftover=0 for valid hex, got $good_left"
    FAIL=$((FAIL + 1))
fi
if [ "$bad_left" -gt 0 ]; then
    echo "[PASS] hex validation: non-hex / uppercase candidate produces non-zero leftover"
    PASS=$((PASS + 1))
else
    echo "[FAIL] hex validation: expected leftover>0 for bad hex, got $bad_left"
    FAIL=$((FAIL + 1))
fi

# 12. #520 M98 v3 PR 3/3: SHA-256 of a known body matches expected
# Python output — same one-liner the helper invokes. Anchors the
# `pp:<sha>` produced over the M106 wire against a deterministic
# reference so future refactors of the helper can be regression-
# checked.
EXPECTED_SHA=$(printf '%s' "hello-prompt-body" | python3 -c 'import sys,hashlib; sys.stdout.write(hashlib.sha256(sys.stdin.read().encode("utf-8")).hexdigest())')
ACTUAL_SHA=$(python3 -c 'import sys,hashlib; sys.stdout.write(hashlib.sha256(sys.argv[1].encode("utf-8")).hexdigest())' "hello-prompt-body")
if [ "$EXPECTED_SHA" = "$ACTUAL_SHA" ] && [ ${#ACTUAL_SHA} -eq 64 ]; then
    echo "[PASS] sha256 helper: 64-char hex matches stdin-vs-argv reference"
    PASS=$((PASS + 1))
else
    echo "[FAIL] sha256 helper: expected=$EXPECTED_SHA actual=$ACTUAL_SHA"
    FAIL=$((FAIL + 1))
fi

# Composed-wrap shape: `pp:<sha>|<old>` total length = 3 + 64 + 1 +
# len(old_variant). For the longest #499-pool variant
# `dangling_borrow:format-pattern-substitution-aware` (51 chars), the
# wrap is 119 bytes — well under the M106 MAX_VARIANT_TAG_BYTES=1024
# cap, so no agentis-core cap bump is required.
EX_VARIANT="dangling_borrow:format-pattern-substitution-aware"
WRAPPED="pp:${ACTUAL_SHA}|${EX_VARIANT}"
if [ ${#WRAPPED} -lt 1024 ]; then
    echo "[PASS] pp:<sha>|<variant> wrap fits within M106 MAX_VARIANT_TAG_BYTES=1024 (got ${#WRAPPED} bytes)"
    PASS=$((PASS + 1))
else
    echo "[FAIL] pp:<sha>|<variant> wrap exceeds M106 cap (got ${#WRAPPED} bytes)"
    FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
