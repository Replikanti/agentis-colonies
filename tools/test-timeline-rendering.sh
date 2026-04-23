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

# --- #248 PR C: Phase Readiness compact tier counter (not bars) ---
# The bar visualisation (phase-bar-outer, phase-marker, phase-eta) was
# removed in PR C in favour of a compact per-colony per-tier counter.
# Lock the contract so a stray revert that brings back the bar markup
# trips this test instead of silently regressing the operator UX.
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Bar/marker/ETA classes must be gone.
forbidden = ['phase-bar-outer', 'phase-bar-inner', 'phase-marker', 'phase-eta']
for cls in forbidden:
    if cls in src:
        sys.stderr.write('forbidden class still present: ' + cls + '\n'); sys.exit(2)
# New tier-counter classes must be wired (CSS + JS render).
required = ['phase-tier', 'phase-tier-label', 'phase-tier-count', 'has-shadow', 'has-propose', 'has-review-gated', 'has-autonomous', 'has-dormant', 'has-no-conf']
for cls in required:
    if cls not in src:
        sys.stderr.write('missing class: ' + cls + '\n'); sys.exit(3)
# Renderer must distinguish null-confidence ("no-conf") from conf<0.4 ("dormant").
if "tierFor" not in src or "'dormant'" not in src or "'no-conf'" not in src:
    sys.stderr.write('tierFor / dormant / no-conf missing\n'); sys.exit(4)
# h2-in-summary anti-pattern must be gone in favour of .summary-h2 span.
if '<summary><h2>' in src:
    sys.stderr.write('h2-in-summary anti-pattern still present\n'); sys.exit(5)
if 'summary-h2' not in src:
    sys.stderr.write('summary-h2 class missing\n'); sys.exit(6)
sys.exit(0)
PY
then
    pass "22: Phase Readiness uses compact tier counter, not bars (#248 PR C)"
else
    fail "22: Phase Readiness regression — bar markup still present or tier-counter classes missing"
fi

# --- #248 PR C: Confidence Trend + Experience Growth demoted behind <details> ---
# Both charts were heavy panels of marginal value; they live inside collapsed
# <details> now. Lock the contract so neither gets accidentally promoted back
# to the always-on grid.
if python3 - "$TEMPLATE_HTML" <<'PY' 2>/dev/null
import sys, re
with open(sys.argv[1]) as f:
    src = f.read()
# Both chart containers must sit inside a <details class="card-collapse">.
# Single-line regex-friendly check: each id must be preceded (within ~400
# chars upward) by a "<details" with matching close before another card.
for chart_id in ('experience-trend', 'confidence-trend'):
    m = re.search(r'<details[^>]*class="card-collapse"[^>]*>([^<]|<(?!/details))*?id="' + chart_id + '"', src, re.DOTALL)
    if not m:
        sys.stderr.write(chart_id + ' not inside <details class=card-collapse>\n'); sys.exit(2)
    # Default-collapsed: the <details> tag must NOT have an `open` attribute.
    tag = m.group(0).split('>', 1)[0]
    if re.search(r'\bopen\b', tag):
        sys.stderr.write(chart_id + ' details opens by default — should be collapsed\n'); sys.exit(3)
sys.exit(0)
PY
then
    pass "23: Confidence Trend + Experience Growth wrapped in collapsed <details> (#248 PR C)"
else
    fail "23: chart-demotion regression — one or both charts no longer inside collapsed <details>"
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
