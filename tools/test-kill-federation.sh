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
    # Run with --json so we exercise the real-execution JSON code path
    # (the dry-run JSON path is already covered by Test 6). Capture
    # stdout — the trailing line should be the JSON document.
    set +e
    json_stdout="$("$KILL_SH" --json --fed-dir "$FIX3" --no-backup \
        --match-pattern "$FIXTURE_TAG" \
        --dashboard-pattern "kill-fed-test-no-such-dash-$$" \
        --dashboard-py-pattern "kill-fed-test-no-such-dashpy-$$" 2>/dev/null)"
    rc=$?
    set -e
    sleep 1
    if kill -0 "$DUMMY_PID" 2>/dev/null; then
        fail "5: real kill" "dummy PID $DUMMY_PID still alive after kill (rc=$rc)"
        kill -KILL "$DUMMY_PID" 2>/dev/null || true
    else
        registry_left=$(find "$FIX3/.agentis/daemon" -maxdepth 1 -type f | wc -l | tr -d ' ')
        # Validate the trailing JSON line shape: real-execution path
        # must include port_8420 and registry_remaining keys, dry_run
        # must be false, and exit must be 0.
        json_ok=0
        if printf '%s' "$json_stdout" | python3 -c "
import sys, json
lines = sys.stdin.read().splitlines()
assert lines, 'no stdout from --json'
data = json.loads(lines[-1])
assert data['exit'] == 0, 'exit != 0'
assert data['dry_run'] is False, 'dry_run not False on real-kill path'
assert 'port_8420' in data, 'missing port_8420 key'
assert 'registry_remaining' in data, 'missing registry_remaining key'
" 2>/dev/null; then
            json_ok=1
        fi
        if [ "$rc" -eq 0 ] && [ "$registry_left" -eq 0 ] && [ "$json_ok" -eq 1 ]; then
            pass "5: real kill terminates fixture, clears registry, emits valid real-path --json"
        else
            fail "5: real kill" "rc=$rc registry_left=$registry_left json_ok=$json_ok"
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

# --- Test 9: ancestor matching a kill pattern is NOT excluded (colonies #188) ---
# Regression for the bug where the dashboard /kill endpoint invoked
# kill-federation.sh as a subprocess, making the dashboard Python server
# an ancestor of kill-federation.sh. The unconditional ancestor-walk
# exclusion dropped the dashboard from the kill set so the dashboard
# survived a "kill federation" request. Build a wrapper whose argv
# matches the configured dashboard-py pattern, invoke kill-federation.sh
# from inside it, and verify the wrapper is signal-killed rather than
# completing cleanly.
FIX9="$TMPDIR_TEST/fix9"
mkdir -p "$FIX9/.agentis/daemon"

FIXTURE_TAG_9="kill-fed-test-ancestor-dashpy-$$"
WRAPPER_SCRIPT_9="$TMPDIR_TEST/ancestor-wrapper-$$.sh"
# Pass KILL_SH, FED_DIR, and TAG via environment rather than argv so the
# wrapper's own argv does NOT contain "kill-federation.sh" — filter_self
# has an independent *"$SCRIPT_BASENAME"* filter that drops any process
# whose argv mentions the script name, which is INDEPENDENT of the
# ancestor-walk bug under test. A real dashboard invokes us as a child
# subprocess; its OWN argv doesn't contain "kill-federation.sh" either,
# so using env here mirrors the real scenario faithfully.
cat > "$WRAPPER_SCRIPT_9" <<'WRAP_EOF'
#!/usr/bin/env bash
# Invoked with argv0 = FIXTURE_TAG via the parent's `exec -a`. Spawns
# kill-federation.sh pointing --dashboard-py-pattern at the tag so the
# wrapper itself is a legitimate dashboard kill target.
"$T9_KILL_SH" --fed-dir "$T9_FED_DIR" --no-backup \
    --match-pattern "kill-fed-t9-no-daemon-$$" \
    --dashboard-pattern "kill-fed-t9-no-dashboard-$$" \
    --dashboard-py-pattern "$T9_TAG" > /dev/null 2>&1
WRAP_EOF
chmod +x "$WRAPPER_SCRIPT_9"

# Spawn the wrapper with its argv0 rewritten to FIXTURE_TAG_9 via exec -a
# so pgrep -f matches it against the tag.
# #296: cd into $FIX9 so the wrapper's /proc/<pid>/cwd is rooted under
# the fed-dir. Without this cd, kill-federation.sh's cwd-scoped filter
# (added in #296) would correctly drop the wrapper as out-of-scope,
# which defeats this regression test's intent — test 9 wants to confirm
# that a wrapper WITH cwd inside fed-dir and whose argv matches the
# dashboard-py pattern gets killed even when it's the ancestor.
(cd "$FIX9" && T9_KILL_SH="$KILL_SH" T9_FED_DIR="$FIX9" T9_TAG="$FIXTURE_TAG_9" \
    bash -c "exec -a '$FIXTURE_TAG_9' bash '$WRAPPER_SCRIPT_9'") &
WRAPPER_PID_9=$!
SPAWNED_PIDS+=("$WRAPPER_PID_9")

# kill-federation.sh takes ~4-5s (SIGTERM + 3s sleep + SIGKILL + 1s sleep
# + verification). Poll for wrapper termination with a 20s upper bound.
_t9_start=$(date +%s)
while kill -0 "$WRAPPER_PID_9" 2>/dev/null; do
    _t9_now=$(date +%s)
    if [ $((_t9_now - _t9_start)) -gt 20 ]; then
        break
    fi
    sleep 1
done
unset _t9_start _t9_now

if kill -0 "$WRAPPER_PID_9" 2>/dev/null; then
    fail "9: ancestor-pattern-match" "wrapper PID $WRAPPER_PID_9 still alive after kill-federation.sh window"
    kill -KILL "$WRAPPER_PID_9" 2>/dev/null || true
    set +e
    wait "$WRAPPER_PID_9" 2>/dev/null
    set -e
else
    # Wrapper dead — distinguish "signal-killed" from "clean exit". A
    # clean exit (rc < 128) means kill-federation.sh excluded the
    # wrapper from its kill set and the wrapper completed via its
    # synchronous subprocess call returning → bug still present.
    set +e
    wait "$WRAPPER_PID_9" 2>/dev/null
    rc9=$?
    set -e
    if [ "$rc9" -ge 128 ]; then
        pass "9: ancestor matching dashboard-py pattern is signal-killed (rc=$rc9)"
    else
        fail "9: ancestor-pattern-match" "wrapper exited clean (rc=$rc9) — fix did not kill it"
    fi
fi

# --- Test 10: dashboard with cwd OUTSIDE fed-dir survives (#296 + #440) ---
# A dashboard process whose argv matches DASHBOARD_MATCH but whose
# /proc/<pid>/cwd is rooted OUTSIDE the resolved fed-dir must NOT be
# signalled. This is the regression #296 originally guarded against —
# made explicit here so the cwd-stage of the two-stage filter has its
# own assertion.
FIX10="$TMPDIR_TEST/fix10"
FIX10_OUTSIDE="$TMPDIR_TEST/fix10-outside"
mkdir -p "$FIX10/.agentis/daemon" "$FIX10_OUTSIDE"

FIXTURE_TAG_10="kill-fed-test-dash-outside-$$"
# cwd OUTSIDE fed-dir — the wrapper's /proc/<pid>/cwd must NOT match
# the FED_DIR_ABS prefix. Mirrors test 5's spawn idiom: outer bash -c
# runs `exec -a TAG sleep N`, replacing itself with sleep whose argv0
# is TAG so pgrep -f matches the dashboard pattern.
(cd "$FIX10_OUTSIDE" && exec bash -c "exec -a '$FIXTURE_TAG_10' sleep 9999") &
DUMMY_PID_10=$!
SPAWNED_PIDS+=("$DUMMY_PID_10")
sleep 1

if ! kill -0 "$DUMMY_PID_10" 2>/dev/null; then
    fail "10: spawn dummy" "PID $DUMMY_PID_10 not alive after spawn"
else
    set +e
    "$KILL_SH" --fed-dir "$FIX10" --no-backup \
        --match-pattern "kill-fed-t10-no-daemon-$$" \
        --dashboard-pattern "$FIXTURE_TAG_10" \
        --dashboard-py-pattern "kill-fed-t10-no-dashpy-$$" >/dev/null 2>&1
    set -e
    # Poll up to 20s for either signal-kill or survival.
    _t10_start=$(date +%s)
    while kill -0 "$DUMMY_PID_10" 2>/dev/null; do
        _t10_now=$(date +%s)
        if [ $((_t10_now - _t10_start)) -gt 20 ]; then
            break
        fi
        sleep 1
    done
    unset _t10_start _t10_now
    if kill -0 "$DUMMY_PID_10" 2>/dev/null; then
        pass "10: dashboard with cwd OUTSIDE fed-dir survives the kill"
        kill -KILL "$DUMMY_PID_10" 2>/dev/null || true
    else
        fail "10: cwd-outside" "dashboard PID $DUMMY_PID_10 was killed despite cwd outside fed-dir"
    fi
fi

# --- Test 11: dashboard with cwd INSIDE fed-dir but unregistered survives (#440) ---
# New behaviour from #440: a dashboard whose cwd is rooted at fed-dir
# but whose PID is NOT in $AGENTIS_DIR/daemon/*.pid must NOT be
# signalled. Simulates the tribes-bench operator scenario where the
# dashboard is launched by hand (`setsid -f federation-dashboard ...`)
# and is not registered in the daemon registry. Requires at least one
# *.pid file in daemon/ so the registered-PID set is non-empty —
# otherwise the filter falls back to cwd-only and would kill T11.
FIX11="$TMPDIR_TEST/fix11"
mkdir -p "$FIX11/.agentis/daemon"
# Seed the registry with a fake PID file (PID 1 — init, never our
# fixture). This forces the registered-PID set to be non-empty so the
# filter requires both cwd AND registry membership.
echo "1" > "$FIX11/.agentis/daemon/seed.pid"

FIXTURE_TAG_11="kill-fed-test-dash-inside-unregistered-$$"
# Mirrors test 5's spawn idiom (see test 10).
(cd "$FIX11" && exec bash -c "exec -a '$FIXTURE_TAG_11' sleep 9999") &
DUMMY_PID_11=$!
SPAWNED_PIDS+=("$DUMMY_PID_11")
sleep 1

if ! kill -0 "$DUMMY_PID_11" 2>/dev/null; then
    fail "11: spawn dummy" "PID $DUMMY_PID_11 not alive after spawn"
else
    set +e
    "$KILL_SH" --fed-dir "$FIX11" --no-backup \
        --match-pattern "kill-fed-t11-no-daemon-$$" \
        --dashboard-pattern "$FIXTURE_TAG_11" \
        --dashboard-py-pattern "kill-fed-t11-no-dashpy-$$" >/dev/null 2>&1
    set -e
    _t11_start=$(date +%s)
    while kill -0 "$DUMMY_PID_11" 2>/dev/null; do
        _t11_now=$(date +%s)
        if [ $((_t11_now - _t11_start)) -gt 20 ]; then
            break
        fi
        sleep 1
    done
    unset _t11_start _t11_now
    if kill -0 "$DUMMY_PID_11" 2>/dev/null; then
        pass "11: dashboard with cwd INSIDE fed-dir but unregistered survives the kill"
        kill -KILL "$DUMMY_PID_11" 2>/dev/null || true
    else
        fail "11: unregistered" "dashboard PID $DUMMY_PID_11 was killed despite missing daemon-registry entry"
    fi
fi

# --- Test 12: registered dashboard inside fed-dir is killed (#440) ---
# OR-branch coverage: a process whose argv matches DASHBOARD_MATCH,
# whose cwd is inside fed-dir, AND whose PID is recorded in
# $AGENTIS_DIR/daemon/<id>.pid must be killed. This mirrors the
# behaviour the federation's own start scripts produce (each daemon
# writes its PID into the registry). Without this assertion, an empty
# daemon registry could silently collapse #440's filter to "no
# dashboards killable" — which would defeat the whole script.
FIX12="$TMPDIR_TEST/fix12"
mkdir -p "$FIX12/.agentis/daemon"

FIXTURE_TAG_12="kill-fed-test-dash-registered-$$"
# Mirrors test 5's spawn idiom (see test 10).
(cd "$FIX12" && exec bash -c "exec -a '$FIXTURE_TAG_12' sleep 9999") &
DUMMY_PID_12=$!
SPAWNED_PIDS+=("$DUMMY_PID_12")
sleep 1

# Register the dummy's PID in the daemon registry so stage (b) of the
# filter accepts it. The file's basename is informational only — the
# script reads its single-line content.
echo "$DUMMY_PID_12" > "$FIX12/.agentis/daemon/dummy12.pid"

if ! kill -0 "$DUMMY_PID_12" 2>/dev/null; then
    fail "12: spawn dummy" "PID $DUMMY_PID_12 not alive after spawn"
else
    set +e
    "$KILL_SH" --fed-dir "$FIX12" --no-backup \
        --match-pattern "kill-fed-t12-no-daemon-$$" \
        --dashboard-pattern "$FIXTURE_TAG_12" \
        --dashboard-py-pattern "kill-fed-t12-no-dashpy-$$" >/dev/null 2>&1
    set -e
    _t12_start=$(date +%s)
    while kill -0 "$DUMMY_PID_12" 2>/dev/null; do
        _t12_now=$(date +%s)
        if [ $((_t12_now - _t12_start)) -gt 20 ]; then
            break
        fi
        sleep 1
    done
    unset _t12_start _t12_now
    if kill -0 "$DUMMY_PID_12" 2>/dev/null; then
        fail "12: registered" "registered dashboard PID $DUMMY_PID_12 still alive after kill window"
        kill -KILL "$DUMMY_PID_12" 2>/dev/null || true
    else
        pass "12: registered dashboard inside fed-dir is killed"
    fi
fi

# --- Test 13: store-split symlinked .agentis/daemon is cleaned + backed up
# through the symlink (#1240) ---
# A store-split federation keeps the canonical daemon registry in one place and
# symlinks $FED_DIR/.agentis/daemon to it. `find <symlink-to-dir>` without -L
# does NOT traverse the symlink, so pre-fix the registry was never cleaned
# (reported "0 files" while stale records survived → next start-federation
# refused), and `tar -C .agentis daemon` archived the symlink rather than its
# contents. Verify the resolved-physical-path fix cleans the canonical store
# AND the backup tarball contains the real sidecar files.
FIX13="$TMPDIR_TEST/fix13"
CANON13="$TMPDIR_TEST/fix13-canonical-store"
mkdir -p "$FIX13/.agentis" "$CANON13"
# Real registry files live in the canonical store...
touch "$CANON13/agent1.pid" \
      "$CANON13/agent1.heartbeat" \
      "$CANON13/agent1.colony"
# ...and $FED_DIR/.agentis/daemon is a SYMLINK to it (store-split layout).
ln -s "$CANON13" "$FIX13/.agentis/daemon"

NOPATTERN13="kill-fed-test-no-such-pattern-$$-symlink"
set +e
"$KILL_SH" --fed-dir "$FIX13" \
    --match-pattern "$NOPATTERN13" \
    --dashboard-pattern "$NOPATTERN13" \
    --dashboard-py-pattern "$NOPATTERN13" >/dev/null 2>&1
rc=$?
set -e
# Registry files in the canonical store must be gone (cleaned through symlink).
canon_left=$(find "$CANON13" -maxdepth 1 -type f | wc -l | tr -d ' ')
# Backup tarball must exist AND contain the real sidecar files (proving tar
# followed the symlink to the physical dir, not archived the symlink itself).
backup13="$(find "$FIX13/.agentis/backups" -name 'agentis-daemon-registry-backup-*.tar.gz' 2>/dev/null | head -n 1)"
backup_has_files=0
if [ -n "$backup13" ] && tar tzf "$backup13" 2>/dev/null | grep -q '\.pid$'; then
    backup_has_files=1
fi
if [ "$rc" -eq 0 ] && [ "$canon_left" -eq 0 ] && [ "$backup_has_files" -eq 1 ]; then
    pass "13: store-split symlinked daemon dir cleaned + backed up through symlink"
else
    fail "13: store-split symlink" "rc=$rc canon_left=$canon_left backup_has_files=$backup_has_files"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
