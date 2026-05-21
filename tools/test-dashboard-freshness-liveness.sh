#!/bin/bash
# tools/test-dashboard-freshness-liveness.sh: regression test for #683 —
# the dashboard's per-agent `pid_alive` flag is now driven by
# `<agent>:last_check` memo freshness instead of `os.kill(pid, 0)`. The
# old probe required the dashboard to share a PID namespace with the
# daemons, which is false on containerized federations
# (`research-foundry`, `tribes-bench`): every PID looked dead from the
# host and the banner flipped to DEGRADED even when the agents were
# ticking happily inside the container.
#
# Tests:
#   1. Fresh memo (now - 30s) → pid_alive=True, is_running=True.
#   2. Stale memo (now - 6000s, > 3 × 60s window) → pid_alive=False.
#   3. Missing memo → pid_alive=False.
#   4. Containerized fixture (PID > kernel.pid_max, fresh memo)
#      → is_running=True (the #683 bug repro: PID-kill would return
#      False here, the new freshness check returns True).
#   5. (#700) Same stale_agent fixture (memo at now - 6000s) but with
#      FEDERATION_DASHBOARD_STALENESS_TICKS=120 exported → window
#      becomes 120 × 60s = 7200s > 6000s, so pid_alive=true again.
#      Proves the env knob widens the freshness window for listen-driven
#      federations without code change.
#
# Strategy: drive federation-dashboard-collector.py directly with a
# synthetic daemons JSON, seed `<agent>:last_check` memos with the real
# `agentis memo set` CLI (no shim — `--raw` mode is invoked by the
# collector subprocess, so the binary's actual support matters), assert
# on the emitted JSON.
#
# Usage: ./tools/test-dashboard-freshness-liveness.sh
# Exit 0 on full pass; skips with exit 0 when `agentis` is absent OR
# when the installed `agentis memo get <key> --raw` invocation does not
# succeed (binary predates the `--raw` flag — the collector falls back
# to `pid_alive=False` for every record on those binaries, which is the
# safe default but breaks the fresh-memo assertions below).

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if ! command -v agentis >/dev/null 2>&1; then
    echo "[SKIP] agentis binary not found on \$PATH"
    echo "Results: 0 passed, 0 failed (skipped — agentis not installed)"
    exit 0
fi

if [ ! -r "$COLLECTOR" ]; then
    fail "0: federation-dashboard-collector.py not readable" "$COLLECTOR"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Probe whether the installed `agentis memo get` returns a clean value
# (no decorations) — required by the collector's freshness path.
PROBE_DIR="$TMPDIR_TEST/probe"
mkdir -p "$PROBE_DIR"
(cd "$PROBE_DIR" && agentis memo set probe:key "probe-value" >/dev/null 2>&1) || true
PROBE_OUT="$(cd "$PROBE_DIR" && agentis memo get probe:key 2>/dev/null | tr -d '\r\n ')" || PROBE_OUT=""
if [ "$PROBE_OUT" != "probe-value" ]; then
    echo "[SKIP] installed agentis ($(agentis --version 2>&1)) memo get does not return a clean scalar value"
    echo "Results: 0 passed, 0 failed (skipped — agentis memo get output unexpected)"
    exit 0
fi

# --- Synthetic federation fixture ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.dashboard" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/experience" \
         "$FED_DIR/stub-colony/agents" \
         "$FED_DIR/stub-colony/config" \
         "$FED_DIR/stub-colony/scripts"

cat > "$FED_DIR/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

# Minimal start-colony.sh so resolve-tick-interval.py finds a tick_interval_for()
# case. Default 60000ms for every stub agent — matches the platform default
# the collector falls back to anyway.
cat > "$FED_DIR/stub-colony/scripts/start-colony.sh" <<'SH'
#!/bin/bash
# Stub start-colony.sh — only consumed by resolve-tick-interval.py.
tick_interval_for() {
    case "$1" in
        fresh_agent|stale_agent|missing_agent|container_agent) echo 60000 ;;
        *) echo 60000 ;;
    esac
}
SH
chmod +x "$FED_DIR/stub-colony/scripts/start-colony.sh"

# Four stub agents — one per scenario. The collector requires an .ag
# file on disk to populate the per-agent description block; minimal
# stub body suffices.
for name in fresh_agent stale_agent missing_agent container_agent; do
    cat > "$FED_DIR/stub-colony/agents/${name}.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
done

# --- Seed last_check memos via the real CLI ---
NOW="$(date '+%s')"
FRESH_ISO="$(date -u -d "@$NOW" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            python3 -c "import datetime,sys;print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$NOW")"
STALE_EPOCH=$((NOW - 6000))   # 100 × 60s in the past, well outside 3×60s window
STALE_ISO="$(date -u -d "@$STALE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
            python3 -c "import datetime,sys;print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$STALE_EPOCH")"

(cd "$FED_DIR" && agentis memo set "fresh_agent:last_check"     "$FRESH_ISO" >/dev/null 2>&1) || true
(cd "$FED_DIR" && agentis memo set "stale_agent:last_check"     "$STALE_ISO" >/dev/null 2>&1) || true
# missing_agent: deliberately no memo set
(cd "$FED_DIR" && agentis memo set "container_agent:last_check" "$FRESH_ISO" >/dev/null 2>&1) || true

# --- Synthetic daemons JSON ---
# All four rows carry state=running. PID values:
#   fresh_agent      — $$ (alive)
#   stale_agent      — $$ (alive PID but stale memo — proves PID is irrelevant)
#   missing_agent    — $$ (alive PID but no memo)
#   container_agent  — 2147483600 (high non-existent PID; #683 repro)
ALIVE_PID="$$"
DEAD_PID=2147483600
DAEMONS_JSON_FILE="$TMPDIR_TEST/daemons.json"
python3 - "$DAEMONS_JSON_FILE" "$ALIVE_PID" "$DEAD_PID" <<'PY'
import json, sys
out, alive_pid, dead_pid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = [
    {"agent_id": "a0001", "source": "stub-colony/agents/fresh_agent.ag",
     "state": "running", "health": "healthy", "pid": alive_pid,
     "started_at": 1700000000, "tick_ok": 1, "tick_err": 0},
    {"agent_id": "a0002", "source": "stub-colony/agents/stale_agent.ag",
     "state": "running", "health": "healthy", "pid": alive_pid,
     "started_at": 1700000000, "tick_ok": 1, "tick_err": 0},
    {"agent_id": "a0003", "source": "stub-colony/agents/missing_agent.ag",
     "state": "running", "health": "healthy", "pid": alive_pid,
     "started_at": 1700000000, "tick_ok": 1, "tick_err": 0},
    {"agent_id": "a0004", "source": "stub-colony/agents/container_agent.ag",
     "state": "running", "health": "healthy", "pid": dead_pid,
     "started_at": 1700000000, "tick_ok": 1, "tick_err": 0},
]
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

AGENT_MAP_FILE="$TMPDIR_TEST/agent_map.json"
python3 - "$AGENT_MAP_FILE" <<'PY'
import json, sys
out = sys.argv[1]
rows = [
    {"agent": "fresh_agent",     "colony": "stub-colony"},
    {"agent": "stale_agent",     "colony": "stub-colony"},
    {"agent": "missing_agent",   "colony": "stub-colony"},
    {"agent": "container_agent", "colony": "stub-colony"},
]
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

# --- Run the collector with fed_tools_dir pointing at our repo tools/ ---
COLLECTOR_OUT="$TMPDIR_TEST/collector.json"
EPOCH="$NOW"
python3 "$COLLECTOR" \
    "@$DAEMONS_JSON_FILE" \
    "$(cat "$AGENT_MAP_FILE")" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$FED_DIR/.dashboard" \
    '["stub-colony"]' \
    "$REPO_ROOT/tools" \
    fresh_agent stale_agent missing_agent container_agent \
    > "$COLLECTOR_OUT" 2>"$TMPDIR_TEST/collector.err"

if [ ! -s "$COLLECTOR_OUT" ]; then
    fail "0: collector produced empty output" "stderr: $(head -3 "$TMPDIR_TEST/collector.err" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Helper to extract one agent's record fields ---
extract() {
    # $1: agent name, $2: field
    python3 - "$COLLECTOR_OUT" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
name, field = sys.argv[2], sys.argv[3]
for a in blob.get("agents", []):
    if a.get("name") == name:
        v = a.get(field)
        if isinstance(v, bool):
            print("true" if v else "false")
        else:
            print(v)
        sys.exit(0)
print("MISSING")
PY
}

# --- Test 1: fresh memo → pid_alive=True, is_running=True ---
FRESH_PID_ALIVE="$(extract fresh_agent pid_alive)"
FRESH_IS_RUNNING="$(extract fresh_agent is_running)"
if [ "$FRESH_PID_ALIVE" = "true" ] && [ "$FRESH_IS_RUNNING" = "true" ]; then
    pass "1: fresh memo (now - 0s, within 3×60s window) → pid_alive=true, is_running=true"
else
    fail "1: fresh memo wrong — pid_alive=$FRESH_PID_ALIVE is_running=$FRESH_IS_RUNNING (want true/true)"
fi

# --- Test 2: stale memo (now - 6000s) → pid_alive=False ---
STALE_PID_ALIVE="$(extract stale_agent pid_alive)"
STALE_IS_RUNNING="$(extract stale_agent is_running)"
if [ "$STALE_PID_ALIVE" = "false" ] && [ "$STALE_IS_RUNNING" = "false" ]; then
    pass "2: stale memo (now - 6000s) → pid_alive=false, is_running=false (PID still alive, memo dominates)"
else
    fail "2: stale memo wrong — pid_alive=$STALE_PID_ALIVE is_running=$STALE_IS_RUNNING (want false/false)"
fi

# --- Test 3: missing memo → pid_alive=False ---
MISSING_PID_ALIVE="$(extract missing_agent pid_alive)"
MISSING_IS_RUNNING="$(extract missing_agent is_running)"
if [ "$MISSING_PID_ALIVE" = "false" ] && [ "$MISSING_IS_RUNNING" = "false" ]; then
    pass "3: missing memo → pid_alive=false, is_running=false"
else
    fail "3: missing memo wrong — pid_alive=$MISSING_PID_ALIVE is_running=$MISSING_IS_RUNNING (want false/false)"
fi

# --- Test 4: containerized fixture — non-existent PID + fresh memo → is_running=True ---
# This is the #683 bug repro. Pre-fix: os.kill(2147483600, 0) raised OSError
# and pid_alive went to False even though the agent was ticking happily in
# the container. Post-fix: memo freshness wins, the host's view of the PID
# does not matter.
CONTAINER_PID_ALIVE="$(extract container_agent pid_alive)"
CONTAINER_IS_RUNNING="$(extract container_agent is_running)"
CONTAINER_PID="$(extract container_agent pid)"
if [ "$CONTAINER_PID_ALIVE" = "true" ] && [ "$CONTAINER_IS_RUNNING" = "true" ]; then
    pass "4: containerized fixture (pid=$CONTAINER_PID, fresh memo) → pid_alive=true, is_running=true (#683 fixed)"
else
    fail "4: containerized fixture wrong — pid=$CONTAINER_PID pid_alive=$CONTAINER_PID_ALIVE is_running=$CONTAINER_IS_RUNNING (want true/true; #683 regression)"
fi

# --- Test 5 (#700): same stale_agent fixture, widened window via env knob ---
# stale_agent memo is at NOW-6000s. With STALENESS_TICKS=120 the window
# becomes 120 × 60s = 7200s > 6000s, so the same row that fails Test 2
# (pid_alive=false at default 3 ticks) must now flip back to true.
COLLECTOR_OUT_WIDE="$TMPDIR_TEST/collector-wide.json"
FEDERATION_DASHBOARD_STALENESS_TICKS=120 python3 "$COLLECTOR" \
    "@$DAEMONS_JSON_FILE" \
    "$(cat "$AGENT_MAP_FILE")" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$FED_DIR/.dashboard" \
    '["stub-colony"]' \
    "$REPO_ROOT/tools" \
    fresh_agent stale_agent missing_agent container_agent \
    > "$COLLECTOR_OUT_WIDE" 2>"$TMPDIR_TEST/collector-wide.err"

extract_wide() {
    python3 - "$COLLECTOR_OUT_WIDE" "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
name, field = sys.argv[2], sys.argv[3]
for a in blob.get("agents", []):
    if a.get("name") == name:
        v = a.get(field)
        if isinstance(v, bool):
            print("true" if v else "false")
        else:
            print(v)
        sys.exit(0)
print("MISSING")
PY
}

STALE_WIDE_PID_ALIVE="$(extract_wide stale_agent pid_alive)"
STALE_WIDE_IS_RUNNING="$(extract_wide stale_agent is_running)"
if [ "$STALE_WIDE_PID_ALIVE" = "true" ] && [ "$STALE_WIDE_IS_RUNNING" = "true" ]; then
    pass "5: stale memo (now - 6000s) with FEDERATION_DASHBOARD_STALENESS_TICKS=120 → pid_alive=true, is_running=true (#700 env knob widens window)"
else
    fail "5: env-widened window wrong — pid_alive=$STALE_WIDE_PID_ALIVE is_running=$STALE_WIDE_IS_RUNNING (want true/true; #700 regression)"
fi

# --- Test 6 (#705): auto-regen runs as Python daemon thread inside server
# PID, not an orphan-prone bash subshell. Optional (default OFF) — set
# RUN_AUTO_REGEN_TEST=1 to enable. Adds ~90-100s to the sweep because it
# waits one full auto-regen cycle at the production-realistic 60s interval.
#
# What this test proves:
#   - The wrapper no longer spawns a `( while true; do sleep 60; ... ) &`
#     bash subshell (pgrep assertion at the end).
#   - The server's daemon thread regenerates snapshot.json on the configured
#     interval (mtime assertion).
#   - STALENESS_TICKS env propagates to the auto-regen path, not just the
#     /refresh POST handler. We pick STALENESS_TICKS=100 (window = 6000s)
#     against a seed at now-4000s so the same memo that would read stale
#     at the default 3 × 60s window flips fresh — proves the env reached
#     the collector subprocess spawned from the daemon thread.
#   - SIGKILL on the wrapper leaves no orphan regen subshell behind.
#
# Strategy: launch a real agentis daemon (so `agentis daemon list --json`
# returns one row), launch the wrapper, wait one regen cycle, assert,
# SIGKILL the wrapper.

if [ "${RUN_AUTO_REGEN_TEST:-0}" = "1" ]; then
    WRAPPER="$REPO_ROOT/federation-dashboard/bin/federation-dashboard"
    if [ ! -x "$WRAPPER" ]; then
        fail "6: federation-dashboard wrapper not executable" "$WRAPPER"
    else
        T6_DIR="$TMPDIR_TEST/t6"
        mkdir -p "$T6_DIR/regen-colony/agents" \
                 "$T6_DIR/regen-colony/config" \
                 "$T6_DIR/regen-colony/scripts" \
                 "$T6_DIR/.agentis/logs" \
                 "$T6_DIR/.agentis/experience"
        cat > "$T6_DIR/regen-colony/config/colony.toml" <<'TOML'
[colony]
name = "regen-colony"
TOML
        cat > "$T6_DIR/regen-colony/scripts/start-colony.sh" <<'SH'
#!/bin/bash
tick_interval_for() { echo 60000; }
SH
        chmod +x "$T6_DIR/regen-colony/scripts/start-colony.sh"
        # Long tick so the daemon does not refresh last_check while we sleep.
        cat > "$T6_DIR/regen-colony/agents/regen_agent.ag" <<'AG'
cb 100;
fn tick() -> void {
    return Void;
}
AG

        # Seed last_check at now - 4000s. With STALENESS_TICKS=100 the
        # window is 100 × 60s = 6000s > 4000s → fresh. Default
        # STALENESS_TICKS=3 (window 180s) → stale.
        T6_NOW="$(date '+%s')"
        T6_STALE_EPOCH=$((T6_NOW - 4000))
        T6_STALE_ISO="$(date -u -d "@$T6_STALE_EPOCH" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
                       python3 -c "import datetime,sys;print(datetime.datetime.utcfromtimestamp(int(sys.argv[1])).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$T6_STALE_EPOCH")"
        (cd "$T6_DIR" && agentis memo set "regen_agent:last_check" "$T6_STALE_ISO" >/dev/null 2>&1) || true

        # Launch the actual agent daemon with a huge tick interval so it
        # does not overwrite our seeded last_check during the test window.
        # 86_400_000ms = 24h between ticks. The daemon process is a
        # long-running supervisor (watchdog + inner), so we MUST background
        # it and disconnect stdin — bare `agentis daemon` is foreground
        # and would deadlock the test. </dev/null shields it from any
        # parent-shell job-control surprise.
        DAEMON_OUT="$T6_DIR/daemon.start.out"
        ( cd "$T6_DIR" && agentis daemon \
             "regen-colony/agents/regen_agent.ag" \
             --colony regen-colony \
             --tick-interval 86400000 \
             </dev/null > "$DAEMON_OUT" 2>&1 & )
        sleep 2

        # Pick an unused port for the wrapper. Python helper avoids the
        # `ss`/`netstat` portability problem.
        T6_PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

        WRAPPER_LOG="$T6_DIR/wrapper.log"
        T6_START="$(date '+%s')"
        # Subshell wrapper around the launch so the parent bash does not
        # print "Killed" / "Terminated" job-control noise when we SIGKILL
        # the wrapper at the end of the test.
        ( FEDERATION_DASHBOARD_STALENESS_TICKS=100 \
              bash "$WRAPPER" "$T6_DIR" "$T6_PORT" \
              > "$WRAPPER_LOG" 2>&1 ) &
        WRAPPER_PID=$!

        # Wait for one auto-regen cycle at the default 60s interval, plus
        # 10s grace for the wrapper boot + the regen subprocess to settle.
        # First generate() runs synchronously at startup → snapshot.json
        # mtime ≈ T6_START. Auto-regen fires at T6_START + 60s. We assert
        # the snapshot.json mtime is > T6_START + 30s, which is unambiguous.
        sleep 70

        SNAPSHOT="$T6_DIR/.dashboard/snapshot.json"
        if [ ! -f "$SNAPSHOT" ]; then
            fail "6a: snapshot.json never created at $SNAPSHOT"
        else
            SNAP_MTIME="$(stat -c '%Y' "$SNAPSHOT" 2>/dev/null || stat -f '%m' "$SNAPSHOT" 2>/dev/null || echo 0)"
            REGEN_CUTOFF=$((T6_START + 30))
            if [ "$SNAP_MTIME" -gt "$REGEN_CUTOFF" ]; then
                pass "6a: snapshot.json regenerated after T+30s (mtime=$SNAP_MTIME, cutoff=$REGEN_CUTOFF) — daemon thread is regenerating"
            else
                fail "6a: snapshot.json mtime ($SNAP_MTIME) not past cutoff ($REGEN_CUTOFF) — auto-regen did not fire"
            fi

            # Assert STALENESS_TICKS=100 reached the regen subprocess:
            # with the env propagated the seeded last_check (4000s old) is
            # still inside the 6000s window → pid_alive=true. Without env
            # propagation the regen would have used the default 3-tick
            # window (180s) → pid_alive=false.
            T6_PID_ALIVE="$(python3 - "$SNAPSHOT" <<'PY' 2>/dev/null || echo ERR
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
for a in blob.get("agents", []):
    if a.get("name") == "regen_agent":
        v = a.get("pid_alive")
        print("true" if v else "false")
        sys.exit(0)
print("MISSING")
PY
)"
            if [ "$T6_PID_ALIVE" = "true" ]; then
                pass "6b: regen-thread snapshot has pid_alive=true (STALENESS_TICKS=100 env propagated to auto-regen subprocess)"
            else
                fail "6b: regen-thread snapshot pid_alive=$T6_PID_ALIVE (want true; STALENESS_TICKS env did not reach auto-regen path)"
            fi
        fi

        # SIGKILL the wrapper to verify no orphan bash subshell survives.
        # Pre-#705 there was a `( while true; do sleep 60; generate; done ) &`
        # subshell that would reparent to init on SIGKILL and keep ticking.
        kill -9 "$WRAPPER_PID" 2>/dev/null || true
        sleep 2

        # The orphan-detection grep targets the bash subshell shape removed
        # in #705. We're conservative: only flag processes that match BOTH
        # the regen loop signature and reference our specific fed dir, to
        # avoid false positives from concurrent test runs.
        ORPHAN_HITS="$(pgrep -af 'while true; do sleep' 2>/dev/null | grep -F "$T6_DIR" || true)"
        if [ -z "$ORPHAN_HITS" ]; then
            pass "6c: no orphan 'while true; do sleep ...' bash subshell survived SIGKILL on wrapper"
        else
            fail "6c: orphan bash subshell survived SIGKILL: $ORPHAN_HITS"
        fi

        # Clean up: SIGKILL on the wrapper bypassed its trap, so the python
        # server child orphans to init. That is the documented behaviour
        # of bash on uncatchable signals; out of scope for #705 (the bug
        # was the SECOND orphan — the regen bash subshell — which is now
        # gone). We clean up the orphan python server here so this test
        # does not leak processes across reruns. Scope to our specific
        # fed dir to avoid touching unrelated dashboards.
        pkill -f "federation-dashboard-server.py.*$T6_DIR" 2>/dev/null || true
        (cd "$T6_DIR" && agentis daemon stop --all >/dev/null 2>&1) || true
    fi
else
    echo "[SKIP] 6: auto-regen daemon-thread test (set RUN_AUTO_REGEN_TEST=1 to enable; adds ~70-90s)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
