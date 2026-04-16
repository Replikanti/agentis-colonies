#!/bin/bash
# tools/test-kill-federation.sh: unit tests for tools/kill-federation.sh.
#
# Self-contained — only bash, python3, and standard Unix tools. Spawns
# a synthetic long-running process labelled with a per-test argv0 so the
# kill machinery can be exercised without ever touching a real agentis
# daemon. Cleans up on every exit path via trap.
#
# Usage: ./tools/test-kill-federation.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KILL_SH="$SCRIPT_DIR/kill-federation.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
SPAWNED_PIDS=()

cleanup() {
    # Best-effort: kill any dummy process the tests left behind.
    for p in "${SPAWNED_PIDS[@]:-}"; do
        [ -z "$p" ] && continue
        kill -KILL "$p" 2>/dev/null || true
    done
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

assert_exit_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        pass "$name"
    else
        fail "$name" "expected exit=$expected, got exit=$actual"
    fi
}

# --- Test 1: --help exits 0, prints Usage ---
set +e
out="$("$KILL_SH" --help 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "Usage"; then
    pass "1: --help exits 0 with Usage"
else
    fail "1: --help" "rc=$rc, out missing 'Usage'"
fi

# --- Test 2: --unknown-flag exits 2 with stderr message ---
set +e
err="$("$KILL_SH" --unknown-flag 2>&1 >/dev/null)"
rc=$?
set -e
if [ "$rc" -eq 2 ] && [ -n "$err" ]; then
    pass "2: bad flag exits 2 with stderr"
else
    fail "2: bad flag" "rc=$rc err=$err"
fi

# --- Test 3: empty fixture, no live processes, exit 0 ---
FIX1="$TMPDIR_TEST/fix1"
mkdir -p "$FIX1/.agentis/daemon"
# Use a unique pattern that matches nothing in the test runner's process
# table to guarantee a clean run.
NOPATTERN="kill-fed-test-no-such-pattern-$$-empty"
set +e
out="$("$KILL_SH" --fed-dir "$FIX1" --no-backup \
    --match-pattern "$NOPATTERN" \
    --dashboard-pattern "$NOPATTERN" \
    --dashboard-py-pattern "$NOPATTERN" 2>&1)"
rc=$?
set -e
if [ "$rc" -eq 0 ] && echo "$out" | grep -q "no live processes"; then
    pass "3: empty fixture exits 0 with 'no live processes'"
else
    fail "3: empty fixture" "rc=$rc out=$out"
fi

# --- Test 4: dry-run with fixture files preserves them, exit 0 ---
FIX2="$TMPDIR_TEST/fix2"
mkdir -p "$FIX2/.agentis/daemon"
touch "$FIX2/.agentis/daemon/foo.pid" \
      "$FIX2/.agentis/daemon/bar.heartbeat" \
      "$FIX2/.agentis/daemon/baz.colony" \
      "$FIX2/.agentis/daemon/qux.watchdog.pid"
NOPATTERN2="kill-fed-test-no-such-pattern-$$-dryrun"
set +e
"$KILL_SH" --dry-run --fed-dir "$FIX2" \
    --match-pattern "$NOPATTERN2" \
    --dashboard-pattern "$NOPATTERN2" \
    --dashboard-py-pattern "$NOPATTERN2" >/dev/null 2>&1
rc=$?
set -e
files_after=$(find "$FIX2/.agentis/daemon" -type f | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$files_after" -eq 4 ]; then
    pass "4: --dry-run leaves fixture files intact"
else
    fail "4: --dry-run" "rc=$rc files_after=$files_after (expected 4)"
fi

# --- Test 5: real kill against fixture process; registry cleaned; exit 0 ---
FIX3="$TMPDIR_TEST/fix3"
mkdir -p "$FIX3/.agentis/daemon"
touch "$FIX3/.agentis/daemon/agent1.pid" \
      "$FIX3/.agentis/daemon/agent1.heartbeat" \
      "$FIX3/.agentis/daemon/agent1.colony"

# Spawn a dummy long-running process with a unique argv0. We use
# `exec -a` so pgrep -f sees the renamed argv. Sleep 600s (10 min) is
# more than enough — the test will signal it within seconds.
FIXTURE_TAG="agentis-daemon-test-fixture-$$"
bash -c "exec -a '$FIXTURE_TAG' sleep 600" &
DUMMY_PID=$!
SPAWNED_PIDS+=("$DUMMY_PID")

# Give the kernel a beat to settle the renamed argv into /proc/PID/cmdline.
sleep 1

if ! kill -0 "$DUMMY_PID" 2>/dev/null; then
    fail "5: spawn dummy" "PID $DUMMY_PID not alive after spawn"
else
    set +e
    "$KILL_SH" --fed-dir "$FIX3" --no-backup \
        --match-pattern "$FIXTURE_TAG" \
        --dashboard-pattern "kill-fed-test-no-such-dash-$$" \
        --dashboard-py-pattern "kill-fed-test-no-such-dashpy-$$" >/dev/null 2>&1
    rc=$?
    set -e
    sleep 1
    if kill -0 "$DUMMY_PID" 2>/dev/null; then
        fail "5: real kill" "dummy PID $DUMMY_PID still alive after kill (rc=$rc)"
        kill -KILL "$DUMMY_PID" 2>/dev/null || true
    else
        registry_left=$(find "$FIX3/.agentis/daemon" -maxdepth 1 -type f | wc -l | tr -d ' ')
        if [ "$rc" -eq 0 ] && [ "$registry_left" -eq 0 ]; then
            pass "5: real kill terminates fixture process and clears registry"
        else
            fail "5: real kill" "rc=$rc registry_left=$registry_left"
        fi
    fi
fi

# --- Test 6: --json emits valid JSON on stdout (dry-run path) ---
FIX4="$TMPDIR_TEST/fix4"
mkdir -p "$FIX4/.agentis/daemon"
touch "$FIX4/.agentis/daemon/x.pid"
NOPATTERN3="kill-fed-test-no-such-pattern-$$-json"
set +e
stdout="$("$KILL_SH" --json --dry-run --fed-dir "$FIX4" \
    --match-pattern "$NOPATTERN3" \
    --dashboard-pattern "$NOPATTERN3" \
    --dashboard-py-pattern "$NOPATTERN3" 2>/dev/null)"
rc=$?
set -e
last_line="$(printf '%s' "$stdout" | tail -n 1)"
if [ "$rc" -eq 0 ] && printf '%s' "$last_line" | python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
assert 'exit' in data, 'missing exit key'
assert 'dry_run' in data, 'missing dry_run key'
assert data['dry_run'] is True, 'dry_run not True'
" 2>/dev/null; then
    pass "6: --json --dry-run emits valid JSON trailing line"
else
    fail "6: --json" "rc=$rc last_line=$last_line"
fi

# --- Test 7: --fed-dir on non-existent path exits 2 ---
set +e
"$KILL_SH" --fed-dir "$TMPDIR_TEST/does-not-exist" --dry-run >/dev/null 2>&1
rc=$?
set -e
assert_exit_eq "7: missing --fed-dir exits 2" "2" "$rc"

# --- Test 8: backup is created in $AGENTIS_DIR/backups when not --no-backup ---
FIX5="$TMPDIR_TEST/fix5"
mkdir -p "$FIX5/.agentis/daemon"
touch "$FIX5/.agentis/daemon/agent.pid"
NOPATTERN4="kill-fed-test-no-such-pattern-$$-backup"
set +e
"$KILL_SH" --fed-dir "$FIX5" \
    --match-pattern "$NOPATTERN4" \
    --dashboard-pattern "$NOPATTERN4" \
    --dashboard-py-pattern "$NOPATTERN4" >/dev/null 2>&1
rc=$?
set -e
backups_count=$(find "$FIX5/.agentis/backups" -name 'agentis-daemon-registry-backup-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
# Parent dir must NOT be polluted with backup tarballs.
parent_pollution=$(find "$FIX5/.." -maxdepth 1 -name 'agentis-daemon-registry-backup-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
if [ "$rc" -eq 0 ] && [ "$backups_count" -eq 1 ] && [ "$parent_pollution" -eq 0 ]; then
    pass "8: backup written to .agentis/backups/, parent dir untouched"
else
    fail "8: backup location" "rc=$rc in_backups=$backups_count parent=$parent_pollution"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
