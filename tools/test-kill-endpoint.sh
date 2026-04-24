#!/bin/bash
# tools/test-kill-endpoint.sh: smoke test for the dashboard /kill endpoint
# (issue #161). Boots federation-dashboard.sh against an empty fixture
# .agentis/ dir, verifies the /kill HTTP handler returns the documented
# JSON shape, and that the served HTML carries the new declarative button
# label + notification region (and NOT the old 'Kill Failed: ' antipattern
# formatter). Self-contained: only bash, python3, curl. Cleans up via trap
# on every exit path.
#
# Usage: ./tools/test-kill-endpoint.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# #252: dashboard extracted to standalone component.
DASHBOARD_SH="$REPO_ROOT/federation-dashboard/bin/federation-dashboard"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DASH_PID=""

cleanup() {
    if [ -n "$DASH_PID" ]; then
        # Kill the dashboard wrapper; its python3 child is in the same
        # process group so a TERM to the wrapper takes everything down.
        kill -TERM "-$DASH_PID" 2>/dev/null || kill -TERM "$DASH_PID" 2>/dev/null || true
        # Best-effort hard kill after a short grace period.
        sleep 1
        kill -KILL "-$DASH_PID" 2>/dev/null || kill -KILL "$DASH_PID" 2>/dev/null || true
    fi
    rm -rf "$TMPDIR_TEST"
}
trap cleanup EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

# Sanity: dashboard script exists and is executable.
if [ ! -x "$DASHBOARD_SH" ]; then
    fail "0: dashboard script missing or not executable" "$DASHBOARD_SH"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Fixture: empty federation directory with a single colony stub so the
#     dashboard's auto-discovery does not bail. ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.agentis/daemon" \
         "$FED_DIR/stub-colony/agents" \
         "$FED_DIR/stub-colony/config" \
         "$FED_DIR/tools"
cat > "$FED_DIR/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML
# Minimal .ag file so the discover loop has something to enumerate.
cat > "$FED_DIR/stub-colony/agents/stub.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
# #252: the dashboard resolves shared helpers via <fed-dir>/tools/ first,
# then <fed-dir>/../tools/. /kill needs kill-federation.sh; symlink the
# real one from the repo so the endpoint can shell out.
ln -s "$REPO_ROOT/tools/kill-federation.sh" "$FED_DIR/tools/kill-federation.sh"

# --- Pick a free port ---
PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)")"
if [ -z "$PORT" ]; then
    fail "1: free-port discovery failed"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Boot the dashboard. setsid puts it in its own process group so the
#     trap can take down the python3 child cleanly. Output silenced; we
#     interrogate the server over HTTP instead.
#     cwd = $FED_DIR so kill-federation.sh's #296 cwd-scoped filter sees
#     the dashboard as legitimately "inside" this test's fed dir. Without
#     this cd, the filter would (correctly) reject this stub dashboard as
#     out-of-scope and the /kill endpoint would report 0 dashboards killed. ---
LOG_FILE="$TMPDIR_TEST/dashboard.log"
(cd "$FED_DIR" && setsid bash "$DASHBOARD_SH" "$FED_DIR" "$PORT" >"$LOG_FILE" 2>&1) &
DASH_PID=$!

# --- Test 1: /  returns 200 within 5s. ---
ready=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -f -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
        ready=1
        break
    fi
    sleep 0.5
done
if [ "$ready" -eq 1 ]; then
    pass "1: dashboard responds on http://127.0.0.1:$PORT/"
else
    fail "1: dashboard never became ready" "log tail: $(tail -10 "$LOG_FILE" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 2: POST /kill with empty body returns documented JSON shape,
#     exit code 0 (empty fed -> kill script reports clean). ---
RESP_FILE="$TMPDIR_TEST/resp1.json"
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{}' "http://127.0.0.1:$PORT/kill" -o "$RESP_FILE" || true
if python3 - "$RESP_FILE" <<'PY' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, dict), 'response not a JSON object'
for k in ('ok', 'exit', 'summary', 'json', 'stderr_tail'):
    assert k in data, f'missing key: {k}'
assert data['exit'] == 0, f"expected exit==0, got {data['exit']}"
assert data['ok'] is True, f"expected ok==True, got {data['ok']!r}"
PY
then
    pass "2: POST /kill returns documented JSON keys, exit 0 on empty fixture"
else
    fail "2: /kill JSON shape" "body: $(head -c 400 "$RESP_FILE" 2>/dev/null)"
fi

# --- Test 3: GET /  HTML contains 'Kill Federation' label + new
#     notification region + skip-backup checkbox; does NOT contain the
#     old 'Kill Failed: ' antipattern formatter. ---
HTML_FILE="$TMPDIR_TEST/index.html"
curl -s "http://127.0.0.1:$PORT/" -o "$HTML_FILE" || true
if [ ! -s "$HTML_FILE" ]; then
    fail "3: GET / returned empty body"
else
    html_ok=1
    if ! grep -q 'Kill Federation' "$HTML_FILE"; then
        echo "  missing literal 'Kill Federation' in HTML"
        html_ok=0
    fi
    if ! grep -q 'id="notification-region"' "$HTML_FILE"; then
        echo "  missing #notification-region element"
        html_ok=0
    fi
    if ! grep -q 'id="kill-no-backup"' "$HTML_FILE"; then
        echo "  missing #kill-no-backup checkbox"
        html_ok=0
    fi
    if grep -q 'Kill Failed: ' "$HTML_FILE"; then
        echo "  antipattern formatter 'Kill Failed: ' still present"
        html_ok=0
    fi
    if [ "$html_ok" -eq 1 ]; then
        pass "3: HTML carries declarative label + notification region, no antipattern formatter"
    else
        fail "3: HTML structure"
    fi
fi

# --- Test 4: POST /kill with {"no_backup": true} succeeds and does NOT
#     create a backup tarball under .agentis/backups/. ---
# Pre-clean any backups left from test 2 (kill script writes one by default).
rm -rf "$FED_DIR/.agentis/backups" 2>/dev/null || true
RESP2_FILE="$TMPDIR_TEST/resp2.json"
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"no_backup": true}' "http://127.0.0.1:$PORT/kill" -o "$RESP2_FILE" || true
if python3 - "$RESP2_FILE" <<'PY' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert data.get('ok') is True, f"ok != True: {data!r}"
assert data.get('exit') == 0, f"exit != 0: {data!r}"
PY
then
    backup_count=$(find "$FED_DIR/.agentis/backups" -name 'agentis-daemon-registry-backup-*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$backup_count" -eq 0 ]; then
        pass "4: POST /kill {no_backup:true} succeeds and skips backup tarball"
    else
        fail "4: no_backup honoured" "backup_count=$backup_count (expected 0)"
    fi
else
    fail "4: /kill no_backup response" "body: $(head -c 400 "$RESP2_FILE" 2>/dev/null)"
fi

# --- Test 5: Server still healthy after both POSTs (200 on /). ---
if curl -f -s -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then
    pass "5: dashboard still serving after /kill round-trips"
else
    fail "5: dashboard stopped responding"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
