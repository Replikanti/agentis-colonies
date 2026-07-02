#!/bin/bash
# tools/test-daemon-restart.sh: unit test for tools/lib/daemon-restart.sh
# (#1357) — the shared single-agent restart machine extracted from the five
# identical --restart-agent kill/poll/verify blocks (#285) in
# dev-apprenticeship/*/scripts/start-colony.sh.
#
# Runs entirely against a stubbed `agentis` binary on PATH whose
# `daemon list --json` output is a fixture file, so no agentis runtime is
# needed. Fake daemons are spawned DETACHED (double-fork, reparented to init)
# so they are reaped promptly on death — a direct child of this test shell
# would linger as a zombie and defeat the helper's `kill -0` exit poll. That
# mirrors production, where the daemons are never children of the
# start-colony.sh invocation that restarts them.
#
# Covered:
#   1. live PID that exits on SIGTERM: killed via the TERM path (a witness
#      file written by the TERM handler proves no SIGKILL was needed),
#      sidecar files removed
#   2. TERM-resistant PID: survives the 5s exit poll, killed via the SIGKILL
#      escalation, sidecar files removed
#   3. no matching registry entry: no-op — a live daemon registered under a
#      different colony/agent is left alive and its sidecars untouched
#   4. malformed registry JSON: degrades gracefully — helper returns 0,
#      nothing is killed
#   5. wiring: every colony's start-colony.sh sources the shared lib and
#      calls daemon_restart_kill_existing with its own colony name
#
# Usage: ./tools/test-daemon-restart.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
# Per-run-unique marker in every fake daemon's argv (same rationale as
# test-start-colony-restart.sh / #1008): pgrep/pkill below must only ever
# match THIS run's fakes, never a sibling run's or a real daemon's.
RUN_MARKER="fake-daemon-restart-1357-$$-$(basename "$TMPDIR_TEST")"
cleanup() {
    pkill -f "$RUN_MARKER" 2>/dev/null || true
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# --- Fixture federation root (holds the .agentis/daemon sidecar dir) ---
FED_ROOT="$TMPDIR_TEST/fed"
mkdir -p "$FED_ROOT/.agentis/daemon"

# --- Stub agentis on PATH: `daemon list --json` cats the fixture registry ---
SHIM_DIR="$TMPDIR_TEST/shim"
mkdir -p "$SHIM_DIR"
cat > "$SHIM_DIR/agentis" <<'SHIM'
#!/bin/bash
if [ "${1:-}" = "daemon" ] && [ "${2:-}" = "list" ]; then
    cat "${FAKE_REGISTRY:?FAKE_REGISTRY not set}"
    exit 0
fi
exit 0
SHIM
chmod +x "$SHIM_DIR/agentis"
PATH="$SHIM_DIR:$PATH"
export PATH
FAKE_REGISTRY="$TMPDIR_TEST/registry.json"
export FAKE_REGISTRY

# Pre-flight isolation check (same spirit as test-start-colony-restart.sh's
# #285 QA guard): the helper must resolve the stub, never a real binary —
# a real `agentis daemon list` could surface a live federation's PIDs and
# the kill machine would then TERM a real daemon. Bail hard if the shim
# does not win the PATH lookup.
resolved="$(command -v agentis 2>/dev/null || true)"
if [ "$resolved" != "$SHIM_DIR/agentis" ]; then
    echo "[FAIL] shim isolation: agentis resolves to '$resolved', refusing to run the kill machine" >&2
    exit 1
fi

# --- The library under test ---
# shellcheck source=lib/daemon-restart.sh
# shellcheck disable=SC1091  # colony-lint runs shellcheck without -x
. "$SCRIPT_DIR/lib/daemon-restart.sh"

# --- Fake daemon binaries (names carry RUN_MARKER for pgrep/pkill scoping) ---
# Exits on SIGTERM: reaps its own sleep child (#1022 orphan concern) and
# writes a witness file so the test can prove the TERM handler — not the
# SIGKILL escalation — ended it.
FAKE_TERM="$SHIM_DIR/${RUN_MARKER}-term"
cat > "$FAKE_TERM" <<'FAKE'
#!/bin/bash
sleep 60 &
_sleep_pid=$!
trap 'kill "$_sleep_pid" 2>/dev/null; echo term > "${TERM_WITNESS:?}"; exit 0' TERM
wait "$_sleep_pid"
FAKE
chmod +x "$FAKE_TERM"

# Ignores SIGTERM outright, so only the SIGKILL escalation can end it. The
# foreground `sleep 1` loop (not `sleep 60`) keeps the orphaned child's
# lifetime after the KILL to at most a second.
FAKE_STUBBORN="$SHIM_DIR/${RUN_MARKER}-stubborn"
cat > "$FAKE_STUBBORN" <<'FAKE'
#!/bin/bash
trap '' TERM
while :; do sleep 1; done
FAKE
chmod +x "$FAKE_STUBBORN"

# Bystander for the no-op tests: must survive the helper untouched.
FAKE_BYSTANDER="$SHIM_DIR/${RUN_MARKER}-bystander"
cp "$FAKE_STUBBORN" "$FAKE_BYSTANDER"
chmod +x "$FAKE_BYSTANDER"

# spawn_detached <fake-binary>: double-fork so the fake is reparented to
# init (prompt reaping on death), then echo its PID discovered via pgrep
# on the per-run-unique binary path.
spawn_detached() {
    local bin="$1" pid="" i=0
    ( "$bin" </dev/null >/dev/null 2>&1 & )
    while [ "$i" -lt 50 ]; do
        pid="$(pgrep -f "$bin" 2>/dev/null | head -n1 || true)"
        [ -n "$pid" ] && break
        sleep 0.1
        i=$((i + 1))
    done
    echo "$pid"
}

# wait_dead <pid>: short grace poll for the detached fake to be reaped.
# Returns 0 once `kill -0` fails, 1 if it is still alive after ~2s.
wait_dead() {
    local pid="$1" i=0
    while [ "$i" -lt 20 ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.1
        i=$((i + 1))
    done
    return 1
}

SIDECAR_EXTS="pid watchdog.pid colony heartbeat status stop"

make_sidecars() {
    local aid="$1" ext
    for ext in $SIDECAR_EXTS; do
        echo x > "$FED_ROOT/.agentis/daemon/${aid}.${ext}"
    done
}

# sidecars_gone <agent_id>: 0 when every sidecar file has been removed.
sidecars_gone() {
    local aid="$1" ext
    for ext in $SIDECAR_EXTS; do
        [ -e "$FED_ROOT/.agentis/daemon/${aid}.${ext}" ] && return 1
    done
    return 0
}

# sidecars_intact <agent_id>: 0 when every sidecar file is still present.
sidecars_intact() {
    local aid="$1" ext
    for ext in $SIDECAR_EXTS; do
        [ -e "$FED_ROOT/.agentis/daemon/${aid}.${ext}" ] || return 1
    done
    return 0
}

# write_registry <pid> <agent_id> <colony> <agent>: one-entry fixture in the
# shape `agentis daemon list --json` emits (pid, agent_id, colony, source).
write_registry() {
    python3 - "$1" "$2" "$3" "$4" > "$FAKE_REGISTRY" <<'PY'
import json, sys
pid, aid, colony, agent = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps([{
    "pid": pid,
    "agent_id": aid,
    "colony": colony,
    "source": "/fake/" + colony + "/agents/" + agent + ".ag",
}]))
PY
}

# --- Test 1: TERM-compliant daemon dies on the SIGTERM path, sidecars go ---
TERM_WITNESS="$TMPDIR_TEST/term-witness"
export TERM_WITNESS
pid="$(spawn_detached "$FAKE_TERM")"
if [ -z "$pid" ]; then
    fail "test1: TERM-compliant fake daemon failed to spawn"
else
    write_registry "$pid" "aid-term" implementation code_writer
    make_sidecars "aid-term"
    daemon_restart_kill_existing "$FED_ROOT" implementation code_writer
    if ! wait_dead "$pid"; then
        fail "test1: daemon pid=$pid still alive after daemon_restart_kill_existing"
    elif [ ! -f "$TERM_WITNESS" ] || ! grep -q '^term$' "$TERM_WITNESS"; then
        fail "test1: daemon died but not via its TERM handler (witness missing)"
    elif ! sidecars_gone "aid-term"; then
        fail "test1: sidecar files for aid-term not removed"
    else
        pass "test1: live PID exits on SIGTERM and sidecar files are removed"
    fi
fi

# --- Test 2: TERM-resistant daemon is ended by the SIGKILL escalation ---
pid="$(spawn_detached "$FAKE_STUBBORN")"
if [ -z "$pid" ]; then
    fail "test2: TERM-resistant fake daemon failed to spawn"
else
    write_registry "$pid" "aid-kill" implementation code_writer
    make_sidecars "aid-kill"
    # trap '' TERM in the fake guarantees only SIGKILL can end it; the helper
    # spends the full 5s poll first, so this test legitimately takes ~6s.
    daemon_restart_kill_existing "$FED_ROOT" implementation code_writer
    if ! wait_dead "$pid"; then
        fail "test2: TERM-resistant daemon pid=$pid survived the SIGKILL escalation"
    elif ! sidecars_gone "aid-kill"; then
        fail "test2: sidecar files for aid-kill not removed"
    else
        pass "test2: TERM-resistant PID is ended via the SIGKILL escalation path"
    fi
fi

# --- Test 3: no matching registry entry is a no-op ---
bystander="$(spawn_detached "$FAKE_BYSTANDER")"
if [ -z "$bystander" ]; then
    fail "test3: bystander fake daemon failed to spawn"
else
    # The registry knows the bystander — but under a different colony/agent
    # than the one being restarted, so the match must come up empty and the
    # helper must touch neither the process nor the sidecars.
    write_registry "$bystander" "aid-other" release ship_decider
    make_sidecars "aid-other"
    daemon_restart_kill_existing "$FED_ROOT" implementation code_writer
    sleep 0.3
    if ! kill -0 "$bystander" 2>/dev/null; then
        fail "test3: non-matching daemon pid=$bystander was killed"
    elif ! sidecars_intact "aid-other"; then
        fail "test3: sidecar files of a non-matching agent_id were removed"
    else
        pass "test3: no matching registry entry => no-op (bystander + sidecars untouched)"
    fi
fi

# --- Test 4: malformed registry JSON degrades gracefully ---
# Bystander (still alive from test 3, still registered only as aid-other)
# doubles as the kill-nothing sentinel here.
printf 'this is {{{ not json[\n' > "$FAKE_REGISTRY"
rc=0
daemon_restart_kill_existing "$FED_ROOT" implementation code_writer || rc=$?
if [ "$rc" != "0" ]; then
    fail "test4: malformed registry JSON => non-zero rc=$rc (must stay best-effort)"
elif [ -n "$bystander" ] && ! kill -0 "$bystander" 2>/dev/null; then
    fail "test4: malformed registry JSON killed an unrelated daemon"
else
    pass "test4: malformed registry JSON degrades gracefully (rc=0, nothing killed)"
fi

# --- Test 5: every colony start-colony.sh is wired to the shared helper ---
for colony in triage planning implementation code-review release; do
    script="$REPO_ROOT/dev-apprenticeship/$colony/scripts/start-colony.sh"
    if [ ! -f "$script" ]; then
        fail "test5: $colony: start-colony.sh missing"
        continue
    fi
    # shellcheck disable=SC2016  # literal source lines; $ must not expand.
    if grep -qF '. "$REPO_ROOT/tools/lib/daemon-restart.sh"' "$script" \
        && grep -qF "daemon_restart_kill_existing \"\$FED_ROOT\" $colony \"\$RESTART_AGENT\"" "$script"; then
        pass "test5: $colony: sources lib and calls daemon_restart_kill_existing $colony"
    else
        fail "test5: $colony: not wired to tools/lib/daemon-restart.sh (#1357)"
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
