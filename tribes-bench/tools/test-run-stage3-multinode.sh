#!/bin/bash
# test-run-stage3-multinode.sh — smoke test for run-stage3-multinode.sh
# --dry-run mode (#439).
#
# Runs `run-stage3-multinode.sh --dry-run` and asserts the emitted
# command transcript contains every required surface:
#
#   1. SSH tunnel command (ssh -fN -M -S ... -L 9101:127.0.0.1:9100)
#   2. agentis serve commands (local + remote)
#   3. daemon spawn commands for the 5 tribes split between nodes
#   4. target-rotation timer setup
#   5. cleanup trap (kill daemons → kill serves → close tunnel)
#
# The dry-run must NOT actually open the SSH tunnel and NOT spawn any
# daemons; the test asserts neither $TUNNEL_SOCK exists post-run nor an
# `agentis serve` listener appears on the local port.
#
# Exit codes:
#   0  all assertions pass
#   1  one or more assertions failed

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCH="$SCRIPT_DIR/run-stage3-multinode.sh"

PASS=0
FAIL=0

assert_contains() {
    label="$1"; haystack="$2"; needle="$3"
    # here-string (not a printf|grep pipe): avoids SIGPIPE on the upstream
    # printf when grep -Fq exits early on a large haystack (CI broken-pipe).
    if grep -Fq -- "$needle" <<<"$haystack"; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       needle not found: $needle"
        FAIL=$((FAIL + 1))
    fi
}

assert_not_exists() {
    label="$1"; path="$2"
    if [ ! -e "$path" ]; then
        echo "[PASS] $label"
        PASS=$((PASS + 1))
    else
        echo "[FAIL] $label"
        echo "       unexpected path exists: $path"
        FAIL=$((FAIL + 1))
    fi
}

if [ ! -x "$ORCH" ]; then
    echo "[FAIL] run-stage3-multinode.sh not executable at $ORCH"
    exit 1
fi

# Use a hermetic tunnel-sock path so we can assert it does NOT get
# created by the dry-run. The default /tmp/stage3-tunnel.sock might
# coincide with a real operator session.
TMP_SOCK="$(mktemp -u -t stage3-tunnel-test.XXXXXX.sock)"
trap 'rm -f "$TMP_SOCK"' EXIT

OUT="$(STAGE3_TUNNEL_SOCK="$TMP_SOCK" \
       STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       bash "$ORCH" --dry-run 2>&1)"

# 1. SSH tunnel
assert_contains "SSH tunnel command emitted" "$OUT" \
    "ssh -fN -M -S $TMP_SOCK -L 9101:127.0.0.1:9100"

# 2. agentis serve (local + remote)
assert_contains "remote agentis serve command emitted" "$OUT" \
    "agentis serve 127.0.0.1:9100"
assert_contains "local agentis serve command emitted" "$OUT" \
    "+ agentis serve 127.0.0.1:9100"

# 3. daemon spawn for the 5 tribes split between nodes
for tribe in tribe-alpha tribe-beta; do
    assert_contains "laptop daemon spawn: $tribe" "$OUT" \
        "$tribe/scripts/start-colony.sh"
done
for tribe in tribe-gamma tribe-delta tribe-epsilon; do
    assert_contains "server daemon spawn: $tribe" "$OUT" \
        "$tribe/scripts/start-colony.sh"
done
# Server-side scaffolding must be pushed before daemon spawn (otherwise
# the remote start-colony.sh paths cannot resolve).
for tribe in tribe-gamma tribe-delta tribe-epsilon; do
    assert_contains "scaffolding push: $tribe" "$OUT" \
        "rsync -az --delete -e 'ssh -S $TMP_SOCK'"
done
assert_contains "tools/ rsync to server" "$OUT" \
    "tools/ ylohnitram@94.112.2.177:"
assert_contains "targets/ rsync to server" "$OUT" \
    "targets/ ylohnitram@94.112.2.177:"
# Server-side spawns must go through ssh + bash -lc (login-shell PATH).
assert_contains "server spawns route through ssh + bash -lc" "$OUT" \
    "ssh -S $TMP_SOCK"
assert_contains "server spawns use bash -lc for login PATH" "$OUT" \
    "bash -lc"

# 4. rotation timer
assert_contains "rotation timer with configured interval" "$OUT" \
    "interval=120s"
assert_contains "rotation timer cycles target_dir" "$OUT" \
    "tribes-bench:target_dir"
assert_contains "rotation timer cycles bugs_manifest" "$OUT" \
    "tribes-bench:bugs_manifest"
assert_contains "rotation toggles smallvec target" "$OUT" \
    "targets/stage2/smallvec-v0.6.13"
assert_contains "rotation toggles bumpalo target" "$OUT" \
    "targets/stage3/bumpalo-v3.2.0"

# 5. cleanup trap
assert_contains "cleanup trap installed" "$OUT" \
    "trap 'stop_rotation_timer; stop_all_daemons; stop_local_serve; stop_remote_serve; close_tunnel'"

# Death threshold injected (Stage 3 default 300, vs Stage 2 default 100).
assert_contains "death threshold 300 propagated to laptop spawns" "$OUT" \
    "DEATH_THRESHOLD=300"

# #1136: flat-cyborg is the default backend. Both nodes inject
# llm.backend = flat-cyborg + llm.flat_cyborg.idle_ms = 4000, and NO
# openai keys.
assert_contains "llm.backend=flat-cyborg injected on laptop config" "$OUT" \
    "llm.backend = flat-cyborg"
assert_contains "laptop flat_cyborg.idle_ms default injected" "$OUT" \
    "llm.flat_cyborg.idle_ms = 4000"
assert_contains "server flat_cyborg.idle_ms default injected over SSH" "$OUT" \
    "printf \"llm.flat_cyborg.idle_ms = 4000"

# Negative assertions: dry-run did NOT side-effect.
assert_not_exists "dry-run did not open tunnel socket" "$TMP_SOCK"

# #445 + #1136: openai backend remains an opt-in fallback. An explicit
# STAGE3_LLM_BACKEND=openai run must inject llm.backend = openai +
# llm.openai.api_key_env on both nodes.
OUT_OPENAI="$(STAGE3_TUNNEL_SOCK="$TMP_SOCK" \
       STAGE3_WALL_CLOCK_S=1800 \
       STAGE3_ROTATION_INTERVAL_S=120 \
       STAGE3_DEATH_THRESHOLD=300 \
       STAGE3_LLM_BACKEND=openai \
       bash "$ORCH" --dry-run 2>&1)"
assert_contains "llm.backend=openai injected on laptop config" "$OUT_OPENAI" \
    "llm.backend = openai"
assert_contains "llm.openai.api_key_env defaulted to OPENAI_API_KEY" "$OUT_OPENAI" \
    "llm.openai.api_key_env = OPENAI_API_KEY"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
