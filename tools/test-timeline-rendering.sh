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
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# #252: federation-dashboard extracted to a standalone component. Entry point
# moved from tools/federation-dashboard.sh to federation-dashboard/bin/...
# and the four Python helpers + template moved to federation-dashboard/lib/.
DASH_BIN_DIR="$REPO_ROOT/federation-dashboard/bin"
DASH_LIB_DIR="$REPO_ROOT/federation-dashboard/lib"
DASHBOARD_SH="$DASH_BIN_DIR/federation-dashboard"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
DASH_PID=""

# #1145: freeze a SINGLE wall-clock sample for the WHOLE suite. Every "now"
# baseline fed into experience/spend/lifecycle fixture rows, the collector,
# the timeline helper, and any date comparison derives from this one epoch —
# so no two reads can straddle 00:00 UTC within a single run (#1043). Reads
# used purely for uniqueness (e.g. %s%N sentinels) are intentionally not
# frozen.
SUITE_NOW="$(date '+%s')"

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
#     Post-#238, the dashboard resolves logs with fed-local-first
#     precedence: "$FED_DIR/.agentis/logs" → "$FED_DIR/../.agentis/logs"
#     → "./.agentis/logs". This fixture exercises the parent-level
#     fallback (no $FED_DIR/.agentis present), so the logs live at
#     $TMPDIR_TEST/.agentis/logs/ (one level above FED_DIR) and the
#     dashboard picks them up via the second arm of that precedence. ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.agentis/daemon" \
         "$TMPDIR_TEST/.agentis/logs" \
         "$TMPDIR_TEST/.agentis/experience" \
         "$TMPDIR_TEST/.agentis/spend" \
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

# #311 PR B: spend log fixture. Three rows in a now-anchored window so the
# today/7d/30d aggregations are non-zero. The orphan agent_id (no daemon
# registered) exercises the "no role mapping" path of collect_spend_log().
NOW_MS_FIX="$(python3 -c 'import time; print(int(time.time()*1000))')"
NOW_MS_T1=$((NOW_MS_FIX - 60000))
NOW_MS_T2=$((NOW_MS_FIX - 120000))
NOW_MS_T3=$((NOW_MS_FIX - 180000))
cat > "$TMPDIR_TEST/.agentis/spend/aaaaaaaa.jsonl" <<SPEND
{"v":1,"ts":$NOW_MS_T3,"agent":"aaaaaaaa","colony":"stub-colony","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":100,"output_tokens":50,"cost_usd":0.0123,"cost_source":"native","cb":50,"instr_hash":"deadbeef","cached":false,"ok":true}
{"v":1,"ts":$NOW_MS_T2,"agent":"aaaaaaaa","colony":"stub-colony","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":200,"output_tokens":80,"cost_usd":0.0234,"cost_source":"native","cb":50,"instr_hash":"cafebabe","cached":false,"ok":true}
{"v":1,"ts":$NOW_MS_T1,"agent":"aaaaaaaa","colony":"stub-colony","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":150,"output_tokens":60,"cost_usd":0.0143,"cost_source":"native","cb":50,"instr_hash":"feedface","cached":false,"ok":true}
SPEND

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

# --- Test 4: per-federation Clear button is rendered with the namespaced
#     id="timeline-clear-btn" so the JS click handler in renderEventTimeline
#     can wire `localStorage[TIMELINE_CURSOR_KEY] = now` without a stray-
#     selector miss. Resurrected in #362 iter5: the timeline UI moved to
#     its own "Logs & Events" tab and the host divs (chips, banner, clear-
#     btn, event-timeline) are back in the served HTML. ---
if grep -q 'id="timeline-clear-btn"' "$HTML_FILE"; then
    pass "4: timeline Clear button renders with id=\"timeline-clear-btn\" on Logs & Events tab"
else
    fail "4: timeline Clear button id missing — Logs & Events tab host divs likely not rendered"
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
#     timeline array literal in the JS source legitimately contains the raw
#     ms values (that's the JSON payload), so we restrict the check to
#     the JS that builds the row HTML — i.e. the timeline renderer body
#     must not contain a 13-digit standalone literal in a way that would
#     render in the row. We instead assert that the row template uses
#     formatTimestamp(<row>.ts), not bare <row>.ts string concatenation.
#     #315 PR 2: federation-wide timeline now iterates `r` over
#     data.timeline[]; pre-PR2 it was `e` over data.events[]. Accept both
#     names so this test stays useful across the refactor.
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Locate the timeline renderer: from "// --- Event Timeline ---" to the
# next "// --- " marker.
m = re.search(r'// --- Event Timeline ---(.*?)// --- ', html, re.DOTALL)
if not m:
    sys.exit(1)
body = m.group(1)
# Must reference formatTimestamp on the row var (`e` pre-PR2, `r` post).
if not re.search(r'formatTimestamp\(\s*[er]\.ts\s*\)', body):
    sys.exit(1)
# Defensive: ensure no naked '+ <row>.ts +' that would dump a 13-digit number.
if re.search(r'\+\s*[er]\.ts\s*\+', body):
    sys.exit(1)
sys.exit(0)
PY
then
    pass "6: timeline row template renders ts via formatTimestamp, no raw-ms leak"
else
    fail "6: rendered timeline row template still references ts directly"
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
#     timeline body works in epoch-ms (post-#158) and must divide by 1000
#     before passing to relTime. Recent Experience modal works in epoch-
#     seconds and must NOT divide. Lock both in to prevent the next
#     refactor from mixing units. #315 PR 2 renamed the timeline loop var
#     from `e` to `r`; accept both. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Timeline body must call relTime(<row>.ts / 1000) somewhere.
m = re.search(r'// --- Event Timeline ---(.*?)// --- ', html, re.DOTALL)
if not m:
    sys.exit(1)
timeline_body = m.group(1)
if not re.search(r'relTime\(\s*[er]\.ts\s*/\s*1000\s*\)', timeline_body):
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

# --- Test 10: kind-filter chip row renders with id="timeline-chips" so
#     renderEventTimeline can populate it with one button per
#     TIMELINE_KINDS entry. Resurrected in #362 iter5: the Logs & Events
#     tab re-introduces the chip host. Without the host the chip-toggle
#     persistence (`TIMELINE_CLASS_FILTER_KEY` per #167) silently no-ops. ---
if grep -q 'id="timeline-chips"' "$HTML_FILE"; then
    pass "10: timeline chip row renders with id=\"timeline-chips\" on Logs & Events tab"
else
    fail "10: timeline chip row host missing — Logs & Events tab not wired"
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

# --- #170: regression guard against re-introducing the macOS bash
#     heredoc-in-$() bug. The collector and server MUST live in
#     standalone Python files, not inline heredocs in the shell
#     script. Backticks in Python comments inside a `<<'PY'` heredoc
#     nested in $() get evaluated by macOS bash even with the single
#     quotes, leading to runtime "syntax error" on every collector
#     invocation. See #170 for the full diagnosis. ---
DASH_FILE="$DASH_BIN_DIR/federation-dashboard"
COLLECTOR_PY="$DASH_LIB_DIR/federation-dashboard-collector.py"
SERVER_PY="$DASH_LIB_DIR/federation-dashboard-server.py"
RENDERER_PY="$DASH_LIB_DIR/federation-dashboard-renderer.py"
HISTORY_PY="$DASH_LIB_DIR/federation-dashboard-history.py"
TEMPLATE_HTML="$DASH_LIB_DIR/federation-dashboard.html.template"

if [ -f "$COLLECTOR_PY" ] && python3 -c "import ast; ast.parse(open('$COLLECTOR_PY').read())" 2>/dev/null; then
    pass "13: federation-dashboard-collector.py exists and is valid Python (#170)"
else
    fail "13: federation-dashboard-collector.py missing or invalid"
fi

if [ -f "$SERVER_PY" ] && python3 -c "import ast; ast.parse(open('$SERVER_PY').read())" 2>/dev/null; then
    pass "14: federation-dashboard-server.py exists and is valid Python (#170)"
else
    fail "14: federation-dashboard-server.py missing or invalid"
fi

# No `<<'P` heredocs nested inside $(...) — that's the buggy pattern.
# A bare top-level `<<'PYHISTORY'` is fine (not nested in $()), so we
# scan only the few lines preceding each match for an unclosed `$(`.
if python3 - "$DASH_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Find every `<<'P...'` heredoc opener; for each, check whether the
# enclosing line (or the few lines before the opener) contains an
# unclosed `$(`. A simple heuristic: count `$(` minus `)` on the
# OPENING line — if positive, the heredoc is inside a $().
bad = []
for m in re.finditer(r"<<'P[A-Z]+'", src):
    line_start = src.rfind('\n', 0, m.start()) + 1
    line_end = src.find('\n', m.end())
    line = src[line_start:line_end if line_end >= 0 else len(src)]
    opens = line.count('$(')
    closes = line.count(')')
    if opens > closes:
        bad.append((line.strip()[:80], opens, closes))
if bad:
    for b in bad: print('  bad:', b, file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
then
    pass "15: no <<'P heredoc nested inside \$() in federation-dashboard.sh (#170)"
else
    fail "15: heredoc-in-\$() pattern detected — see #170 for why this breaks macOS"
fi

# --- #172: renderer.py + history.py + template extracted from the shell
#     script. The previous attempt at #170 only extracted Python heredocs
#     nested in $(); the JS/CSS/HTML heredocs that remained still tripped
#     the macOS bash 3.2 / 5.3 parser at line 962 (escaped single quote
#     inside <<'JSEOF'). #172 eliminates ALL heredocs from the shell. ---
if [ -f "$RENDERER_PY" ] && python3 -c "import ast; ast.parse(open('$RENDERER_PY').read())" 2>/dev/null; then
    pass "16: federation-dashboard-renderer.py exists and is valid Python (#172)"
else
    fail "16: federation-dashboard-renderer.py missing or invalid"
fi

if [ -f "$HISTORY_PY" ] && python3 -c "import ast; ast.parse(open('$HISTORY_PY').read())" 2>/dev/null; then
    pass "17: federation-dashboard-history.py exists and is valid Python (#172)"
else
    fail "17: federation-dashboard-history.py missing or invalid"
fi

# Template must exist and contain ALL 10 sentinels the renderer substitutes,
# otherwise the rendered page would silently render the literal sentinel
# text (e.g. "{{FED_NAME}}") instead of the federation name.
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys
required = {
    '{{FED_NAME}}', '{{FED_NAME_JS}}', '{{COLONY_COUNT}}', '{{AGENT_COUNT}}',
    '{{COLLECTOR_JSON}}', '{{HISTORY}}', '{{REMEDIATION}}',
    '{{COLONY_LIST_JS}}', '{{EPOCH}}', '{{TIMESTAMP}}',
}
with open(sys.argv[1]) as f:
    src = f.read()
missing = [s for s in required if s not in src]
sys.exit(1 if missing else 0)
PY
then
    pass "18: template contains all 10 named sentinels expected by renderer.py (#172)"
else
    fail "18: template missing one or more renderer sentinels"
fi

# Hard guard: ZERO heredocs of any kind in federation-dashboard.sh. After
# #172 every multi-line content block lives in a standalone file. New
# heredocs are forbidden because the macOS bash 3.2 / 5.3 parser is too
# fragile to trust with any content longer than a few lines (the previous
# bug at line 962 was triggered by a single \' inside a quoted heredoc).
if python3 - "$DASH_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Match shell-style heredoc openers: optional whitespace, then `<<` with
# optional `-`, then optionally-quoted delimiter. We strip line-comments
# first so a comment that mentions "<<'JSEOF'" doesn't trip the guard.
no_comments = re.sub(r'(?m)^\s*#.*$', '', src)
no_comments = re.sub(r'#.*$', '', no_comments, flags=re.MULTILINE)
matches = re.findall(r'<<-?\s*(?:[A-Za-z_][A-Za-z0-9_]*|\'[^\']+\'|"[^"]+")', no_comments)
sys.exit(1 if matches else 0)
PY
then
    pass "19: federation-dashboard.sh contains zero heredocs of any kind (#172)"
else
    fail "19: heredoc detected — extract content to a standalone file (see #172)"
fi

# --- #248 PR B QA finding #1 regression guard ---
# The confidence-log JSONL writer (federation-dashboard-server.py:494) writes
# rows with field name `t`. The PR B "Learning // 24h" code originally read
# `c.ts` instead — a one-char typo that silently zeroed the conf-moves count.
# Lock the contract: the template must reference `c.t`, never `c.ts`, when
# walking confChanges entries.
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Forbid `confChanges.filter(c => (c.ts` and similar c.ts reads.
# Allow c.t reads. Match against the JS body inside <script>...</script>.
m = re.search(r'<script>(.*?)</script>', src, re.DOTALL)
js = m.group(1) if m else src
# Look for any `c.ts` (word-boundary right) on a confChanges-related line.
# We're conservative: flag any c.ts read in the JS body that's not c.tsv etc.
bad = re.findall(r'\bc\.ts\b', js)
sys.exit(1 if bad else 0)
PY
then
    pass "20: template uses c.t (not c.ts) for confChanges entries (#248 PR B)"
else
    fail "20: template references c.ts on confChanges — server writes c.t, see #248 PR B QA #1"
fi

# --- #163: evolve flat-slope threshold is named, reachable, and calibrated.
#     Guards against reverting to the pre-calibration 1e-6 guess or silently
#     orphaning the constant (declared but never used). The production
#     calibration in #163 picked 1e-4 as the natural separator between the
#     true-plateau cluster (|slope| <= 1e-5) and the oscillation cluster
#     (|slope| >= 1e-4). ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
m = re.search(r'const\s+SLOPE_FLAT_THRESHOLD\s*=\s*([0-9eE.+\-]+)\s*;', src)
if not m: sys.exit(1)
value = float(m.group(1))
# Must equal the calibrated value (not the pre-calibration 1e-6).
if abs(value - 1e-4) > 1e-12: sys.exit(2)
# Must actually be referenced (no orphaned constant).
if 'SLOPE_FLAT_THRESHOLD' not in src[m.end():]: sys.exit(3)
# Legacy literal must no longer guard the flat-slope branch.
if re.search(r'Math\.abs\(\s*f\.slope\s*\)\s*<\s*1e-6\b', src): sys.exit(4)
sys.exit(0)
PY
then
    pass "21: SLOPE_FLAT_THRESHOLD defined as 1e-4, referenced, no leftover 1e-6 guard (#163)"
else
    fail "21: SLOPE_FLAT_THRESHOLD missing, wrong value, orphaned, or 1e-6 guard survived (#163)"
fi

# --- #362 iter5 + #865 + #869 test 22: 6-tab cut — exactly 6 <section data-tab="...">
#     blocks in the order status / analytics / cost / recovery / logs /
#     config. iter4 was 4-tab (no Logs); iter5 resurrects Event Timeline
#     as its own tab; #865 added Analytics; #869 promoted Analytics to
#     position 2 (right after Status) so it isn't tucked after Config. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
expected = ['status', 'analytics', 'cost', 'recovery', 'logs', 'config']
found = [m for m in re.findall(r'<section\s+data-tab="([^"]+)"', src) if m != '...']
if found != expected:
    sys.stderr.write('section data-tab order/contents wrong: %r vs expected %r\n' % (found, expected))
    sys.exit(1)
# Negative-assert: progress section is gone.
if '<section data-tab="progress"' in src:
    sys.stderr.write('progress section still present (should be deleted in #362)\n')
    sys.exit(2)
sys.exit(0)
PY
then
    pass "22: 6-tab cut — exactly 6 <section data-tab=\"...\"> blocks (status / analytics / cost / recovery / logs / config) (#362 iter5 + #865 + #869)"
else
    fail "22: 6-tab section count or order wrong (#362 iter5 + #865 + #869 expect status / analytics / cost / recovery / logs / config)"
fi

# --- #362 iter5 + #865 + #869 test 23: 6-tab bar emits exactly 6 buttons;
#     no data-tab="progress". Analytics is in 2nd position (#869), Logs
#     & Events is in 5th. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
expected = ['status', 'analytics', 'cost', 'recovery', 'logs', 'config']
buttons = re.findall(r'<button\s+class="tab-btn"\s+role="tab"\s+data-tab="([^"]+)"', src)
if buttons != expected:
    sys.stderr.write('tab-btn data-tab order wrong: %r vs expected %r\n' % (buttons, expected))
    sys.exit(1)
# Negative-assert: progress button is gone.
if 'data-tab="progress"' in src:
    sys.stderr.write('Progress tab button still present (#362 deletes it)\n')
    sys.exit(2)
sys.exit(0)
PY
then
    pass "23: 6-tab bar emits exactly 6 buttons; no data-tab=\"progress\" (#362 iter5 + #865 + #869)"
else
    fail "23: tab bar buttons missing or out of order (#362 iter5 + #865 + #869 expect 6: status / analytics / cost / recovery / logs / config)"
fi

# --- #257: federation-agnostic vocabulary regression guard. ---
# The dashboard ships as a separately-versioned standalone component and
# auto-discovers colonies; nothing in the UI or server code may hard-code
# forge-specific vocabulary (GitLab, GITLAB_*, MRs, "merge request"). The
# only permitted GitLab references are historical comments inside
# server.py that explain what was removed in #257 — those strings live
# inside comment lines and do not leak into rendered text.
t24_ok=1
# 24a: HTML template must not mention GitLab / MRs anywhere.
for pat in GitLab MRs 'merge request' GITLAB_; do
    if grep -q -- "$pat" "$DASH_LIB_DIR/federation-dashboard.html.template"; then
        echo "  template contains forbidden term: $pat"
        t24_ok=0
    fi
done
# 24b: server.py must not dispatch on any GitLab env var at runtime. The
# only tolerated occurrences are inside Python comments (leading whitespace
# then '#') explaining the pre-#257 history.
if python3 - "$DASH_LIB_DIR/federation-dashboard-server.py" <<'PY' 2>/dev/null
import sys
bad = []
with open(sys.argv[1]) as f:
    for i, line in enumerate(f, 1):
        stripped = line.lstrip()
        if stripped.startswith('#') or stripped.startswith('"""'):
            continue
        for term in ('GITLAB_URL', 'GITLAB_TOKEN', 'GITLAB_PROJECT', 'GITLAB_ME'):
            if term in line:
                bad.append((i, term, line.rstrip()))
if bad:
    for i, t, l in bad[:5]:
        sys.stderr.write(f'line {i}: {t}: {l}\n')
    sys.exit(1)
sys.exit(0)
PY
then
    :
else
    echo "  server.py contains non-comment GitLab env references"
    t24_ok=0
fi
if [ "$t24_ok" -eq 1 ]; then
    pass "24: federation-agnostic vocabulary — no GitLab-specific terms in template or runtime server code (#257)"
else
    fail "24: forge-vocabulary regression — see lines above"
fi

# --- #276 / #362: per-agent promotion forecast (template wiring + algorithm) ---
# Two checks: (a) the template carries the JS render branch keyed on
# evidence.forecast_days_to_next_tier (now in renderStatusAgentTable's
# ETA column after #362, replaces the deleted Promote Candidates badge);
# (b) the linear-regression projection embedded in federation-dashboard-
# collector.py yields a positive forecast in the [3.5, 4.5] day band for
# a 5-point colony series climbing 0.60 → 0.65 over 1 hour at confidence
# 0.62 → next-tier 0.80, and yields null for a flat / declining series.
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys
with open(sys.argv[1]) as f:
    src = f.read()
needles = ['forecast_days_to_next_tier', "'d'", 'function renderStatusAgentTable']
for n in needles:
    if n not in src:
        sys.stderr.write('template missing forecast wiring: ' + n + '\n')
        sys.exit(2)
sys.exit(0)
PY
then
    pass "25a: template wires forecast JS render branch in per-agent table ETA column (#276 / #362)"
else
    fail "25a: forecast template wiring missing"
fi

# Replicate the collector's linreg algorithm against a synthetic series so
# this test stays fully hermetic (no daemon list, no auto-promote-decisions
# subprocess). The expected band [3.5, 4.5] follows from a slow colony
# climb (0.6000 → 0.6019 over 1h) projected against a 0.18 delta to the
# 0.80 tier from a 0.62-confidence agent (~4.0 days at slope ~5.2e-7/s).
if python3 - <<'PY' 2>/dev/null
import sys
def slope(pts):
    n = len(pts)
    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sxy = sum(p[0]*p[1] for p in pts)
    sx2 = sum(p[0]*p[0] for p in pts)
    denom = n*sx2 - sx*sx
    if denom == 0 or n < 3:
        return None
    return (n*sxy - sx*sy) / denom
# 5 points spanning 1h. Slow rise calibrated to land in the [3.5, 4.5] day
# band when projected from confidence 0.62 to the next-tier target 0.80.
rising = [(i*900.0, 0.6000 + 0.0019*i/4.0) for i in range(5)]
m = slope(rising)
if m is None or m <= 0:
    sys.stderr.write('positive slope expected, got %r\n' % m); sys.exit(2)
days = ((0.80 - 0.62) / m) / 86400.0
if not (3.5 <= days <= 4.5):
    sys.stderr.write('days out of band: %.3f\n' % days); sys.exit(3)
# Negative case: declining slope → forecast null (slope <= 0 short-circuit).
falling = [(i*900.0, 0.65 - 0.05*i/4.0) for i in range(5)]
mf = slope(falling)
if mf is None or mf > 0:
    sys.stderr.write('negative slope expected, got %r\n' % mf); sys.exit(4)
# Sub-3-points history collapses to None.
if slope([(0.0, 0.6), (60.0, 0.61)]) is not None:
    sys.stderr.write('len<3 should yield None\n'); sys.exit(5)
sys.exit(0)
PY
then
    pass "25b: forecast algorithm — rising series projects ~3.7d (in [3.5, 4.5]); flat/declining → null (#276)"
else
    fail "25b: forecast algorithm regression — see stderr above"
fi

# --- #311 PR B: LLM Cost tile structurally present + headline numbers ---
# (a) Tile is wired in HTML (h2 + container div + JS renderer).
# (b) `cost` block is emitted in COLLECTOR_JSON and headline values match
#     the spend-log fixture above (sum of three rows = 0.0500).
t26_ok=1
if ! grep -q 'id="llm-cost"' "$HTML_FILE"; then echo "  missing #llm-cost container"; t26_ok=0; fi
if ! grep -q '>LLM Cost</h2>' "$HTML_FILE"; then echo "  missing 'LLM Cost' h2"; t26_ok=0; fi
if ! grep -q 'cost-headline' "$HTML_FILE"; then echo "  missing cost-headline class"; t26_ok=0; fi
if [ "$t26_ok" -eq 1 ]; then
    pass "26: LLM Cost tile structurally present (container, h2, headline class) (#311 PR B)"
else
    fail "26: LLM Cost tile missing one or more structural elements"
fi

# Cost block in COLLECTOR_JSON: parse the embedded JSON and assert the
# windowed totals match the fixture sum (0.0123 + 0.0234 + 0.0143 = 0.0500).
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
data = json.loads(m.group(1))
cost = data.get('cost')
if not isinstance(cost, dict):
    sys.stderr.write('cost block missing\n'); sys.exit(2)
fed = cost.get('federation') or {}
# Allow tiny float rounding (round to 4 decimal places in collector).
expected = 0.0500
for k in ('today', 'week', 'month'):
    v = fed.get(k)
    if not isinstance(v, (int, float)):
        sys.stderr.write('federation.%s not numeric: %r\n' % (k, v)); sys.exit(3)
    if abs(v - expected) > 1e-3:
        sys.stderr.write('federation.%s = %r, expected ~%r\n' % (k, v, expected)); sys.exit(4)
# Sparkline arrays exist + correct length.
if len(cost.get('sparkline_24h') or []) != 24: sys.exit(5)
if len(cost.get('sparkline_30d') or []) != 30: sys.exit(6)
# Currency + table_pin_date metadata exposed.
if cost.get('currency') != 'USD': sys.exit(7)
if not cost.get('table_pin_date'): sys.exit(8)
# Per-agent injection: each agent record has cost_today / 7d / 30d fields
# (always present, default 0.0 when no spend data for that agent).
for a in data.get('agents', []):
    for k in ('cost_today', 'cost_7d', 'cost_30d'):
        if k not in a: sys.stderr.write('agent missing %s\n' % k); sys.exit(9)
sys.exit(0)
PY
then
    pass "27: cost block emitted with today/7d/30d ~= 0.0500, sparklines + per-agent fields (#311 PR B)"
else
    fail "27: cost block aggregations / per-agent injection regressed — see stderr above"
fi

# --- #315 PR 1: per-agent unified timeline injection. Drives the collector
#     directly against a synthetic fixture (no second dashboard boot) and
#     asserts each agent record carries a non-empty `timeline[]` field
#     containing rows from at least 2 of the 4 sources (experience, spend,
#     confidence-log, lifecycle). Fixture lives at /tmp/qa-315-fed/ per the
#     plan in #315 PR 1. ---
QA_FED="/tmp/qa-315-fed"
COLLECTOR_PY="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"
rm -rf "$QA_FED"
mkdir -p "$QA_FED/.agentis/experience" \
         "$QA_FED/.agentis/spend" \
         "$QA_FED/.agentis/lifecycle" \
         "$QA_FED/.dashboard" \
         "$QA_FED/qa-colony/agents" \
         "$QA_FED/qa-colony/config"
cat > "$QA_FED/qa-colony/config/colony.toml" <<'TOML'
[colony]
name = "qa-colony"
TOML
cat > "$QA_FED/qa-colony/agents/qa_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

QA_AID="bbbbbbbb"
QA_NOW="$SUITE_NOW"
QA_NOW_MS=$((QA_NOW * 1000))

# 1 experience row (epoch-SECONDS, mirroring agentis-core's writer).
cat > "$QA_FED/.agentis/experience/$QA_AID.jsonl" <<EXP
{"v":1,"ts":$((QA_NOW - 30)),"agent":"$QA_AID","action":"draft","in":"MR 281","outcome":"success","delta":0.150}
EXP

# 1 spend row (epoch-MS, mirroring agentis-core's spend writer).
cat > "$QA_FED/.agentis/spend/$QA_AID.jsonl" <<SPEND
{"v":1,"ts":$((QA_NOW_MS - 60000)),"agent":"$QA_AID","colony":"qa-colony","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":120,"output_tokens":40,"cost_usd":0.0150,"cost_source":"native","cb":50,"instr_hash":"deadbeef","cached":false,"ok":true}
SPEND

# 1 lifecycle event (epoch-SECONDS, mirroring agentis-core's daemon writer).
cat > "$QA_FED/.agentis/lifecycle/events.jsonl" <<LIFE
{"agent_id":"$QA_AID","event":"daemon.started","cb_per_tick":2000,"tick_interval_ms":60000,"ts":$((QA_NOW - 90))}
LIFE

# Synthetic daemon entry so the collector resolves agent_id -> rec for our
# fixture agent. `source` path mapping to qa_agent.ag wires the role-to-id.
QA_DAEMONS=$(python3 -c "
import json
print(json.dumps([{
    'agent_id': '$QA_AID',
    'source':   '$QA_FED/qa-colony/agents/qa_agent.ag',
    'state':    'running',
    'health':   'healthy',
    'pid':      0,
    'confidence': 0.5,
    'tick_ok': 1,
    'tick_err': 0,
    'started_at': $QA_NOW - 100,
}]))
")
QA_AGENT_MAP='[{"agent":"qa_agent","colony":"qa-colony"}]'
QA_COLONIES='["qa-colony"]'

QA_JSON="$(python3 "$COLLECTOR_PY" \
    "$QA_DAEMONS" \
    "$QA_AGENT_MAP" \
    "$QA_FED" \
    "$QA_NOW" \
    "$QA_FED/.agentis/experience" \
    "$QA_FED/.agentis/logs" \
    "$QA_FED/.dashboard" \
    "$QA_COLONIES" \
    "" \
    qa_agent 2>/dev/null)"

t28_ok=1
if [ -z "$QA_JSON" ]; then
    echo "  collector returned empty output"
    t28_ok=0
elif ! python3 - <<PY 2>&1
import json, sys
blob = json.loads('''$QA_JSON''')
agents = blob.get('agents') or []
if not agents:
    sys.stderr.write('no agents in collector output\n'); sys.exit(2)
agent = next((a for a in agents if a.get('name') == 'qa_agent'), None)
if agent is None:
    sys.stderr.write('qa_agent not found in agents array\n'); sys.exit(3)
tl = agent.get('timeline')
if not isinstance(tl, list):
    sys.stderr.write('timeline missing or not a list: %r\n' % type(tl)); sys.exit(4)
if len(tl) == 0:
    sys.stderr.write('timeline is empty\n'); sys.exit(5)
kinds = set(r.get('kind') for r in tl)
# At least 2 of {learn, prompt, lifecycle, confidence_change} must be present.
expected = {'learn', 'prompt', 'lifecycle', 'confidence_change'}
overlap = kinds & expected
if len(overlap) < 2:
    sys.stderr.write('only %d source(s) merged, need >= 2: %r\n' % (len(overlap), kinds)); sys.exit(6)
# Verify reverse-chronological order (newest first).
ts_seq = [r.get('ts') for r in tl if isinstance(r.get('ts'), int)]
if ts_seq != sorted(ts_seq, reverse=True):
    sys.stderr.write('timeline not sorted ts-desc: %r\n' % ts_seq); sys.exit(7)
# Verify shape: each row has ts, agent_id, kind, payload, severity.
for r in tl:
    for k in ('ts', 'agent_id', 'kind', 'payload', 'severity'):
        if k not in r:
            sys.stderr.write('row missing %s: %r\n' % (k, r)); sys.exit(8)
sys.exit(0)
PY
then
    t28_ok=0
fi
if [ "$t28_ok" -eq 1 ]; then
    pass "28: per-agent timeline[] populated from >=2 sources, ts-desc sorted, normalized shape (#315 PR 1)"
else
    fail "28: per-agent timeline injection regressed — see stderr above"
fi
rm -rf "$QA_FED"

# --- #315 PR 2: federation-wide unified timeline + /timeline endpoint.
#     Build a 3-agent fixture so we can assert the merged stream contains
#     rows from multiple agents, ts-desc sorted, capped at 200. Then boot
#     the dashboard against the same fixture and smoke /timeline with
#     pagination + colony filtering. ---
QA_FED2="/tmp/qa-315-pr2-fed"
COLLECTOR_PY="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"
rm -rf "$QA_FED2"
mkdir -p "$QA_FED2/.agentis/experience" \
         "$QA_FED2/.agentis/spend" \
         "$QA_FED2/.agentis/lifecycle" \
         "$QA_FED2/.dashboard" \
         "$QA_FED2/colony-a/agents" \
         "$QA_FED2/colony-a/config" \
         "$QA_FED2/colony-b/agents" \
         "$QA_FED2/colony-b/config"
cat > "$QA_FED2/colony-a/config/colony.toml" <<'TOML'
[colony]
name = "colony-a"
TOML
cat > "$QA_FED2/colony-b/config/colony.toml" <<'TOML'
[colony]
name = "colony-b"
TOML

# Three agents: agent_a1, agent_a2 in colony-a; agent_b1 in colony-b.
for ag_pair in colony-a/agents/agent_a1.ag colony-a/agents/agent_a2.ag colony-b/agents/agent_b1.ag; do
    cat > "$QA_FED2/$ag_pair" <<'AG'
cb 100;
fn tick() { return Void; }
AG
done

QA_AID_A1="aaaaaaa1"
QA_AID_A2="aaaaaaa2"
QA_AID_B1="bbbbbbb1"
QA_NOW2="$SUITE_NOW"
QA_NOW2_MS=$((QA_NOW2 * 1000))

# Each agent gets >=1 experience row + >=1 spend row + >=1 lifecycle row,
# so the merged feed carries rows from all three. Stagger ts so the desc
# sort is observable.
cat > "$QA_FED2/.agentis/experience/$QA_AID_A1.jsonl" <<EXP
{"v":1,"ts":$((QA_NOW2 - 300)),"agent":"$QA_AID_A1","action":"draft","in":"MR 1","outcome":"success","delta":0.05}
{"v":1,"ts":$((QA_NOW2 - 200)),"agent":"$QA_AID_A1","action":"draft","in":"MR 2","outcome":"success","delta":0.10}
EXP
cat > "$QA_FED2/.agentis/experience/$QA_AID_A2.jsonl" <<EXP
{"v":1,"ts":$((QA_NOW2 - 250)),"agent":"$QA_AID_A2","action":"review","in":"MR 3","outcome":"failure","delta":-0.02}
EXP
cat > "$QA_FED2/.agentis/experience/$QA_AID_B1.jsonl" <<EXP
{"v":1,"ts":$((QA_NOW2 - 150)),"agent":"$QA_AID_B1","action":"merge","in":"MR 4","outcome":"success","delta":0.20}
EXP

cat > "$QA_FED2/.agentis/spend/$QA_AID_A1.jsonl" <<SPEND
{"v":1,"ts":$((QA_NOW2_MS - 280000)),"agent":"$QA_AID_A1","colony":"colony-a","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":100,"output_tokens":50,"cost_usd":0.0123,"cost_source":"native","cb":50,"instr_hash":"deadbeef","cached":false,"ok":true}
SPEND
cat > "$QA_FED2/.agentis/spend/$QA_AID_A2.jsonl" <<SPEND
{"v":1,"ts":$((QA_NOW2_MS - 220000)),"agent":"$QA_AID_A2","colony":"colony-a","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":120,"output_tokens":60,"cost_usd":0.0150,"cost_source":"native","cb":50,"instr_hash":"cafebabe","cached":false,"ok":true}
SPEND
cat > "$QA_FED2/.agentis/spend/$QA_AID_B1.jsonl" <<SPEND
{"v":1,"ts":$((QA_NOW2_MS - 100000)),"agent":"$QA_AID_B1","colony":"colony-b","backend":"claude-cli","model":"claude-sonnet-4-20250514","input_tokens":150,"output_tokens":70,"cost_usd":0.0180,"cost_source":"native","cb":50,"instr_hash":"feedface","cached":false,"ok":true}
SPEND

cat > "$QA_FED2/.agentis/lifecycle/events.jsonl" <<LIFE
{"agent_id":"$QA_AID_A1","event":"daemon.started","cb_per_tick":2000,"tick_interval_ms":60000,"ts":$((QA_NOW2 - 350))}
{"agent_id":"$QA_AID_A2","event":"daemon.started","cb_per_tick":2000,"tick_interval_ms":60000,"ts":$((QA_NOW2 - 340))}
{"agent_id":"$QA_AID_B1","event":"daemon.started","cb_per_tick":2000,"tick_interval_ms":60000,"ts":$((QA_NOW2 - 330))}
LIFE

QA_DAEMONS2=$(python3 -c "
import json
print(json.dumps([
  {'agent_id':'$QA_AID_A1','source':'$QA_FED2/colony-a/agents/agent_a1.ag','state':'running','health':'healthy','pid':0,'confidence':0.5,'tick_ok':1,'tick_err':0,'started_at':$QA_NOW2 - 400},
  {'agent_id':'$QA_AID_A2','source':'$QA_FED2/colony-a/agents/agent_a2.ag','state':'running','health':'healthy','pid':0,'confidence':0.5,'tick_ok':1,'tick_err':0,'started_at':$QA_NOW2 - 400},
  {'agent_id':'$QA_AID_B1','source':'$QA_FED2/colony-b/agents/agent_b1.ag','state':'running','health':'healthy','pid':0,'confidence':0.5,'tick_ok':1,'tick_err':0,'started_at':$QA_NOW2 - 400},
]))
")
QA_AGENT_MAP2='[{"agent":"agent_a1","colony":"colony-a"},{"agent":"agent_a2","colony":"colony-a"},{"agent":"agent_b1","colony":"colony-b"}]'
QA_COLONIES2='["colony-a","colony-b"]'

QA_JSON2="$(python3 "$COLLECTOR_PY" \
    "$QA_DAEMONS2" \
    "$QA_AGENT_MAP2" \
    "$QA_FED2" \
    "$QA_NOW2" \
    "$QA_FED2/.agentis/experience" \
    "$QA_FED2/.agentis/logs" \
    "$QA_FED2/.dashboard" \
    "$QA_COLONIES2" \
    "" \
    agent_a1 agent_a2 agent_b1 2>/dev/null)"

t30_ok=1
if [ -z "$QA_JSON2" ]; then
    echo "  collector returned empty output"
    t30_ok=0
elif ! python3 - <<PY 2>&1
import json, sys
blob = json.loads('''$QA_JSON2''')
tl = blob.get('timeline')
if not isinstance(tl, list):
    sys.stderr.write('federation-wide timeline missing or not a list: %r\n' % type(tl)); sys.exit(2)
if len(tl) == 0:
    sys.stderr.write('federation-wide timeline is empty\n'); sys.exit(3)
if len(tl) > 200:
    sys.stderr.write('federation-wide timeline exceeds 200-row cap: %d\n' % len(tl)); sys.exit(4)
# ts-desc sort.
ts_seq = [r.get('ts') for r in tl if isinstance(r.get('ts'), int)]
if ts_seq != sorted(ts_seq, reverse=True):
    sys.stderr.write('federation-wide timeline not ts-desc sorted: %r\n' % ts_seq[:10]); sys.exit(5)
# Rows from MULTIPLE agents — at least 2 distinct agent_ids must appear.
aids = set(r.get('agent_id') for r in tl)
if len(aids) < 2:
    sys.stderr.write('only one agent in federation timeline: %r\n' % aids); sys.exit(6)
# Augmentation: every row carries agent_name + colony.
for r in tl:
    if 'agent_name' not in r or 'colony' not in r:
        sys.stderr.write('row missing agent_name/colony: %r\n' % r); sys.exit(7)
# Per-agent timelines also still populated (PR1 contract preserved).
for a in blob.get('agents') or []:
    if not isinstance(a.get('timeline'), list):
        sys.stderr.write('per-agent timeline regression on %s\n' % a.get('name')); sys.exit(8)
sys.exit(0)
PY
then
    t30_ok=0
fi
if [ "$t30_ok" -eq 1 ]; then
    pass "30: data.timeline[] federation-wide field exists, ts-desc, capped at 200, multi-agent (#315 PR 2)"
else
    fail "30: federation-wide timeline assertion failed — see stderr above"
fi

# --- t31 / t32: HTTP smoke against /timeline endpoint. We boot
#     federation-dashboard-server.py directly (NOT the wrapper) against a
#     hand-written timeline-full.jsonl in the dashboard cache dir.
#     Booting the wrapper would shell out to `agentis daemon list --json`
#     which hits the global registry and returns daemons unrelated to the
#     fixture — causing the wrapper's timeline regen to write zero rows.
#     The server endpoint contract is "read timeline-full.jsonl from
#     <dash-dir>"; we exercise that contract directly. ---
DASH_DIR2="$QA_FED2/.dashboard"
TIMELINE_FULL2="$DASH_DIR2/timeline-full.jsonl"
# Hand-write 9 rows: 3 per agent × 3 agents, ts-desc.
python3 - <<PY
import json, os, time
out = "$TIMELINE_FULL2"
QA_NOW2_MS = $((QA_NOW2 * 1000))
rows = [
  # colony-a, agent_a1
  {"ts": QA_NOW2_MS - 200000, "agent_id": "aaaaaaa1", "kind": "learn",
   "payload": {"outcome": "success", "delta": 0.10}, "severity": "info",
   "agent_name": "agent_a1", "colony": "colony-a"},
  {"ts": QA_NOW2_MS - 280000, "agent_id": "aaaaaaa1", "kind": "prompt",
   "payload": {"cost_usd": 0.0123, "input_tokens": 100, "output_tokens": 50,
               "model": "claude-sonnet-4-20250514", "ok": True}, "severity": "info",
   "agent_name": "agent_a1", "colony": "colony-a"},
  {"ts": QA_NOW2_MS - 350000, "agent_id": "aaaaaaa1", "kind": "lifecycle",
   "payload": {"event": "daemon.started"}, "severity": "info",
   "agent_name": "agent_a1", "colony": "colony-a"},
  # colony-a, agent_a2
  {"ts": QA_NOW2_MS - 250000, "agent_id": "aaaaaaa2", "kind": "learn",
   "payload": {"outcome": "failure", "delta": -0.02}, "severity": "error",
   "agent_name": "agent_a2", "colony": "colony-a"},
  {"ts": QA_NOW2_MS - 220000, "agent_id": "aaaaaaa2", "kind": "prompt",
   "payload": {"cost_usd": 0.0150, "input_tokens": 120, "output_tokens": 60,
               "model": "claude-sonnet-4-20250514", "ok": True}, "severity": "info",
   "agent_name": "agent_a2", "colony": "colony-a"},
  {"ts": QA_NOW2_MS - 340000, "agent_id": "aaaaaaa2", "kind": "lifecycle",
   "payload": {"event": "daemon.started"}, "severity": "info",
   "agent_name": "agent_a2", "colony": "colony-a"},
  # colony-b, agent_b1
  {"ts": QA_NOW2_MS - 150000, "agent_id": "bbbbbbb1", "kind": "learn",
   "payload": {"outcome": "success", "delta": 0.20}, "severity": "info",
   "agent_name": "agent_b1", "colony": "colony-b"},
  {"ts": QA_NOW2_MS - 100000, "agent_id": "bbbbbbb1", "kind": "prompt",
   "payload": {"cost_usd": 0.0180, "input_tokens": 150, "output_tokens": 70,
               "model": "claude-sonnet-4-20250514", "ok": True}, "severity": "info",
   "agent_name": "agent_b1", "colony": "colony-b"},
  {"ts": QA_NOW2_MS - 330000, "agent_id": "bbbbbbb1", "kind": "lifecycle",
   "payload": {"event": "daemon.started"}, "severity": "info",
   "agent_name": "agent_b1", "colony": "colony-b"},
]
rows.sort(key=lambda r: r["ts"], reverse=True)
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    for r in rows:
        f.write(json.dumps(r, separators=(",", ":")))
        f.write("\n")
PY

PORT2="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)")"
LOG2="$TMPDIR_TEST/server-pr2.log"
SERVER_PY_PR2="$DASH_LIB_DIR/federation-dashboard-server.py"
# Direct server boot. Args: serve_dir, port, script_path, fed_dir,
# allowed_agents, agent_map_json, fed_tools_dir.
setsid python3 "$SERVER_PY_PR2" "$DASH_DIR2" "$PORT2" \
    "$DASHBOARD_SH" "$QA_FED2" \
    "agent_a1,agent_a2,agent_b1" "$QA_AGENT_MAP2" "" \
    >"$LOG2" 2>&1 &
DASH_PID2=$!

ready2=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -f -s -o /dev/null "http://127.0.0.1:$PORT2/timeline?limit=1" 2>/dev/null; then
        ready2=1
        break
    fi
    sleep 0.5
done
if [ "$ready2" -ne 1 ]; then
    fail "31/32: server-pr2 never became ready" "log tail: $(tail -10 "$LOG2" 2>/dev/null | tr '\n' ' ')"
    kill -TERM "-$DASH_PID2" 2>/dev/null || kill -TERM "$DASH_PID2" 2>/dev/null || true
    rm -rf "$QA_FED2"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- t31: /timeline?since=<future-ms>&limit=10 returns rows + next_cursor.
#     The fixture has ~9 timeline-eligible rows (3 exp + 3 spend + 3 lifecycle
#     after the 7-day window filter), but the contract is "returns up to limit
#     rows with non-null next_cursor when more remain". Use limit=5 so we
#     reliably get a non-null next_cursor. ---
FUTURE_MS=$(( ( QA_NOW2 + 3600 ) * 1000 ))
TL_RESP="$TMPDIR_TEST/timeline.json"
curl -s "http://127.0.0.1:$PORT2/timeline?since=$FUTURE_MS&limit=5" -o "$TL_RESP" || true
if python3 - "$TL_RESP" <<'PY' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
assert isinstance(data, dict), 'response is not a dict'
rows = data.get('rows')
assert isinstance(rows, list), 'rows is not a list: %r' % type(rows)
# At least 1 row from the 9-row fixture + limit cap respected.
if len(rows) == 0:
    sys.stderr.write('no rows returned by /timeline\n'); sys.exit(2)
if len(rows) > 5:
    sys.stderr.write('rows exceeds limit=5: %d\n' % len(rows)); sys.exit(3)
# ts-desc sort within the response.
ts_seq = [r.get('ts') for r in rows]
if ts_seq != sorted(ts_seq, reverse=True):
    sys.stderr.write('rows not ts-desc: %r\n' % ts_seq); sys.exit(4)
# next_cursor non-null because the fixture has more rows than limit=5.
if data.get('next_cursor') is None:
    sys.stderr.write('next_cursor is null but more rows should remain\n'); sys.exit(5)
sys.exit(0)
PY
then
    pass "31: /timeline?since=<future>&limit=5 returns rows ts-desc with non-null next_cursor (#315 PR 2)"
else
    fail "31: /timeline pagination smoke regressed — body: $(head -c 400 "$TL_RESP" 2>/dev/null)"
fi

# --- t32: /timeline?colony=<name> filters correctly. colony-b has only
#     agent_b1, which contributes 3 rows (1 exp + 1 spend + 1 lifecycle). ---
TL_RESP_B="$TMPDIR_TEST/timeline-b.json"
curl -s "http://127.0.0.1:$PORT2/timeline?colony=colony-b&since=$FUTURE_MS&limit=200" -o "$TL_RESP_B" || true
if python3 - "$TL_RESP_B" <<'PY' 2>/dev/null
import sys, json
with open(sys.argv[1]) as f:
    data = json.load(f)
rows = data.get('rows') or []
if not rows:
    sys.stderr.write('no rows returned for colony=colony-b\n'); sys.exit(2)
# Every row must carry colony=colony-b.
for r in rows:
    if r.get('colony') != 'colony-b':
        sys.stderr.write('row leaked from another colony: %r\n' % r); sys.exit(3)
# Same agent_id across all rows (only agent_b1 in colony-b).
aids = set(r.get('agent_id') for r in rows)
if aids != {'bbbbbbb1'}:
    sys.stderr.write('unexpected agents under colony-b filter: %r\n' % aids); sys.exit(4)
sys.exit(0)
PY
then
    pass "32: /timeline?colony=colony-b returns only colony-b rows (#315 PR 2)"
else
    fail "32: /timeline colony filter regressed — body: $(head -c 400 "$TL_RESP_B" 2>/dev/null)"
fi

# Tear down the second dashboard before finishing.
kill -TERM "-$DASH_PID2" 2>/dev/null || kill -TERM "$DASH_PID2" 2>/dev/null || true
sleep 0.5
kill -KILL "-$DASH_PID2" 2>/dev/null || kill -KILL "$DASH_PID2" 2>/dev/null || true
rm -rf "$QA_FED2"

# --- #362 test 33: Status tab renders per-agent table tbody with one row
#     per agent (one in this single-stub-agent fixture). Each row carries
#     `data-agent` for the click-row → modal handler, plus the 8 expected
#     columns (state-dot / agent / colony / conf / next / eta / limiting /
#     last-err). Replaces the deleted Promote Candidates test. ---
if python3 - "$HTML_FILE" "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    rendered = f.read()
with open(sys.argv[2]) as f:
    src = f.read()
# Container element exists in the template + rendered HTML.
if 'id="status-agent-table"' not in src:
    sys.stderr.write('#status-agent-table host missing from template\n'); sys.exit(2)
if 'id="status-agent-table"' not in rendered:
    sys.stderr.write('#status-agent-table host missing from rendered HTML\n'); sys.exit(3)
# Renderer + sort persistence wiring are present.
for needle in ('function renderStatusAgentTable', 'STATUS_AGENT_TABLE_COLUMNS',
               'data-agent="', 'agentis:dashboard:agent-table-sort'):
    if needle not in src:
        sys.stderr.write('per-agent table wiring missing: ' + needle + '\n'); sys.exit(4)
# 8 column headers in declaration order.
expected_labels = ['State', 'Agent', 'Colony', 'Conf', 'Next', 'ETA', 'Limiting', 'Last err']
m = re.search(r'STATUS_AGENT_TABLE_COLUMNS\s*=\s*\[(.*?)\];', src, re.DOTALL)
if not m:
    sys.stderr.write('STATUS_AGENT_TABLE_COLUMNS array not found\n'); sys.exit(5)
labels = re.findall(r"label:\s*'([^']+)'", m.group(1))
if labels != expected_labels:
    sys.stderr.write('column labels wrong: %r vs %r\n' % (labels, expected_labels)); sys.exit(6)
sys.exit(0)
PY
then
    pass "33: Status tab renders per-agent table tbody with data-agent rows + 8 columns (#362)"
else
    fail "33: per-agent table wiring regressed (#362)"
fi

# --- #362 test 34: Status tab stat-tile row includes a Total Experience
#     tile sourced from `data.experience_counts.total` with thousands
#     separator. This is the operator's missing-since-#359 contract —
#     federation-wide cumulative experience count back on the dashboard. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Renderer wiring present.
for needle in ('function renderStatusStatTiles',
               'id="status-stat-tiles"',
               'data.experience_counts',
               "toLocaleString('en-US')",
               "'Total Experience'"):
    if needle not in src:
        sys.stderr.write('stat-tile wiring missing: ' + needle + '\n'); sys.exit(2)
# Hermetic re-implementation: experience_counts.total = 12345 must format
# as '12,345 entries' under en-US thousands separator.
n = 12345
formatted = '{:,}'.format(n) + ' entries'
if formatted != '12,345 entries':
    sys.stderr.write('en-US locale formatter regression: %r\n' % formatted); sys.exit(3)
# Verify the JS string concatenation pattern is present in source so the
# rendered HTML carries the formatted total verbatim once the live federation
# pushes a non-zero value.
if "expTotal.toLocaleString('en-US') + ' entries'" not in src:
    sys.stderr.write('Total Experience tile string-concat pattern missing\n'); sys.exit(4)
sys.exit(0)
PY
then
    pass "34: Status tab Total Experience tile sourced from data.experience_counts.total with thousands separator (#362)"
else
    fail "34: Total Experience tile wiring regressed (#362)"
fi

# --- #362 test 35: Experience Growth chart renders at the bottom of the
#     Status tab (after status-meta), NOT inside <details>, NOT inside the
#     deleted Progress tab. Confidence Trend container is gone everywhere.
#     Replaces tests 23 + 54 from #359. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Negative: confidence-trend container must be gone everywhere.
if 'id="confidence-trend"' in src:
    sys.stderr.write('confidence-trend container still in template (deleted in #362)\n'); sys.exit(2)
# Negative: progress section must be gone.
if '<section data-tab="progress"' in src:
    sys.stderr.write('progress section still present (deleted in #362)\n'); sys.exit(3)
# Slice the Status tab body and verify experience-trend lives there.
m_sec = re.search(r'<section\s+data-tab="status"[^>]*>', src)
if not m_sec:
    sys.stderr.write('status section missing\n'); sys.exit(4)
start = m_sec.end()
m_next = re.search(r'<section\s+data-tab="', src[start:])
end = start + m_next.start() if m_next else len(src)
status_body = src[start:end]
if 'id="experience-trend"' not in status_body:
    sys.stderr.write('experience-trend chart missing from Status tab body\n'); sys.exit(5)
# Verify experience-trend appears AFTER status-meta in document order.
pos_meta = status_body.find('id="status-meta"')
pos_trend = status_body.find('id="experience-trend"')
if pos_meta < 0 or pos_trend < 0:
    sys.stderr.write('status-meta or experience-trend not found in Status body\n'); sys.exit(6)
if pos_trend <= pos_meta:
    sys.stderr.write('experience-trend should render AFTER status-meta\n'); sys.exit(7)
# Verify experience-trend is NOT wrapped in <details>.
head = status_body[:pos_trend]
last_open = head.rfind('<details')
last_close = head.rfind('</details>')
if last_open > last_close:
    sys.stderr.write('experience-trend is inside <details> on Status tab\n'); sys.exit(8)
sys.exit(0)
PY
then
    pass "35: Experience Growth chart at bottom of Status tab; #confidence-trend gone everywhere (#362)"
else
    fail "35: Experience Growth chart relocation regressed (#362)"
fi

# --- #352: pickTextColor returns dark for #f59e0b (amber) and light
#     for #3b82f6 (blue). The amber `tier-review-gated` background was
#     the WCAG AA violation that motivated the helper. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# The lookup must contain '#f59e0b': 'var(--text-on-light)' and
# '#3b82f6': 'var(--text)' so labels stay readable on light vs dark fills.
if not re.search(r"'#f59e0b':\s*'var\(--text-on-light\)'", html):
    sys.stderr.write('pickTextColor lookup missing dark-text mapping for #f59e0b\n')
    sys.exit(1)
if not re.search(r"'#3b82f6':\s*'var\(--text\)'", html):
    sys.stderr.write('pickTextColor lookup missing light-text mapping for #3b82f6\n')
    sys.exit(1)
# Helper function defined.
if 'function pickTextColor' not in html:
    sys.stderr.write('pickTextColor helper function not defined\n')
    sys.exit(1)
# --text-on-light variable defined.
if '--text-on-light:' not in html:
    sys.stderr.write('--text-on-light CSS variable not defined\n')
    sys.exit(1)
sys.exit(0)
PY
then
    pass "38: pickTextColor maps amber→dark + blue→light + variable defined (#352)"
else
    fail "38: pickTextColor contrast mapping regressed"
fi

# --- #352/#1227: sidecar listing renders all federation sidecars with name
#     labels and per-row [restart] button. The collector emits `data.sidecars`
#     with auto-promote + cost-cap (install-gated) plus the always-on
#     snapshot-refresh + cost-rate records (#1227); the renderer iterates and
#     emits one .sidecar-row per record. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(2)
sidecars = data.get('sidecars') or []
names = [s.get('name') for s in sidecars]
# #1227: all three federation sidecars must be present (cost-cap too).
for required in ('auto-promote', 'cost-cap', 'snapshot-refresh', 'cost-rate'):
    if required not in names:
        sys.stderr.write('sidecars[] missing %r: %r\n' % (required, names))
        sys.exit(3)
# #1227: the always-on sidecars carry no install file / started_at, so the
# collector must mark them installed+enabled (else the row shows a spurious
# `not installed` age + a disabled restart button).
by_name = {s.get('name'): s for s in sidecars}
for always_on in ('snapshot-refresh', 'cost-rate'):
    rec = by_name[always_on]
    if not rec.get('installed') or not rec.get('enabled'):
        sys.stderr.write('always-on %r not installed/enabled: %r\n' % (always_on, rec))
        sys.exit(6)
# renderSidecarStatus must be defined.
if 'function renderSidecarStatus' not in html:
    sys.stderr.write('renderSidecarStatus not defined\n'); sys.exit(4)
# The renderer must emit a button class="sidecar-restart"
if 'sidecar-restart' not in html:
    sys.stderr.write('sidecar-restart class not found in template\n'); sys.exit(5)
sys.exit(0)
PY
then
    pass "40: data.sidecars has auto-promote + cost-cap + snapshot-refresh + cost-rate, per-row [restart] (#352/#1227)"
else
    fail "40: sidecar listing wiring regressed"
fi

# --- #359 (was #352 test 41): bulk-restart action wired on the new
#     Recovery tab. The pre-#359 #bulk-actions container is gone (the
#     Overview tab is gone); the equivalent surface lives in the Recovery
#     tab as #recovery-bulk-actions. The legacy renderBulkActions is
#     preserved as a no-op for back-compat (its #bulk-actions container is
#     absent → it bails). Test enforces the new path. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# New Recovery-tab renderer.
if 'function renderRecoveryActions' not in html:
    sys.stderr.write('renderRecoveryActions not defined\n'); sys.exit(1)
if 'id="recovery-bulk-actions"' not in html:
    sys.stderr.write('#recovery-bulk-actions container missing\n'); sys.exit(2)
# Branch logic: filtering by non-running state still present.
if "a.state !== 'running'" not in html and 'a.state !== "running"' not in html:
    sys.stderr.write('non-running filter logic missing\n')
    sys.exit(3)
# `restartAllStopped` action handler still defined.
if 'function restartAllStopped' not in html:
    sys.stderr.write('restartAllStopped handler not defined\n'); sys.exit(4)
# Per-agent restart handler (new in #359).
if 'function restartAgent' not in html:
    sys.stderr.write('restartAgent handler not defined\n'); sys.exit(5)
# The legacy renderBulkActions function stays around (back-compat
# no-op when the #bulk-actions container is absent).
if 'function renderBulkActions' not in html:
    sys.stderr.write('legacy renderBulkActions removed (should remain as no-op)\n'); sys.exit(6)
sys.exit(0)
PY
then
    pass "41: bulk-restart wired on Recovery tab + per-agent restartAgent handler (#359)"
else
    fail "41: Recovery bulk + per-agent restart wiring regressed (#359)"
fi

# --- #357: Config tab EDITABLE by default. The v0.6.0 read-only gate
#     was a feature regression; #357 inverts the gate so writes are
#     permitted unless `operator_writes_disabled = true` is explicitly
#     set. Inputs render without disabled / readonly attributes by
#     default. The read-only branch is reachable via fixture-only
#     `read_only_override = true`. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(2)
ce = data.get('config_editor') or {}
# #357: the new defensive gate is `operator_writes_disabled` (not
# `_enabled`). Default-absent or False means the tab is editable.
if ce.get('operator_writes_disabled') is True:
    sys.stderr.write('default operator_writes_disabled is unexpectedly True: %r\n' % ce)
    sys.exit(3)
# renderConfigEditor must be defined.
if 'function renderConfigEditor' not in html:
    sys.stderr.write('renderConfigEditor not defined\n'); sys.exit(4)
# applyConfigEdits handler hits /config/apply.
if "fetch('/config/apply'" not in html:
    sys.stderr.write('applyConfigEdits does not POST /config/apply\n'); sys.exit(6)
# #357: writable branch — inputs without `disabled` / `readonly`. The
# fixture has no operator_writes_disabled, so the renderer must NOT
# apply the disabled attribute literal to .config-input elements. We
# grep the rendered Config tab section for `class="config-input"` and
# assert no occurrence carries ` disabled` on the same line.
m = re.search(r'<div\s+id="config-editor"[^>]*>(.*?)</section>', html, re.DOTALL)
config_section = m.group(1) if m else ''
disabled_inputs = re.findall(r'class="config-input"[^>]*disabled', config_section)
if disabled_inputs:
    # First-paint should never carry disabled on the editable default.
    sys.stderr.write('disabled attribute on .config-input under default editable mode: %r\n' % disabled_inputs[:3])
    sys.exit(5)
# The renderer body must reference the `operator_writes_disabled` and
# `read_only_override` gate keys so the inverted-gate logic is wired.
m = re.search(r'function renderConfigEditor\b.*?\n\}', html, re.DOTALL)
body = m.group(0) if m else ''
if 'operator_writes_disabled' not in body:
    sys.stderr.write('renderConfigEditor missing operator_writes_disabled gate\n'); sys.exit(7)
if 'read_only_override' not in body:
    sys.stderr.write('renderConfigEditor missing read_only_override fixture lever\n'); sys.exit(8)
# Read-only banner literal MUST still be defined (we only flipped the
# default; the read-only render path stays).
if 'config-readonly-banner' not in html:
    sys.stderr.write('config-readonly-banner class missing\n'); sys.exit(9)
sys.exit(0)
PY
then
    pass "42: Config tab editable by default; operator_writes_disabled gate inverted (#357)"
else
    fail "42: Config tab default-editable contract regressed (#357)"
fi

# --- #359: tab init defaults to STATUS (was 'overview' in #352). ---
# The default-active tab is enforced via JS at init: `localStorage` read
# falls back to 'status' when missing. Legacy values (overview/agents/
# promotions/learning) migrate via LEGACY_TAB_MIGRATION so a returning
# operator from #357 doesn't see a blank tab on first load post-upgrade.
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
if 'activateTab(initial)' not in html:
    sys.stderr.write('activateTab init call missing\n'); sys.exit(1)
if "initial = 'status'" not in html:
    sys.stderr.write("default 'status' fallback missing — #359 should NOT default to 'overview'\n"); sys.exit(2)
if 'ACTIVE_TAB_KEY' not in html:
    sys.stderr.write('ACTIVE_TAB_KEY not defined\n'); sys.exit(3)
# Legacy migration is in place so #357-era localStorage values don't
# leave the operator on a blank tab.
if 'LEGACY_TAB_MIGRATION' not in html:
    sys.stderr.write('LEGACY_TAB_MIGRATION map missing — pre-#359 localStorage values would crash\n'); sys.exit(4)
sys.exit(0)
PY
then
    pass "43: tab init defaults to status (was overview), legacy values migrate (#359)"
else
    fail "43: tab default + persistence regressed (#359)"
fi

# --- #352: new endpoints (`/restart-all-stopped`, `/sidecar-restart`,
#     `/config/apply`) all return non-200 fail-safes from the stub server
#     when the federation has nothing to act on. We assert each endpoint
#     responds (any status code, just not 404 / connection refused) so the
#     wiring exists. ---
T44_OK=1
RESP44A="$TMPDIR_TEST/restart-all-stopped.txt"
RESP44A_CODE="$(curl -s -o "$RESP44A" -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/restart-all-stopped" 2>/dev/null || echo "000")"
case "$RESP44A_CODE" in
    200|400|405|500|503) : ;;
    *) echo "  /restart-all-stopped returned $RESP44A_CODE (expected 200/400/405/500/503)"; T44_OK=0 ;;
esac
RESP44B="$TMPDIR_TEST/sidecar-restart.txt"
RESP44B_CODE="$(curl -s -o "$RESP44B" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"name":"auto-promote"}' "http://127.0.0.1:$PORT/sidecar-restart" 2>/dev/null || echo "000")"
# Stub server has no shared tools/, so 503 is expected. 200 is OK if the
# helper happens to be reachable. 400 is OK on bad payload defensively.
case "$RESP44B_CODE" in
    200|400|500|503) : ;;
    *) echo "  /sidecar-restart returned $RESP44B_CODE (expected 200/400/500/503)"; T44_OK=0 ;;
esac
RESP44C="$TMPDIR_TEST/config-apply.txt"
RESP44C_CODE="$(curl -s -o "$RESP44C" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d '{"scope":"fed","mtime_ms":0,"changes":[]}' "http://127.0.0.1:$PORT/config/apply" 2>/dev/null || echo "000")"
# #357: editable by default. Empty changes[] → 400. 503 only if the
# operator pre-flipped operator_writes_disabled (not in this fixture).
# 404 if the fed config file doesn't exist (fixture has no .agentis/config).
# 200 only on a non-empty payload, which we don't send here.
case "$RESP44C_CODE" in
    200|400|404|409|422|503) : ;;
    *) echo "  /config/apply returned $RESP44C_CODE (expected 200/400/404/409/422/503)"; T44_OK=0 ;;
esac
if [ "$T44_OK" -eq 1 ]; then
    pass "44: /restart-all-stopped, /sidecar-restart, /config/apply endpoints all return defensive status (#352)"
else
    fail "44: one or more #352 endpoints unreachable"
fi

# --- #359 (was #357 test 45): Forge Rate Limits container NOT a top-level
#     tab child. Lives only inside the per-colony modal (showColonyModal).
#     The Overview tab is gone in #359; we now assert the container does
#     not appear inside any of the 5 tab sections. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
def slice_section(haystack, name):
    m = re.search(r'<section\s+data-tab="' + re.escape(name) + r'"[^>]*>', haystack)
    if not m: return None
    start = m.end()
    n = re.search(r'<section\s+data-tab="', haystack[start:])
    end = start + n.start() if n else len(haystack)
    return haystack[start:end]
for name in ('status', 'cost', 'recovery', 'logs', 'config'):
    body = slice_section(src, name) or ''
    if 'id="forge-rate-limits"' in body:
        sys.stderr.write('Forge Rate Limits container in tab "' + name + '" — should be in colony modal (#359)\n')
        sys.exit(1)
# Per-colony modal entry point must exist.
if 'function showColonyModal' not in src:
    sys.stderr.write('showColonyModal not defined (#357 per-colony modal missing)\n')
    sys.exit(2)
# Modal markup container must be present.
if 'id="colony-modal"' not in src:
    sys.stderr.write('#colony-modal container missing\n'); sys.exit(3)
# The per-colony modal renderer must reference data.forge_rate_limits.
if 'forge_rate_limits' not in src:
    sys.stderr.write('forge_rate_limits never read in template\n'); sys.exit(4)
sys.exit(0)
PY
then
    pass "45: Forge Rate Limits stays in per-colony modal under 5-tab cut (#359)"
else
    fail "45: Forge Rate Limits relocation regression"
fi

# --- #357 test 46: confirm-modal markup. The bare `confirm()` was
#     replaced with a structured config-confirm-modal listing each key
#     diff. Asserts the modal container + the function that opens it. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys
with open(sys.argv[1]) as f:
    src = f.read()
needles = [
    'id="config-confirm-modal"',
    'config-confirm-rows',
    'config-confirm-key',
    '_showConfigConfirm',
    '_postConfigApply',
]
for n in needles:
    if n not in src:
        sys.stderr.write('config-confirm wiring missing: ' + n + '\n')
        sys.exit(2)
# The bare confirm() in applyConfigEdits (which we replaced) must be gone.
import re
m = re.search(r'function applyConfigEdits\b.*?\n\}', src, re.DOTALL)
body = m.group(0) if m else ''
if re.search(r'\bconfirm\(', body):
    sys.stderr.write('bare confirm() still in applyConfigEdits — should be _showConfigConfirm\n')
    sys.exit(3)
sys.exit(0)
PY
then
    pass "46: structured confirm modal replaces bare confirm() in applyConfigEdits (#357)"
else
    fail "46: confirm-modal markup regression"
fi

# --- #357 test 47: line-level TOML patcher smoke. Build a fixture
#     colony.toml with comments + sections + 5 keys. POST /config/apply
#     touching ONE key. Assert: file mutated (key has new value), every
#     OTHER line byte-identical, comments preserved. ---
PATCHER_FED="$TMPDIR_TEST/qa357-fed"
mkdir -p "$PATCHER_FED/.agentis/logs" "$PATCHER_FED/sample-colony/config" \
         "$PATCHER_FED/sample-colony/agents" "$PATCHER_FED/sample-colony/scripts"
cat > "$PATCHER_FED/sample-colony/config/colony.toml" <<'TOML'
# colony.toml — sample fixture for #357 patcher smoke
# Top of file comment must survive a patch.

[gitlab]
url = "https://example.test"  # inline comment must survive
project = "sample/repo"

[forge.gitlab]
api_root = "https://gitlab.example.test/api/v4"
url = "https://gitlab.example.test"

[llm]
backend = "cli"

[daemon]
tick_interval_ms = 60000
heartbeat_interval_ms = 1800000  # very long for live federations
TOML
cat > "$PATCHER_FED/sample-colony/agents/dummy.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
cat > "$PATCHER_FED/sample-colony/scripts/start-colony.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$PATCHER_FED/sample-colony/scripts/start-colony.sh"
PORT2="$(python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); p=s.getsockname()[1]; s.close(); print(p)")"
LOG2="$TMPDIR_TEST/dashboard-357.log"
setsid bash "$DASHBOARD_SH" "$PATCHER_FED" "$PORT2" >"$LOG2" 2>&1 &
DASH2_PID=$!
ready2=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -f -s -o /dev/null "http://127.0.0.1:$PORT2/" 2>/dev/null; then
        ready2=1; break
    fi
    sleep 0.5
done

if [ "$ready2" -eq 1 ]; then
    ORIG_FIXTURE="$PATCHER_FED/sample-colony/config/colony.toml"
    # Capture original via `cp`, not `$(cat)` — bash command substitution
    # strips trailing newlines, which would create false-positive diff
    # rows in the byte-identity assertion below.
    ORIG_FILE_47="$TMPDIR_TEST/orig-47.toml"
    cp "$ORIG_FIXTURE" "$ORIG_FILE_47"
    MTIME_MS_47="$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1]) * 1000))" "$ORIG_FIXTURE")"
    PAYLOAD_47="$(python3 -c "
import json, sys
print(json.dumps({
    'scope': 'sample-colony',
    'mtime_ms': int(sys.argv[1]),
    'changes': [{'key': 'daemon.tick_interval_ms', 'value': '30000', 'type': 'int'}],
}))" "$MTIME_MS_47")"
    RESP47="$TMPDIR_TEST/apply-47.txt"
    RESP47_CODE="$(curl -s -o "$RESP47" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD_47" \
        "http://127.0.0.1:$PORT2/config/apply" 2>/dev/null || echo "000")"
    T47_OK=1
    if [ "$RESP47_CODE" != "200" ]; then
        echo "  /config/apply returned $RESP47_CODE (expected 200): $(head -c 400 "$RESP47" 2>/dev/null)"
        T47_OK=0
    fi
    if cmp -s "$ORIG_FILE_47" "$ORIG_FIXTURE"; then
        echo "  fixture not mutated after /config/apply"
        T47_OK=0
    fi
    # The mutated key must hold the new value.
    if ! grep -q '^tick_interval_ms = 30000' "$ORIG_FIXTURE"; then
        echo "  daemon.tick_interval_ms not rewritten to 30000"
        T47_OK=0
    fi
    # Every other line must be byte-identical to the original — the
    # patcher only rewrites the matching `tick_interval_ms = ...` line.
    DIFF47="$TMPDIR_TEST/diff-47.txt"
    diff "$ORIG_FILE_47" "$ORIG_FIXTURE" > "$DIFF47" 2>&1 || true
    # Count only content-bearing diff lines (skip the `\ No newline at
    # end of file` markers, which are formatting noise rather than
    # content changes).
    DIFF_LINES_47="$(grep -cE '^[<>] ' "$DIFF47" 2>/dev/null || echo 0)"
    if [ "$DIFF_LINES_47" -gt 2 ]; then
        echo "  more than 1 line rewritten by /config/apply (diff lines: $DIFF_LINES_47)"
        head -20 "$DIFF47"
        T47_OK=0
    fi
    # Inline comment after the changed key must survive.
    if ! grep -q '# inline comment must survive' "$ORIG_FIXTURE"; then
        echo "  inline comment lost after patch"
        T47_OK=0
    fi
    if ! grep -q '# Top of file comment must survive a patch.' "$ORIG_FIXTURE"; then
        echo "  top-of-file comment lost after patch"
        T47_OK=0
    fi
    if [ "$T47_OK" -eq 1 ]; then
        pass "47: line-level TOML patcher mutates target key, byte-preserves the rest (#357)"
    else
        fail "47: line-level TOML patcher smoke regression"
    fi

    # --- #357 test 48: drift detection. Stat fixture, externally bump
    #     mtime, POST apply with stale mtime → 409 + drift:true. ---
    sleep 1  # ensure mtime can advance
    : > "$ORIG_FIXTURE.touch"
    python3 -c "
import os, sys, time
p = sys.argv[1]
ts = time.time() + 5  # future mtime so the disk_mtime > payload_mtime
os.utime(p, (ts, ts))
" "$ORIG_FIXTURE"
    PAYLOAD_48="$(python3 -c "
import json, sys
print(json.dumps({
    'scope': 'sample-colony',
    'mtime_ms': int(sys.argv[1]),
    'changes': [{'key': 'daemon.tick_interval_ms', 'value': '12345', 'type': 'int'}],
}))" "$MTIME_MS_47")"
    RESP48="$TMPDIR_TEST/apply-48.txt"
    RESP48_CODE="$(curl -s -o "$RESP48" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD_48" \
        "http://127.0.0.1:$PORT2/config/apply" 2>/dev/null || echo "000")"
    T48_OK=1
    if [ "$RESP48_CODE" != "409" ]; then
        echo "  drift detection returned $RESP48_CODE (expected 409): $(head -c 400 "$RESP48" 2>/dev/null)"
        T48_OK=0
    fi
    if ! grep -q '"drift": *true' "$RESP48" 2>/dev/null; then
        echo "  drift response missing drift:true: $(head -c 400 "$RESP48" 2>/dev/null)"
        T48_OK=0
    fi
    if [ "$T48_OK" -eq 1 ]; then
        pass "48: /config/apply returns 409 + drift:true on stale mtime (#357)"
    else
        fail "48: drift detection regression"
    fi

    # --- #357 test 49: multi-line value rejection. Append a multi-line
    #     array to the fixture, POST apply targeting that key, expect
    #     422 + clear error message. ---
    cat >> "$ORIG_FIXTURE" <<'TOML'

[multiline]
big_array = [
  "alpha",
  "beta",
  "gamma",
]
TOML
    MTIME_MS_49="$(python3 -c "import os,sys; print(int(os.path.getmtime(sys.argv[1]) * 1000))" "$ORIG_FIXTURE")"
    PAYLOAD_49="$(python3 -c "
import json, sys
print(json.dumps({
    'scope': 'sample-colony',
    'mtime_ms': int(sys.argv[1]),
    'changes': [{'key': 'multiline.big_array', 'value': 'whatever', 'type': 'text'}],
}))" "$MTIME_MS_49")"
    RESP49="$TMPDIR_TEST/apply-49.txt"
    RESP49_CODE="$(curl -s -o "$RESP49" -w '%{http_code}' -X POST \
        -H 'Content-Type: application/json' \
        -d "$PAYLOAD_49" \
        "http://127.0.0.1:$PORT2/config/apply" 2>/dev/null || echo "000")"
    T49_OK=1
    if [ "$RESP49_CODE" != "422" ]; then
        echo "  multi-line rejection returned $RESP49_CODE (expected 422): $(head -c 400 "$RESP49" 2>/dev/null)"
        T49_OK=0
    fi
    if ! grep -q 'value spans multiple lines' "$RESP49" 2>/dev/null; then
        echo "  422 response missing 'value spans multiple lines' message: $(head -c 400 "$RESP49" 2>/dev/null)"
        T49_OK=0
    fi
    if [ "$T49_OK" -eq 1 ]; then
        pass "49: /config/apply rejects multi-line values with 422 + clear message (#357)"
    else
        fail "49: multi-line rejection regression"
    fi

    # Tear down the second dashboard before the final summary.
    kill -TERM "-$DASH2_PID" 2>/dev/null || kill -TERM "$DASH2_PID" 2>/dev/null || true
    sleep 0.5
    kill -KILL "-$DASH2_PID" 2>/dev/null || kill -KILL "$DASH2_PID" 2>/dev/null || true
else
    fail "47/48/49: second dashboard never became ready" "log tail: $(tail -10 "$LOG2" 2>/dev/null | tr '\n' ' ')"
fi

# --- #357 test 50: collector emits the inverted gate field. The new
#     contract is `operator_writes_disabled` (not `_enabled`); the
#     audit_log_path must always be present. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
try:
    data = json.loads(m.group(1))
except Exception:
    sys.exit(2)
ce = data.get('config_editor') or {}
# audit_log_path always present.
if not ce.get('audit_log_path'):
    sys.stderr.write('audit_log_path missing from config_editor block\n'); sys.exit(3)
# operator_writes_disabled key present (default False).
if 'operator_writes_disabled' not in ce:
    sys.stderr.write('operator_writes_disabled key missing — collector still emits old _enabled gate?\n'); sys.exit(4)
if ce.get('operator_writes_disabled') is True:
    sys.stderr.write('default operator_writes_disabled is True — should be False (editable)\n'); sys.exit(5)
# Legacy operator_writes_enabled must be GONE so callers don't read a
# stale field.
if 'operator_writes_enabled' in ce:
    sys.stderr.write('legacy operator_writes_enabled key leaked into output\n'); sys.exit(6)
sys.exit(0)
PY
then
    pass "50: collector emits inverted gate (operator_writes_disabled), audit_log_path always present (#357)"
else
    fail "50: collector config_editor block contract regression"
fi

# =====================================================================
# #359 tests 51-58: stray quote bug, SSE flicker bug, Status verdict,
# Cost projections, cross-colony matrix, bulk-apply checkbox group.
# =====================================================================

# --- #359 test 51: stray quote scalar fix + complex-value marker ---
# Build a fixture colony.toml with a SCALAR string (`backend = "cli"`) and
# an INLINE ARRAY (`priority = ["p0", "p1", "p2"]`). Drive the collector
# directly, parse data.config_editor.scopes[*].keys, assert:
#   * scalar `backend` is emitted with raw_value="cli" (NOT "\"cli\"" and
#     NOT empty) AND complex_value=False.
#   * inline-array `priority` is emitted with complex_value=True so the
#     renderer can show the read-only marker instead of an editable input.
T51_FED="/tmp/qa-359-fed-51"
rm -rf "$T51_FED"
mkdir -p "$T51_FED/.agentis/experience" \
         "$T51_FED/.agentis/spend" \
         "$T51_FED/.agentis/lifecycle" \
         "$T51_FED/.dashboard" \
         "$T51_FED/triage/agents" \
         "$T51_FED/triage/config"
cat > "$T51_FED/triage/config/colony.toml" <<'TOML'
name = "triage"

[forge.gitlab]
project = "owner/repo"

[llm]
backend = "cli"

[planning.labels]
epic = "epic"

[triage.labels]
priority = ["p0", "p1", "p2"]
TOML
cat > "$T51_FED/triage/agents/qa_agent.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG

T51_AID="cccccccc"
T51_NOW="$SUITE_NOW"
T51_DAEMONS=$(python3 -c "
import json
print(json.dumps([{
    'agent_id': '$T51_AID',
    'source':   '$T51_FED/triage/agents/qa_agent.ag',
    'state':    'running',
    'health':   'healthy',
    'pid':      0,
    'confidence': 0.5,
    'tick_ok': 1,
    'tick_err': 0,
    'started_at': $T51_NOW - 100,
}]))
")
T51_AGENT_MAP='[{"agent":"qa_agent","colony":"triage"}]'
T51_COLONIES='["triage"]'
T51_JSON="$(python3 "$COLLECTOR_PY" \
    "$T51_DAEMONS" \
    "$T51_AGENT_MAP" \
    "$T51_FED" \
    "$T51_NOW" \
    "$T51_FED/.agentis/experience" \
    "$T51_FED/.agentis/logs" \
    "$T51_FED/.dashboard" \
    "$T51_COLONIES" \
    "" \
    qa_agent 2>/dev/null)"

# Pass T51_JSON via env-var so the heredoc body can stay quoted (no
# shell expansion / backslash munging on the embedded JSON).
T51_JSON_FILE="$TMPDIR_TEST/t51-collector.json"
printf '%s' "$T51_JSON" > "$T51_JSON_FILE"
if [ -s "$T51_JSON_FILE" ] && python3 - "$T51_JSON_FILE" <<'PY' 2>&1
import json, sys
with open(sys.argv[1]) as f:
    blob = json.loads(f.read())
ce = blob.get('config_editor') or {}
scopes = ce.get('scopes') or []
triage = next((s for s in scopes if s.get('scope') == 'triage'), None)
if triage is None:
    sys.stderr.write('triage scope missing\n'); sys.exit(2)
keys = triage.get('keys') or []
def find(section, key):
    for kv in keys:
        if kv.get('section') == section and kv.get('key') == key:
            return kv
    return None
backend = find('llm', 'backend')
if not backend:
    sys.stderr.write('[llm].backend not parsed\n'); sys.exit(3)
if backend.get('raw_value') != 'cli':
    sys.stderr.write('backend raw_value = %r, expected "cli" (no surrounding quotes)\n' % backend.get('raw_value'))
    sys.exit(4)
if backend.get('complex_value') is not False:
    sys.stderr.write('backend complex_value = %r, expected False\n' % backend.get('complex_value'))
    sys.exit(5)
priority = find('triage.labels', 'priority')
if not priority:
    sys.stderr.write('[triage.labels].priority not parsed\n'); sys.exit(6)
if priority.get('complex_value') is not True:
    sys.stderr.write('priority complex_value = %r, expected True (inline array)\n' % priority.get('complex_value'))
    sys.exit(7)
# Scalar string `epic = "epic"` must also strip quotes cleanly.
epic_kv = find('planning.labels', 'epic')
if not epic_kv or epic_kv.get('raw_value') != 'epic':
    sys.stderr.write('planning.labels.epic raw_value = %r, expected "epic"\n' % (epic_kv and epic_kv.get('raw_value')))
    sys.exit(8)
if epic_kv.get('complex_value'):
    sys.stderr.write('planning.labels.epic flagged as complex (it is scalar)\n'); sys.exit(9)
sys.exit(0)
PY
then
    pass "51: stray quote — scalar strips cleanly, inline array gets complex_value flag (#359)"
else
    fail "51: stray quote bug regression — see stderr above (#359)"
fi
rm -rf "$T51_FED"
rm -f "$T51_JSON_FILE"

# --- #359 test 52: NO <meta http-equiv="refresh"> in served HTML ---
# The pre-#359 dashboard had <meta http-equiv="refresh" content="60"> on
# line 5 of the template. It triggered full-page reloads every minute,
# wiping operator in-flight state (Bug 2). Removed in #359; SSE keeps
# the page fresh in-place. Regression guard.
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
# Scrub HTML comments AND <script>/<style> blocks (which can mention the
# tag historically in a JS/CSS comment) so the regex only matches a real
# <meta> element in the document head.
no_comments = re.sub(r'<!--.*?-->', '', html, flags=re.DOTALL)
no_scripts = re.sub(r'<script\b[^>]*>.*?</script>', '', no_comments, flags=re.DOTALL | re.IGNORECASE)
no_styles = re.sub(r'<style\b[^>]*>.*?</style>', '', no_scripts, flags=re.DOTALL | re.IGNORECASE)
if re.search(r'<meta\b[^>]*http-equiv\s*=\s*"refresh"', no_styles, re.IGNORECASE):
    sys.stderr.write('<meta http-equiv="refresh"> still present in document head — removed in #359 to fix flicker\n')
    sys.exit(1)
sys.exit(0)
PY
then
    pass "52: <meta http-equiv=\"refresh\"> removed from served HTML (#359 Bug 2 + Bug 4)"
else
    fail "52: meta refresh tag is back — would re-introduce 60s flicker (#359)"
fi

# --- #359 test 53: SSE status indicator markup + dot states ---
# A small `#sse-dot` lives in the page header. CSS classes sse-dot-init /
# sse-dot-ok / sse-dot-err are bound to EventSource lifecycle.
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    html = f.read()
needles = [
    'id="sse-dot"',
    'sse-dot-init',
    'sse-dot-ok',
    'sse-dot-err',
    '_sseSetDot',
    'es.onopen',
]
for n in needles:
    if n not in html:
        sys.stderr.write('SSE dot wiring missing: ' + n + '\n')
        sys.exit(2)
sys.exit(0)
PY
then
    pass "53: SSE status indicator markup + onopen/onerror wiring present (#359)"
else
    fail "53: SSE dot wiring regressed (#359)"
fi

# --- #359 test 56: Cost tab renders 4 projection stat tiles backed by
#     data.cost.projected_* fields (1h, 1d in headline; 1w / 1m in tile
#     extras). The collector emits all four projections; the renderer
#     references them. ---
if python3 - "$HTML_FILE" <<'PY' 2>/dev/null
import sys, re, json
with open(sys.argv[1]) as f:
    html = f.read()
m = re.search(r'const data\s*=\s*(\{.*?\});\n', html, re.DOTALL)
if not m: sys.exit(1)
data = json.loads(m.group(1))
cost = data.get('cost') or {}
# All four projection fields must be present (default 0.0 on a fresh
# fed with no spend rows in the 5-min window).
for k in ('rate_per_min_usd', 'rate_per_min_tokens',
          'projected_1h_usd', 'projected_1d_usd',
          'projected_1w_usd', 'projected_1m_usd'):
    if k not in cost:
        sys.stderr.write('cost.%s missing from collector output\n' % k); sys.exit(2)
# Threshold fields are also surfaced so JS can render the traffic-light.
for k in ('cost_threshold_yellow_usd_per_h', 'cost_threshold_red_usd_per_h'):
    if k not in cost:
        sys.stderr.write('cost.%s missing\n' % k); sys.exit(3)
# Renderer markup: id="cost-projections" container + projection-tile class.
if 'id="cost-projections"' not in html:
    sys.stderr.write('cost-projections container missing\n'); sys.exit(4)
if 'projection-tile' not in html:
    sys.stderr.write('projection-tile class missing\n'); sys.exit(5)
if 'function renderCostProjections' not in html:
    sys.stderr.write('renderCostProjections renderer missing\n'); sys.exit(6)
sys.exit(0)
PY
then
    pass "56: Cost tab renders 4 projection tiles backed by data.cost.projected_* (#359)"
else
    fail "56: Cost projections wiring regressed (#359)"
fi

# --- #359 test 57: Cross-colony matrix renders one row per dotted key
#     with at least one override. The collector emits
#     data.config_editor.matrix; the renderer walks it. ---
T57_FED="/tmp/qa-359-fed-57"
rm -rf "$T57_FED"
mkdir -p "$T57_FED/.agentis/logs" \
         "$T57_FED/triage/agents" "$T57_FED/triage/config" \
         "$T57_FED/code-review/agents" "$T57_FED/code-review/config"
cat > "$T57_FED/.agentis/config" <<'CFG'
[daemon]
tick_interval_ms = 60000
heartbeat_interval_ms = 1800000
CFG
cat > "$T57_FED/triage/config/colony.toml" <<'TOML'
[daemon]
tick_interval_ms = 30000

[llm]
backend = "cli"
TOML
cat > "$T57_FED/code-review/config/colony.toml" <<'TOML'
[daemon]
tick_interval_ms = 60000

[llm]
backend = "mock"
TOML
cat > "$T57_FED/triage/agents/x.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
cat > "$T57_FED/code-review/agents/y.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
T57_DAEMONS='[]'
T57_AGENT_MAP='[{"agent":"x","colony":"triage"},{"agent":"y","colony":"code-review"}]'
T57_COLONIES='["triage","code-review"]'
T57_JSON="$(python3 "$COLLECTOR_PY" \
    "$T57_DAEMONS" \
    "$T57_AGENT_MAP" \
    "$T57_FED" \
    "$SUITE_NOW" \
    "$T57_FED/.agentis/experience" \
    "$T57_FED/.agentis/logs" \
    "$T57_FED/.dashboard" \
    "$T57_COLONIES" \
    "" \
    x y 2>/dev/null)"

T57_JSON_FILE="$TMPDIR_TEST/t57-collector.json"
printf '%s' "$T57_JSON" > "$T57_JSON_FILE"
if [ -s "$T57_JSON_FILE" ] && python3 - "$T57_JSON_FILE" <<'PY' 2>&1
import json, sys
with open(sys.argv[1]) as f:
    blob = json.loads(f.read())
ce = blob.get('config_editor') or {}
matrix = ce.get('matrix')
if not isinstance(matrix, list):
    sys.stderr.write('config_editor.matrix missing or not list\n'); sys.exit(2)
# At least one override exists in the fixture (triage.daemon.tick_interval_ms
# overrides federation default; both colonies override [llm].backend).
if not matrix:
    sys.stderr.write('matrix empty (expected at least one override row)\n'); sys.exit(3)
keys = [r.get('key') for r in matrix]
if 'daemon.tick_interval_ms' not in keys:
    sys.stderr.write('expected daemon.tick_interval_ms in matrix; got %r\n' % keys); sys.exit(4)
if 'llm.backend' not in keys:
    sys.stderr.write('expected llm.backend in matrix; got %r\n' % keys); sys.exit(5)
# Each row carries cells keyed by scope name + the federation default.
backend_row = next((r for r in matrix if r.get('key') == 'llm.backend'), None)
cells = (backend_row or {}).get('cells') or {}
if 'triage' not in cells or 'code-review' not in cells:
    sys.stderr.write('per-colony cells missing on llm.backend: %r\n' % cells); sys.exit(6)
sys.exit(0)
PY
then
    T57_DATA_OK=1
else
    T57_DATA_OK=0
fi
rm -rf "$T57_FED"
rm -f "$T57_JSON_FILE"

if [ "$T57_DATA_OK" -eq 1 ] && python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys
with open(sys.argv[1]) as f:
    src = f.read()
needles = ['id="config-matrix"', 'function renderConfigMatrix', 'config-matrix-table']
for n in needles:
    if n not in src:
        sys.stderr.write('matrix renderer wiring missing: ' + n + '\n'); sys.exit(2)
sys.exit(0)
PY
then
    pass "57: cross-colony matrix emitted by collector + rendered on Config tab (#359)"
else
    fail "57: cross-colony matrix wiring regressed (#359)"
fi

# --- #359 test 58: bulk-apply confirm modal has per-colony checkbox
#     group when editing a federation-wide key. The renderer reads
#     configEditor.scopes to build the group; the confirm modal walks
#     `.bulk-apply-scope:checked` to decide which scopes to include in
#     the POST. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys
with open(sys.argv[1]) as f:
    src = f.read()
# CSS class for the checkbox group.
if 'config-confirm-scopes' not in src:
    sys.stderr.write('config-confirm-scopes CSS class missing\n'); sys.exit(2)
# Renderer must emit `.bulk-apply-scope` checkboxes inside the modal
# only when scope === 'federation'.
if 'bulk-apply-scope' not in src:
    sys.stderr.write('bulk-apply-scope class never emitted\n'); sys.exit(3)
# _showConfigConfirm + _postConfigApply must reference the bulk path.
if 'isFedScope' not in src:
    sys.stderr.write('isFedScope branch missing in _showConfigConfirm\n'); sys.exit(4)
if "scopes:" not in src and 'scopes:' not in src and 'scopes: checked' not in src and 'scopes: ' not in src:
    sys.stderr.write('bulk payload {scopes:[...]} never built in _postConfigApply\n'); sys.exit(5)
sys.exit(0)
PY
then
    pass "58: bulk-apply confirm modal renders per-colony checkbox group on fed-wide edits (#359)"
else
    fail "58: bulk-apply checkbox group wiring regressed (#359)"
fi

# --- #366 test 59: renderer is sentinel-injection-safe. When COLLECTOR_JSON
#     contains the literal text of another sentinel ({{HISTORY}}), the
#     rendered output keeps the literal as-is and does NOT inject the
#     history payload. Sequential str.replace would re-substitute and
#     break `const data = ...;` parsing in the browser, blanking the
#     dashboard. The fix uses a single-pass re.sub. ---
T59_DIR="$(mktemp -d)"
T59_TEMPLATE="$T59_DIR/template.html"
T59_OUTPUT="$T59_DIR/output.html"
cat > "$T59_TEMPLATE" <<'TPL'
<!doctype html><html><body>
const data = {{COLLECTOR_JSON}};
let history = {{HISTORY}};
let remediation = {{REMEDIATION}};
</body></html>
TPL
# Note the {{HISTORY}} literal embedded inside the COLLECTOR_JSON value.
T59_COLLECTOR='{"timeline":[{"out":"agent reasoned about {{HISTORY}} sentinel"}]}'
T59_HISTORY='[{"sentinel":true}]'
T59_REMEDIATION='[]'
T59_OK=0
if python3 "$RENDERER_PY" \
        "$T59_TEMPLATE" \
        "$T59_OUTPUT" \
        "fed" '"fed"' "1" "1" "0" "ts" \
        "$T59_COLLECTOR" "$T59_HISTORY" "$T59_REMEDIATION" "[]" \
        2>/dev/null
then
    # The {{HISTORY}} literal must survive inside the COLLECTOR_JSON value
    # (one occurrence). The history payload [{"sentinel":true}] must appear
    # exactly once — at the {{HISTORY}} substitution site, NOT also injected
    # into the COLLECTOR_JSON spot.
    T59_HIST_LIT_COUNT="$(grep -cF '{{HISTORY}}' "$T59_OUTPUT" 2>/dev/null || echo 0)"
    T59_PAYLOAD_COUNT="$(grep -cF '[{"sentinel":true}]' "$T59_OUTPUT" 2>/dev/null || echo 0)"
    if [ "$T59_HIST_LIT_COUNT" = "1" ] && [ "$T59_PAYLOAD_COUNT" = "1" ]; then
        T59_OK=1
    fi
fi
if [ "$T59_OK" -eq 1 ]; then
    pass "59: renderer is sentinel-injection-safe — {{HISTORY}} inside COLLECTOR_JSON is not re-substituted (#366)"
else
    fail "59: renderer re-substituted a sentinel literal inside another sentinel's value (#366)"
fi
rm -rf "$T59_DIR"

# --- #362 iter5 test 60: Promotion Progress combined panel — Phase
#     Readiness writes into #phase-readiness-host (NOT the pre-iter4 top-
#     level #readiness), Promote Candidates writes into
#     #promote-candidates-host (NOT the pre-iter4 top-level
#     #promote-candidates). Both renderers were resurrected from sha
#     90ffef4 and retargeted at the combined-panel hosts so the bottom-row
#     card stays self-contained on Status. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Renderer functions exist + their wrapper.
for fn in ('function renderPhaseReadiness',
           'function renderPromoteCandidates',
           'function renderPromotionProgress'):
    if fn not in src:
        sys.stderr.write('renderer missing: ' + fn + '\n'); sys.exit(2)
# Phase Readiness must target #phase-readiness-host, NOT #readiness.
m_phase = re.search(r'function renderPhaseReadiness\b.*?\n\}', src, re.DOTALL)
phase_body = m_phase.group(0) if m_phase else ''
if "getElementById('readiness')" in phase_body:
    sys.stderr.write('renderPhaseReadiness still targets pre-iter4 #readiness host\n'); sys.exit(3)
if "getElementById('phase-readiness-host')" not in phase_body:
    sys.stderr.write('renderPhaseReadiness does not target #phase-readiness-host\n'); sys.exit(4)
# Promote Candidates must target #promote-candidates-host, NOT #promote-candidates.
m_prom = re.search(r'function renderPromoteCandidates\b.*?\n\}', src, re.DOTALL)
prom_body = m_prom.group(0) if m_prom else ''
if "getElementById('promote-candidates')" in prom_body:
    sys.stderr.write('renderPromoteCandidates still targets pre-iter4 #promote-candidates host\n'); sys.exit(5)
if "getElementById('promote-candidates-host')" not in prom_body:
    sys.stderr.write('renderPromoteCandidates does not target #promote-candidates-host\n'); sys.exit(6)
# The combined panel hosts must exist in the template.
for needle in ('id="promotion-progress"', 'id="phase-readiness-host"', 'id="promote-candidates-host"'):
    if needle not in src:
        sys.stderr.write('combined-panel host missing: ' + needle + '\n'); sys.exit(7)
# rerender() must dispatch the combined wrapper.
if 'renderPromotionProgress(snap)' not in src:
    sys.stderr.write('rerender() does not call renderPromotionProgress(snap)\n'); sys.exit(8)
sys.exit(0)
PY
then
    pass "60: Promotion Progress combined panel — Phase Readiness and Promote Candidates retargeted at #phase-readiness-host / #promote-candidates-host (#362 iter5)"
else
    fail "60: Promotion Progress combined panel wiring regressed (#362 iter5)"
fi

# --- #362 iter5 test 61: Status tab bottom row — `.status-bottom-row`
#     flex container holds #experience-trend and #promotion-progress
#     side-by-side. Asserts both children live inside the same
#     .status-bottom-row sibling and the row CSS is wired (display: flex
#     + min-width: 0 children) so a long chart SVG / bar label cannot
#     force the row wider than the viewport. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Slice the Status tab body so the assertion is scoped to the right tab.
m_sec = re.search(r'<section\s+data-tab="status"[^>]*>', src)
if not m_sec:
    sys.stderr.write('status section missing\n'); sys.exit(2)
start = m_sec.end()
m_next = re.search(r'<section\s+data-tab="', src[start:])
end = start + m_next.start() if m_next else len(src)
status_body = src[start:end]
# .status-bottom-row container present inside Status.
m_row = re.search(r'<div\s+class="status-bottom-row"[^>]*>(.*?)</div>\s*</section>', status_body, re.DOTALL)
if not m_row:
    sys.stderr.write('.status-bottom-row not found at end of Status section\n'); sys.exit(3)
row_body = m_row.group(1)
# Both children inside the row.
if 'id="experience-trend"' not in row_body:
    sys.stderr.write('#experience-trend not inside .status-bottom-row\n'); sys.exit(4)
if 'id="promotion-progress"' not in row_body:
    sys.stderr.write('#promotion-progress not inside .status-bottom-row\n'); sys.exit(5)
# Document order: experience-trend before promotion-progress (left → right).
pos_trend = row_body.find('id="experience-trend"')
pos_prom = row_body.find('id="promotion-progress"')
if pos_trend < 0 or pos_prom < 0 or pos_trend >= pos_prom:
    sys.stderr.write('expected #experience-trend before #promotion-progress in .status-bottom-row\n'); sys.exit(6)
# CSS rules wired so the row actually flexes.
if not re.search(r'\.status-bottom-row\s*\{[^}]*display:\s*flex', src):
    sys.stderr.write('.status-bottom-row CSS does not set display:flex\n'); sys.exit(7)
if not re.search(r'\.status-bottom-row\s*>\s*\*\s*\{[^}]*min-width:\s*0', src):
    sys.stderr.write('.status-bottom-row > * does not set min-width: 0\n'); sys.exit(8)
sys.exit(0)
PY
then
    pass "61: Status tab bottom row — .status-bottom-row flex container holds #experience-trend and #promotion-progress side-by-side (#362 iter5)"
else
    fail "61: Status tab bottom row wiring regressed (#362 iter5)"
fi

# --- #369 test 62: Promotion Progress contrast — pickTextColor is applied
#     inside renderPhaseReadiness AND renderPromoteCandidates function
#     bodies so labels rendered on amber / yellow tier + partial bars use
#     dark fill (var(--text-on-light)) instead of the default light cyan
#     and meet WCAG-AA. Also asserts the lookup table covers the tier-
#     review-gated amber `#f59e0b` and the `--yellow` partial-fill `#ffff00`
#     entries — the two surfaces operators flagged as unreadable. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
m_phase = re.search(r'function renderPhaseReadiness\b.*?\n\}', src, re.DOTALL)
phase_body = m_phase.group(0) if m_phase else ''
if 'pickTextColor(' not in phase_body:
    sys.stderr.write('renderPhaseReadiness does not call pickTextColor(\n'); sys.exit(2)
m_prom = re.search(r'function renderPromoteCandidates\b.*?\n\}', src, re.DOTALL)
prom_body = m_prom.group(0) if m_prom else ''
if 'pickTextColor(' not in prom_body:
    sys.stderr.write('renderPromoteCandidates does not call pickTextColor(\n'); sys.exit(3)
# Sanity: the pickTextColor lookup table maps amber + yellow to dark text.
if "'#f59e0b': 'var(--text-on-light)'" not in src:
    sys.stderr.write('PICK_TEXT_LOOKUP missing tier-review-gated amber → dark text\n'); sys.exit(4)
if "'#ffff00': 'var(--text-on-light)'" not in src:
    sys.stderr.write('PICK_TEXT_LOOKUP missing partial-fill yellow → dark text\n'); sys.exit(5)
sys.exit(0)
PY
then
    pass "62: Promotion Progress contrast — pickTextColor is applied inside renderPhaseReadiness AND renderPromoteCandidates so amber/yellow bar labels meet WCAG-AA (#369)"
else
    fail "62: Promotion Progress contrast regression — pickTextColor missing on tier or partial bar labels (#369)"
fi

# --- #369 test 63: Promotion Progress is collapsible — <details
#     id="promotion-progress-details"> wraps the content, <summary>
#     contains the three counters (ready / close / not yet), default
#     collapsed (no `open` attribute on the outer <details>). Per-agent
#     log tail removed from Recovery tab in the same iteration; assert
#     the host card lives inside <section data-tab="logs">. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# <details id="promotion-progress-details"> wraps the panel.
m_det = re.search(r'<details\s+id="promotion-progress-details"([^>]*)>', src)
if not m_det:
    sys.stderr.write('<details id="promotion-progress-details"> not found\n'); sys.exit(2)
attrs = m_det.group(1)
if re.search(r'\bopen\b', attrs):
    sys.stderr.write('<details id="promotion-progress-details"> has `open` attribute (must default collapsed)\n'); sys.exit(3)
# <summary> with three counters present.
m_sum = re.search(r'<details\s+id="promotion-progress-details"[^>]*>\s*<summary>(.*?)</summary>', src, re.DOTALL)
if not m_sum:
    sys.stderr.write('<summary> inside #promotion-progress-details not found\n'); sys.exit(4)
sum_body = m_sum.group(1)
for needle in ('ready', 'close', 'not yet'):
    if needle not in sum_body:
        sys.stderr.write('<summary> missing counter: ' + needle + '\n'); sys.exit(5)
# Children rehosted inside the <details>.
m_full = re.search(
    r'<details\s+id="promotion-progress-details"[^>]*>(.*?)</details>',
    src, re.DOTALL,
)
if not m_full:
    sys.stderr.write('<details id="promotion-progress-details"> close not found\n'); sys.exit(6)
panel_body = m_full.group(1)
for needle in ('id="phase-readiness-host"', 'id="promote-candidates-host"'):
    if needle not in panel_body:
        sys.stderr.write('child host missing inside <details>: ' + needle + '\n'); sys.exit(7)
# rerender() must dispatch the summary aggregate alongside the children.
if 'renderPromotionSummary' not in src:
    sys.stderr.write('renderPromotionSummary helper missing\n'); sys.exit(8)
# Per-Agent Log Tail moved from Recovery to Logs & Events.
m_logs = re.search(r'<section\s+data-tab="logs"[^>]*>(.*?)</section>', src, re.DOTALL)
if not m_logs:
    sys.stderr.write('<section data-tab="logs"> not found\n'); sys.exit(9)
if 'id="recovery-log-tails"' not in m_logs.group(1):
    sys.stderr.write('Per-Agent Log Tail host (#recovery-log-tails) not inside Logs & Events\n'); sys.exit(10)
# And NOT inside Recovery any more.
m_rec = re.search(r'<section\s+data-tab="recovery"[^>]*>(.*?)</section>', src, re.DOTALL)
if not m_rec:
    sys.stderr.write('<section data-tab="recovery"> not found\n'); sys.exit(11)
if 'id="recovery-log-tails"' in m_rec.group(1):
    sys.stderr.write('Per-Agent Log Tail still inside Recovery tab (must move to Logs & Events)\n'); sys.exit(12)
sys.exit(0)
PY
then
    pass "63: Promotion Progress is collapsible — <details id=\"promotion-progress-details\"> wraps content with ready/close/not-yet summary, default collapsed; Per-Agent Log Tail moved to Logs & Events (#369)"
else
    fail "63: Promotion Progress collapsible wrap or log-tail relocation regressed (#369)"
fi

# --- #369 test 64: Promote Candidates list capped at top 5 with a
#     "+N more" hint pointing at the Agents table. Asserts the renderer
#     slices to 5 (or equivalent) and emits a `more-candidates` marker
#     when the source list is longer. ---
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
m = re.search(r'function renderPromoteCandidates\b.*?\n\}', src, re.DOTALL)
body = m.group(0) if m else ''
if not body:
    sys.stderr.write('renderPromoteCandidates body not found\n'); sys.exit(2)
# Slice cap to 5 entries (visible bars).
if not re.search(r'\.slice\s*\(\s*0\s*,\s*5\s*\)', body):
    sys.stderr.write('renderPromoteCandidates does not .slice(0, 5) the bar list\n'); sys.exit(3)
# "+N more" hint emitted via the more-candidates marker.
if 'more-candidates' not in body:
    sys.stderr.write('renderPromoteCandidates does not emit the `more-candidates` marker\n'); sys.exit(4)
sys.exit(0)
PY
then
    pass "64: Promote Candidates list capped at top 5 + +N more hint when there are >5 candidates (#369)"
else
    fail "64: Promote Candidates top-5 cap or more-candidates hint regressed (#369)"
fi

# --- t65b (#1145): federation-dashboard-timeline.py must take its "now" as
#     an injected arg (the single epoch the wrapper already sampled for the
#     collector), never re-sample the wall clock. We run the helper twice
#     against the SAME fixture with the SAME frozen $SUITE_NOW and assert the
#     output is byte-identical and the 7-day cutoff is anchored on the
#     injected now (a row just inside the window survives; a row just outside
#     is dropped). Before the fix the helper sampled time.time() internally,
#     so its cutoff disagreed with the injected epoch across 00:00 UTC. ---
TIMELINE_PY="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-timeline.py"
T65B_FED="/tmp/qa-1145-timeline-fed"
rm -rf "$T65B_FED"
mkdir -p "$T65B_FED/.agentis/experience" \
         "$T65B_FED/.agentis/spend" \
         "$T65B_FED/.agentis/lifecycle" \
         "$T65B_FED/.dashboard"
T65B_AID="dddddddd"
T65B_NOW="$SUITE_NOW"
# Two experience rows: one 30s old (inside the 7-day window) and one 8 days
# old (outside). The injected-now cutoff decides which survives.
cat > "$T65B_FED/.agentis/experience/$T65B_AID.jsonl" <<EXP
{"v":1,"ts":$((T65B_NOW - 30)),"agent":"$T65B_AID","action":"draft","in":"recent","outcome":"success","delta":0.10}
{"v":1,"ts":$((T65B_NOW - 8 * 86400)),"agent":"$T65B_AID","action":"draft","in":"stale","outcome":"success","delta":0.10}
EXP
cat > "$T65B_FED/.agentis/lifecycle/events.jsonl" <<LIFE
{"agent_id":"$T65B_AID","event":"daemon.started","cb_per_tick":2000,"tick_interval_ms":60000,"ts":$((T65B_NOW - 90))}
LIFE
T65B_DAEMONS=$(python3 -c "
import json
print(json.dumps([{
    'agent_id': '$T65B_AID',
    'source':   '$T65B_FED/qa-colony/agents/d_agent.ag',
    'state':    'running',
}]))
")
T65B_MAP='[{"agent":"d_agent","colony":"qa-colony"}]'
T65B_OUT="$T65B_FED/.dashboard/timeline-full.jsonl"
python3 "$TIMELINE_PY" \
    "$T65B_FED/.agentis/experience" "$T65B_FED/.agentis/spend" \
    "$T65B_FED/.agentis/lifecycle" "$T65B_FED/.dashboard" \
    "$T65B_MAP" "$T65B_DAEMONS" "$T65B_OUT" "$T65B_NOW" 2>/dev/null || true
T65B_FIRST="$(cat "$T65B_OUT" 2>/dev/null || true)"
python3 "$TIMELINE_PY" \
    "$T65B_FED/.agentis/experience" "$T65B_FED/.agentis/spend" \
    "$T65B_FED/.agentis/lifecycle" "$T65B_FED/.dashboard" \
    "$T65B_MAP" "$T65B_DAEMONS" "$T65B_OUT" "$T65B_NOW" 2>/dev/null || true
T65B_SECOND="$(cat "$T65B_OUT" 2>/dev/null || true)"
t65b_ok=1
if [ "$T65B_FIRST" != "$T65B_SECOND" ]; then
    echo "  timeline.py output not deterministic w.r.t. the injected now"
    t65b_ok=0
elif ! printf '%s\n' "$T65B_FIRST" | grep -q '"in":"recent"'; then
    echo "  in-window experience row missing from timeline.py output"
    t65b_ok=0
elif printf '%s\n' "$T65B_FIRST" | grep -q '"in":"stale"'; then
    echo "  out-of-window experience row leaked past the injected-now cutoff"
    t65b_ok=0
fi
rm -rf "$T65B_FED"
if [ "$t65b_ok" -eq 1 ]; then
    pass "65b: timeline.py anchors its 7-day cutoff on the injected now — deterministic, 00:00-UTC-safe (#1145)"
else
    fail "65b: timeline.py mis-handled the injected now — see stderr above (#1145)"
fi

# t65 (#1043): the collector must derive ALL now-relative computation from the single
# injected epoch (NOW_TS), never re-sample the wall clock. A second time-sample can
# disagree with the injected epoch across the 00:00 UTC date boundary and flake the
# timeline/cost tests (test-sse-stream.sh test 8 runs this suite, so it goes red too).
# Source-guard so the regression can't return silently.
if [ -f "$COLLECTOR_PY" ] && ! grep -Eq 'time\.time\(\)' "$COLLECTOR_PY"; then
    pass "65: collector takes no second wall-clock sample — all now-derived from the injected epoch/NOW_TS (#1043)"
else
    fail "65: federation-dashboard-collector.py still calls time.time() — 00:00 UTC date-boundary flake risk (#1043)" \
         "offending: $(grep -nE 'time\.time\(\)' "$COLLECTOR_PY" 2>/dev/null | tr '\n' ' ')"
fi

# t66 (#1145): the sibling timeline helper must ALSO take no second wall-clock
# sample — it now derives its 7-day cutoff from the injected now (argv[8]),
# the same single epoch the wrapper passes the collector. #1043 hardened the
# collector but MISSED timeline.py, which re-sampled time.time() and disagreed
# across 00:00 UTC. Source-guard so the regression can't return silently.
if [ -f "$TIMELINE_PY" ] && ! grep -Eq 'time\.time\(\)' "$TIMELINE_PY"; then
    pass "66: timeline helper takes no second wall-clock sample — cutoff now-derived from the injected epoch (#1145)"
else
    fail "66: federation-dashboard-timeline.py still calls time.time() — 00:00 UTC date-boundary flake risk (#1145)" \
         "offending: $(grep -nE 'time\.time\(\)' "$TIMELINE_PY" 2>/dev/null | tr '\n' ' ')"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
