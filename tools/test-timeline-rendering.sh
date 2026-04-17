#!/bin/bash
# tools/test-timeline-rendering.sh: structural test for the Event Timeline
# panel in federation-dashboard.sh (issue #158). Boots the dashboard against
# a fixture .agentis/logs/ directory containing log lines in BOTH the raw
# 13-digit epoch-ms format (the real agentis daemon production format) and
# the legacy ISO/bracketed format, plus one corrupted line, then asserts
# the served HTML renders all three events with human-readable timestamps,
# wires the per-federation Clear button + cursor, and does NOT leak raw
# 13-digit ms into the rendered timeline rows. Also smokes /kill so we
# don't regress #161.
#
# Usage: ./tools/test-timeline-rendering.sh
# Exit code 0 if all tests pass, 1 otherwise.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_SH="$SCRIPT_DIR/federation-dashboard.sh"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DASH_PID=""

cleanup() {
    if [ -n "$DASH_PID" ]; then
        kill -TERM "-$DASH_PID" 2>/dev/null || kill -TERM "$DASH_PID" 2>/dev/null || true
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

# --- Fixture: federation directory with a single colony stub and a logs
#     dir containing three crafted lines exercising each timestamp path.
#     The dashboard reads logs from "$FED_DIR/../.agentis/logs", so the
#     logs live at $TMPDIR_TEST/.agentis/logs/ (one level above FED_DIR). ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.agentis/daemon" \
         "$TMPDIR_TEST/.agentis/logs" \
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

# Three log lines:
# 1. Raw 13-digit epoch-ms format (the real agentis daemon production
#    format) with the 'emit' keyword so it hits the timeline.
# 2. Legacy bracketed ISO format (kept as a fallback for older logs and
#    external producers) with the 'error' keyword.
# 3. Corrupted line with no parseable timestamp; the 'action' keyword
#    keeps it in the timeline so the ts==0 fallback path is exercised.
cat > "$TMPDIR_TEST/.agentis/logs/stub_agent.log" <<'LOG'
1776250011452 emit test:event from stub
[2026-04-15 13:23:58] error something failed
corrupted line with no timestamp action draft
LOG

# --- Pick a free port ---
PORT="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)")"
if [ -z "$PORT" ]; then
    fail "1: free-port discovery failed"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Boot the dashboard. setsid -> own process group for clean teardown. ---
LOG_FILE="$TMPDIR_TEST/dashboard.log"
setsid bash "$DASHBOARD_SH" "$FED_DIR" "$PORT" >"$LOG_FILE" 2>&1 &
DASH_PID=$!

# Wait for readiness.
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

HTML_FILE="$TMPDIR_TEST/index.html"
curl -s "http://127.0.0.1:$PORT/" -o "$HTML_FILE" || true

if [ ! -s "$HTML_FILE" ]; then
    fail "0: GET / returned empty body"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: timeline JSON injection contains all three events. ---
t1_ok=1
if ! grep -q 'test:event' "$HTML_FILE"; then echo "  missing 'test:event'"; t1_ok=0; fi
if ! grep -q 'something failed' "$HTML_FILE"; then echo "  missing 'something failed'"; t1_ok=0; fi
if ! grep -q 'corrupted line' "$HTML_FILE"; then echo "  missing 'corrupted line'"; t1_ok=0; fi
if [ "$t1_ok" -eq 1 ]; then
    pass "1: timeline ingests both raw-ms and ISO formats plus the no-timestamp fallback"
else
    fail "1: timeline missing one or more crafted events"
fi

# --- Test 2: formatTimestamp helper present in served HTML. ---
if grep -q 'function formatTimestamp' "$HTML_FILE"; then
    pass "2: formatTimestamp helper present in served HTML"
else
    fail "2: formatTimestamp helper missing"
fi

# --- Test 3: TIMELINE_CURSOR_KEY namespaced via FED_NAME concat. The
#     trailing dot proves the FED_NAME suffix is appended (vs. a bare
#     constant that would collide across federations). ---
if grep -q 'dashboard.timeline.cursorMs\.' "$HTML_FILE"; then
    pass "3: TIMELINE_CURSOR_KEY is namespaced with FED_NAME suffix"
else
    fail "3: TIMELINE_CURSOR_KEY namespacing missing"
fi

# --- Test 4: Clear button structurally present. ---
if grep -q 'id="timeline-clear-btn"' "$HTML_FILE"; then
    pass "4: timeline Clear button present in HTML"
else
    fail "4: #timeline-clear-btn missing"
fi

# --- Test 5: Tooltip wired — at least one tip-text near a timeline-ts. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Look for 'tip-text' within ~200 chars after any 'timeline-ts' occurrence
# inside the JS source (the IIFE constructs the row template).
ok = False
for m in re.finditer(r'timeline-ts', html):
    window = html[m.start(): m.start() + 400]
    if 'tip-text' in window:
        ok = True
        break
sys.exit(0 if ok else 1)
PY
then
    pass "5: tooltip (tip-text) wired adjacent to timeline-ts in row template"
else
    fail "5: tip-text not found near timeline-ts"
fi

# --- Test 6: no raw 13-digit ms leaks into rendered timeline rows. The
#     events array literal in the JS source legitimately contains the raw
#     ms values (that's the JSON payload), so we restrict the check to
#     the JS that builds the row HTML — i.e. the timeline IIFE body and
#     the format helpers must not contain a 13-digit standalone literal
#     in a way that would render in the row. We instead assert that the
#     row template uses formatTimestamp(e.ts), not bare e.ts string
#     concatenation. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Locate the timeline IIFE: from "// --- Event Timeline ---" to the next
# "// --- " marker.
m = re.search(r'// --- Event Timeline ---(.*?)// --- ', html, re.DOTALL)
if not m:
    sys.exit(1)
body = m.group(1)
# Must reference formatTimestamp on e.ts; must NOT concat e.ts directly
# into a span without going through formatTimestamp/esc/Date.
if 'formatTimestamp(e.ts)' not in body:
    sys.exit(1)
# Defensive: ensure no naked '+ e.ts +' that would dump a 13-digit number.
if re.search(r'\+\s*e\.ts\s*\+', body):
    sys.exit(1)
sys.exit(0)
PY
then
    pass "6: timeline row template renders e.ts via formatTimestamp, no raw-ms leak"
else
    fail "6: rendered timeline row template still references e.ts directly"
fi

# --- Test 7: /kill regression smoke (issue #161). ---
RESP_FILE="$TMPDIR_TEST/kill.json"
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{}' "http://127.0.0.1:$PORT/kill" -o "$RESP_FILE" || true
if python3 - "$RESP_FILE" <<'PY' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, dict)
assert 'ok' in data
PY
then
    pass "7: /kill endpoint still returns JSON with 'ok' key"
else
    fail "7: /kill regression — response missing 'ok' key" "body: $(head -c 400 "$RESP_FILE" 2>/dev/null)"
fi

# --- Test 8: unit-mismatch guard. relTime() expects epoch-SECONDS. The
#     timeline IIFE works in epoch-ms (post-#158) and must divide by 1000
#     before passing to relTime. Recent Experience modal works in epoch-
#     seconds and must NOT divide. Lock both in to prevent the next
#     refactor from mixing units. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Timeline IIFE must call relTime(e.ts / 1000) (or e.ts/1000) somewhere.
m = re.search(r'// --- Event Timeline ---(.*?)// --- ', html, re.DOTALL)
if not m:
    sys.exit(1)
timeline_body = m.group(1)
if not re.search(r'relTime\(\s*e\.ts\s*/\s*1000\s*\)', timeline_body):
    sys.exit(1)
# Recent Experience modal must call relTime(e.ts) — no division. Locate
# the modal block by its header marker.
m2 = re.search(r'Recent Experience.*?(relTime\([^)]*\))', html, re.DOTALL)
if not m2:
    sys.exit(1)
call = m2.group(1)
if '/' in call or '* 1000' in call:
    sys.exit(1)
sys.exit(0)
PY
then
    pass "8: unit contract — timeline divides ts/1000, recent_experience does not"
else
    fail "8: unit-mismatch guard tripped (relTime call shape changed)"
fi

# --- #167: per-(agent, class) cursor key namespaced via FED_NAME suffix.
#     Mirrors test 3 for the new selective-clear cursor. ---
if grep -q 'dashboard.timeline.cursorClass\.' "$HTML_FILE"; then
    pass "9: TIMELINE_CURSOR_CLASS_KEY namespaced with FED_NAME suffix"
else
    fail "9: TIMELINE_CURSOR_CLASS_KEY namespacing missing"
fi

# --- #167: all four timeline controls structurally present. ---
t10_ok=1
for id in timeline-clear-stale-btn timeline-time-mode-btn timeline-auto-hide-stale timeline-chips; do
    if ! grep -q "id=\"$id\"" "$HTML_FILE"; then echo "  missing #$id"; t10_ok=0; fi
done
if [ "$t10_ok" -eq 1 ]; then
    pass "10: #167 controls (Clear stale, Time mode, Auto-hide, chips) present"
else
    fail "10: one or more #167 controls missing"
fi

# --- #167: TIMELINE_CLASSES constant lists every classified type so the
#     chip row stays in sync with the Python classifier. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'TIMELINE_CLASSES\s*=\s*\[([^\]]+)\]', html)
if not m: sys.exit(1)
required = {'emit', 'recv', 'suggest', 'error', 'action', 'finding'}
present = set(re.findall(r"'([a-z]+)'", m.group(1)))
sys.exit(0 if required.issubset(present) else 1)
PY
then
    pass "11: TIMELINE_CLASSES enumerates all six classifier outputs"
else
    fail "11: TIMELINE_CLASSES missing one or more classifier types"
fi

# --- #167: server-side per-agent agent_last_ok_ts field is emitted in the
#     embedded agents JSON. The fixture's stub_agent.log has two non-error
#     lines (raw-ms emit + corrupted action), so the field MUST be > 0 for
#     the stub-colony agent. Locate the agents=[...] payload and parse. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
data = json.loads(m.group(1))
stub = next((a for a in data.get('agents', []) if a.get('name') == 'stub_agent'), None)
if not stub: sys.exit(1)
# Field MUST be present (always-emitted contract).
if 'agent_last_ok_ts' not in stub: sys.exit(1)
# Fixture has a raw-ms emit line (1776250011452); last-ok must reflect it.
if stub['agent_last_ok_ts'] != 1776250011452: sys.exit(1)
sys.exit(0)
PY
then
    pass "12: agent_last_ok_ts emitted per agent and reflects newest non-error ts"
else
    fail "12: agent_last_ok_ts missing or wrong"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
