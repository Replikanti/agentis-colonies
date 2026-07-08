#!/bin/bash
# tools/test-dashboard-api-status.sh: functional test for #1465 — the
# federation-dashboard server's `GET /api/status` machine-readable status
# endpoint.
#
# The endpoint is a pure JSON view of the collector snapshot the HTML page
# already renders (snapshot.json), so ops tooling (start scripts, probes,
# benchmark harnesses) never has to scrape HTML or shell into
# `agentis daemon list`. This test launches the REAL server.py against a
# synthetic serve_dir + snapshot.json fixture and asserts:
#
#   1. GET /api/status returns 200 application/json.
#   2. The body carries dashboard_version (from federation-dashboard/VERSION),
#      a generated_at ISO-8601 stamp, and one agent record per snapshot agent.
#   3. `state` is the EFFECTIVE state the page shows: is_running -> "running",
#      a stale registry-running row -> "dead", everything else passthrough.
#   4. `last_seen` is ISO-8601 for a non-zero last-ok ts, null otherwise.
#   5. An unknown /api/* path still 404s.
#
# Usage: ./tools/test-dashboard-api-status.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERVER_PY="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-server.py"
VERSION_FILE="$REPO_ROOT/federation-dashboard/VERSION"

PASS=0
FAIL=0
SKIP=0
TMPDIR_TEST="$(mktemp -d)"
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    # Defense-in-depth: reap any leaked server child bound to our tmp dir.
    pkill -f "federation-dashboard-server.py.*$TMPDIR_TEST" 2>/dev/null || true
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }
skip() { echo "[SKIP] $1${2:+: $2}"; SKIP=$((SKIP + 1)); }

if ! command -v python3 >/dev/null 2>&1; then
    skip "0: python3 not available"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 0
fi
if [ ! -f "$SERVER_PY" ]; then
    fail "0: federation-dashboard-server.py missing" "$SERVER_PY"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi

# --- Fixture: serve_dir with a synthetic collector snapshot ---
# The server os.chdir()'s into serve_dir and reads snapshot.json from it,
# so this is the whole surface /api/status touches. Three agents exercise
# the three state-derivation branches.
SERVE_DIR="$TMPDIR_TEST/.dashboard"
mkdir -p "$SERVE_DIR"
cat > "$SERVE_DIR/snapshot.json" <<'JSON'
{
  "now_epoch": 1752062096,
  "agents": [
    {"name": "router", "colony": "triage", "state": "running", "is_running": true, "agent_last_ok_ts": 1752062081},
    {"name": "code_writer", "colony": "implementation", "state": "running", "is_running": false, "agent_last_ok_ts": 1752061000},
    {"name": "ship_decider", "colony": "release", "state": "stopped", "is_running": false, "agent_last_ok_ts": 0}
  ]
}
JSON

# --- Pick a free port + launch the real server ---
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"

# script_path (argv 3) is only invoked by /refresh + the auto-regen loop;
# point it at a no-op so an accidental fire does nothing. Push the regen
# interval past the test window so it never fires.
NOOP_SCRIPT="$TMPDIR_TEST/noop.sh"
printf '#!/bin/bash\nexit 0\n' > "$NOOP_SCRIPT"
chmod +x "$NOOP_SCRIPT"

FEDERATION_DASHBOARD_REGEN_S=3600 \
  python3 "$SERVER_PY" \
    "$SERVE_DIR" "$PORT" "$NOOP_SCRIPT" "$TMPDIR_TEST" \
    "router,code_writer,ship_decider" '[]' '' \
    >"$TMPDIR_TEST/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the port to accept connections (up to ~5s).
READY=""
for _ in $(seq 1 50); do
    if python3 -c "import socket,sys; s=socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)" 2>/dev/null; then
        READY=1
        break
    fi
    sleep 0.1
done
if [ -z "$READY" ]; then
    fail "1: server did not come up on port $PORT" "$(cat "$TMPDIR_TEST/server.log" 2>/dev/null)"
    echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
    exit 1
fi
pass "1: server accepting connections on 127.0.0.1:$PORT"

# --- HTTP client helper (urllib, no curl dependency). Prints
#     "<status>\n<body>" for a GET. ---
http_get() {
    python3 - "$1" <<'PY'
import sys, urllib.request
url = sys.argv[1]
try:
    with urllib.request.urlopen(url, timeout=5) as r:
        print(r.status)
        print(r.headers.get('Content-Type', ''))
        sys.stdout.write(r.read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print(e.code)
    print(e.headers.get('Content-Type', ''))
    sys.stdout.write(e.read().decode('utf-8', 'replace'))
except Exception as e:  # noqa: BLE001
    print('ERR')
    print('')
    sys.stdout.write(str(e))
PY
}

STATUS_OUT="$TMPDIR_TEST/status.out"
http_get "http://127.0.0.1:$PORT/api/status" > "$STATUS_OUT"
CODE="$(sed -n '1p' "$STATUS_OUT")"
CTYPE="$(sed -n '2p' "$STATUS_OUT")"
BODY="$(sed '1,2d' "$STATUS_OUT")"

if [ "$CODE" = "200" ]; then
    pass "2: GET /api/status returns 200"
else
    fail "2: GET /api/status returned $CODE" "$BODY"
fi

case "$CTYPE" in
    application/json*) pass "3: Content-Type is application/json" ;;
    *) fail "3: Content-Type not application/json" "$CTYPE" ;;
esac

# --- Assert the response shape + state derivation via python. ---
EXPECT_VERSION="$(head -n1 "$VERSION_FILE" 2>/dev/null | tr -d '[:space:]')"
if EXPECT_VERSION="$EXPECT_VERSION" python3 - "$BODY" <<'PY'
import sys, os, json
body = sys.argv[1]
try:
    obj = json.loads(body)
except Exception as e:  # noqa: BLE001
    print("not JSON:", e); sys.exit(1)
errs = []
if obj.get('dashboard_version') != os.environ.get('EXPECT_VERSION'):
    errs.append("dashboard_version=%r expected %r" % (obj.get('dashboard_version'), os.environ.get('EXPECT_VERSION')))
ga = obj.get('generated_at')
if not (isinstance(ga, str) and ga.endswith('Z') and 'T' in ga):
    errs.append("generated_at not ISO-8601 Z: %r" % (ga,))
agents = {a.get('agent'): a for a in obj.get('agents', [])}
if set(agents) != {'router', 'code_writer', 'ship_decider'}:
    errs.append("agent set mismatch: %r" % (sorted(agents),))
if agents.get('router', {}).get('state') != 'running':
    errs.append("router state=%r expected running" % (agents.get('router', {}).get('state'),))
if agents.get('router', {}).get('colony') != 'triage':
    errs.append("router colony=%r expected triage" % (agents.get('router', {}).get('colony'),))
if agents.get('code_writer', {}).get('state') != 'dead':
    errs.append("code_writer state=%r expected dead (stale registry-running)" % (agents.get('code_writer', {}).get('state'),))
if agents.get('ship_decider', {}).get('state') != 'stopped':
    errs.append("ship_decider state=%r expected stopped" % (agents.get('ship_decider', {}).get('state'),))
ls = agents.get('router', {}).get('last_seen')
if not (isinstance(ls, str) and ls.endswith('Z')):
    errs.append("router last_seen not ISO-8601: %r" % (ls,))
if agents.get('ship_decider', {}).get('last_seen') is not None:
    errs.append("ship_decider last_seen expected null, got %r" % (agents.get('ship_decider', {}).get('last_seen'),))
if errs:
    print("\n".join(errs)); sys.exit(1)
sys.exit(0)
PY
then
    pass "4: response carries version + generated_at + per-agent effective state + last_seen"
else
    fail "4: response shape/state assertions failed"
fi

# --- Unknown /api/* path must 404. ---
UNK_OUT="$TMPDIR_TEST/unknown.out"
http_get "http://127.0.0.1:$PORT/api/does-not-exist" > "$UNK_OUT"
UNK_CODE="$(sed -n '1p' "$UNK_OUT")"
if [ "$UNK_CODE" = "404" ]; then
    pass "5: unknown /api/* path returns 404"
else
    fail "5: unknown /api/* path returned $UNK_CODE (expected 404)"
fi

# --- /api/status with a query string must still route (200), not 404. A
# monitoring probe appending ?t=<cachebuster> or a trailing ? previously fell
# through to the /api/* 404 branch (exact-match bug caught by QA on #1465). ---
QS_OUT="$TMPDIR_TEST/status-qs.out"
http_get "http://127.0.0.1:$PORT/api/status?t=12345&nocache=1" > "$QS_OUT"
QS_CODE="$(sed -n '1p' "$QS_OUT")"
if [ "$QS_CODE" = "200" ]; then
    pass "6: /api/status with a query string still returns 200"
else
    fail "6: /api/status?t=... returned $QS_CODE (expected 200)"
fi

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
