#!/bin/bash
# tools/test-sse-stream.sh: smoke test for the Server-Sent Events stream
# in federation-dashboard (#313 PR 1). Boots the dashboard against a
# minimal fixture federation on a free local port, then exercises:
#
#   t1: GET /events emits at least one `event: snapshot` frame within 5s.
#   t2: GET /  still returns 200 + non-empty HTML (static first-paint
#       path is unchanged).
#   t3: when the wrapper writes a fresh snapshot, a new SSE frame
#       arrives within ~1s (the watcher polls every 250ms).
#   t4: an SSE client disconnect doesn't crash the server (server keeps
#       serving / and accepts a new GET /events afterwards).
#   t5: a second GET /events succeeds after the first one was killed
#       (multi-client + reconnect path).
#
# Self-contained: only bash, python3, curl. Cleans up via trap on every
# exit path. Auto-skips when python3 or a free port is unavailable.
#
# Live-federation safety: spawns its own dashboard process on a free
# port under a temp federation fixture. Never targets the production
# 8420 dashboard.
#
# Usage: ./tools/test-sse-stream.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD_SH="$REPO_ROOT/federation-dashboard/bin/federation-dashboard"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DASH_PID=""

cleanup() {
    if [ -n "$DASH_PID" ]; then
        # Kill the wrapper and its python child (same process group).
        kill -TERM "-$DASH_PID" 2>/dev/null || kill -TERM "$DASH_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "-$DASH_PID" 2>/dev/null || kill -KILL "$DASH_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1${2:+: $2}"; }

# Sanity: dashboard script exists and is executable.
if [ ! -x "$DASHBOARD_SH" ]; then
    fail "0: dashboard script missing or not executable" "$DASHBOARD_SH"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    skip "0: python3 not on PATH; SSE test cannot pick a free port"
    echo "Results: $PASS passed, $FAIL failed"
    exit 0
fi

# --- Fixture: minimal federation directory with a single colony stub. ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.agentis/daemon" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/experience" \
         "$FED_DIR/stub-colony/agents" \
         "$FED_DIR/stub-colony/config"

cat > "$FED_DIR/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

cat > "$FED_DIR/stub-colony/agents/stub_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

# --- Pick a free port (avoid the live 8420 dashboard). Range fallback if
#     getsockname-with-:0 is somehow blocked. ---
PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)" 2>/dev/null || true)"
if [ -z "$PORT" ]; then
    skip "0: free-port discovery failed; SSE test requires a free local port"
    echo "Results: $PASS passed, $FAIL failed"
    exit 0
fi
if [ "$PORT" = "8420" ]; then
    # Astronomical, but the live dashboard runs on 8420 — never collide.
    PORT=$((PORT + 1))
fi

# --- Boot the dashboard. setsid -> own process group for clean teardown. ---
LOG_FILE="$TMPDIR_TEST/dashboard.log"
setsid bash "$DASHBOARD_SH" "$FED_DIR" "$PORT" >"$LOG_FILE" 2>&1 &
DASH_PID=$!

# Wait for readiness (GET /).
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -f -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -ne 1 ]; then
    fail "0: dashboard never became ready" "log tail: $(tail -10 "$LOG_FILE" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: GET /events emits at least one `event: snapshot` frame. ---
# curl -N (no buffering); --max-time 6s gives the watcher (250ms poll) and
# the wrapper's atomic snapshot write plenty of slack. We grep for the SSE
# event header rather than parsing the frame payload — payload validity is
# enforced by the EventSource consumer end-to-end in the browser.
SSE_OUT_T1="$TMPDIR_TEST/events1.txt"
curl -N -s --max-time 6 "http://127.0.0.1:$PORT/events" >"$SSE_OUT_T1" 2>&1 || true
if grep -q '^event: snapshot' "$SSE_OUT_T1"; then
    pass "1: GET /events emits at least one snapshot frame within 6s"
else
    fail "1: no snapshot frame in /events stream" "head: $(head -5 "$SSE_OUT_T1" 2>/dev/null | tr '\n' ' ')"
fi

# Also assert the frame body parses as JSON and carries the server-injected
# __hash field that the browser uses to dedupe identical pushes. We pull
# the first `data: ` line out of the captured stream and feed it to
# python3.
DATA_LINE="$(grep -m 1 '^data: ' "$SSE_OUT_T1" 2>/dev/null | sed 's/^data: //')"
if [ -n "$DATA_LINE" ]; then
    if python3 - "$DATA_LINE" <<'PY' 2>/dev/null
import sys, json
obj = json.loads(sys.argv[1])
assert isinstance(obj, dict), 'snapshot payload not a JSON object'
assert '__hash' in obj, 'snapshot missing __hash field'
assert isinstance(obj['__hash'], str) and len(obj['__hash']) >= 4, 'bad __hash'
PY
    then
        pass "1b: snapshot frame payload is valid JSON with __hash field"
    else
        fail "1b: snapshot frame payload failed JSON / __hash validation"
    fi
else
    fail "1b: no data: line captured from /events; cannot validate payload"
fi

# --- Test 2: GET / continues to serve a fully-rendered index.html. ---
HTML_OUT="$TMPDIR_TEST/index.html"
HTTP_CODE="$(curl -s -o "$HTML_OUT" -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
if [ "$HTTP_CODE" = "200" ] && [ -s "$HTML_OUT" ] && grep -q '<html' "$HTML_OUT"; then
    pass "2: GET / returns 200 + non-empty HTML (static first-paint preserved)"
else
    fail "2: GET / regression" "code=$HTTP_CODE size=$(wc -c <"$HTML_OUT" 2>/dev/null || echo 0)"
fi

# --- Test 3: a fresh wrapper-side snapshot triggers a new SSE frame
#     within ~1s. We poke the snapshot file directly with a different
#     payload (mimicking what the wrapper's regen loop writes), then
#     listen on /events and assert the new payload arrives. The watcher
#     polls every 250ms so 2s is generous but not flaky. ---
SNAPSHOT_FILE="$FED_DIR/.dashboard/snapshot.json"
if [ ! -f "$SNAPSHOT_FILE" ]; then
    fail "3: snapshot.json was not written by the wrapper" "expected $SNAPSHOT_FILE"
else
    # Inject a unique sentinel into the snapshot to disambiguate the
    # frame we expect from any earlier cached one.
    SENTINEL="sse-test-$(date +%s%N)-$$"
    NEW_SNAP="$TMPDIR_TEST/new-snap.json"
    python3 - "$SNAPSHOT_FILE" "$NEW_SNAP" "$SENTINEL" <<'PY' 2>/dev/null
import sys, json
src, dst, sentinel = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(src) as f:
        obj = json.load(f)
    if not isinstance(obj, dict):
        obj = {}
except Exception:
    obj = {}
obj['__test_sentinel__'] = sentinel
# Strip any existing __hash so the watcher is forced to recompute.
obj.pop('__hash', None)
with open(dst, 'w') as f:
    json.dump(obj, f)
PY
    if [ -s "$NEW_SNAP" ]; then
        # Atomic update mirroring what the wrapper does.
        mv -f "$NEW_SNAP" "$SNAPSHOT_FILE"
        # Capture /events for 3s; the watcher's 250ms poll should pick up
        # the mtime change and push a new frame.
        SSE_OUT_T3="$TMPDIR_TEST/events3.txt"
        curl -N -s --max-time 3 "http://127.0.0.1:$PORT/events" >"$SSE_OUT_T3" 2>&1 || true
        if grep -q "$SENTINEL" "$SSE_OUT_T3"; then
            pass "3: fresh snapshot file triggers a new SSE frame within 3s"
        else
            fail "3: SSE frame did not pick up the fresh snapshot sentinel" \
                 "head: $(head -5 "$SSE_OUT_T3" 2>/dev/null | tr '\n' ' ')"
        fi
    else
        fail "3: failed to construct sentinel snapshot payload"
    fi
fi

# --- Test 4: client disconnect doesn't crash the server. We open a
#     connection, kill it after a short window, then verify GET / still
#     returns 200. ---
( curl -N -s --max-time 1 "http://127.0.0.1:$PORT/events" >/dev/null 2>&1 || true ) &
DISC_PID=$!
sleep 0.5
kill -TERM "$DISC_PID" 2>/dev/null || true
wait "$DISC_PID" 2>/dev/null || true
HTTP_CODE_T4="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
if [ "$HTTP_CODE_T4" = "200" ]; then
    pass "4: server still serves / after a /events client disconnect"
else
    fail "4: server unhealthy after client disconnect" "code=$HTTP_CODE_T4"
fi

# --- Test 5: a second /events connection succeeds after a prior one was
#     killed (multi-client / reconnect path). ---
SSE_OUT_T5="$TMPDIR_TEST/events5.txt"
curl -N -s --max-time 4 "http://127.0.0.1:$PORT/events" >"$SSE_OUT_T5" 2>&1 || true
if grep -q '^event: snapshot' "$SSE_OUT_T5"; then
    pass "5: second /events connection emits a snapshot frame (reconnect path)"
else
    fail "5: second /events connection did not deliver a snapshot frame" \
         "head: $(head -5 "$SSE_OUT_T5" 2>/dev/null | tr '\n' ' ')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
