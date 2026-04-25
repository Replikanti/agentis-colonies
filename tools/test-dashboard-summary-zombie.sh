#!/bin/bash
# tools/test-dashboard-summary-zombie.sh: regression test for #300 — the
# dashboard's top-line "Agents Running" stat box must not disagree with
# per-agent rendering when the daemon registry contains zombie rows
# (state=running but the OS PID is gone).
#
# Pre-#300 the summary counted `agents.filter(a => a.state === 'running')`,
# while per-agent rows used `state === 'running' && pid > 0 && !pid_alive`
# to flag dead PIDs. When the federation hit the zombie pattern, the top
# said "21/21 running" while every per-agent row rendered as DEAD.
#
# Fix:
#   1. federation-dashboard-collector.py emits a derived `is_running`
#      field on each agent record: `state == 'running' AND pid_alive`.
#   2. federation-dashboard.html.template's stats-row counter switches
#      from `a.state === 'running'` to `a.is_running`.
#
# Strategy (mirrors test-dashboard-sidecar-grace.sh):
#   - Drive federation-dashboard-collector.py directly with a synthetic
#     daemons JSON: 10 rows with PIDs of THIS shell (always alive), 11
#     rows with high-numbered PIDs that cannot exist (zombies). All 21
#     rows have state=running.
#   - Assert the emitted JSON has exactly 10 `is_running: true` and 11
#     `is_running: false` records.
#   - Render via federation-dashboard-renderer.py and assert:
#       (a) the rendered HTML contains the new template predicate
#           (`a.is_running`) — protects the template change from regression.
#       (b) the rendered HTML's embedded COLLECTOR_JSON still has the
#           10/11 split — confirms data reaches the template intact.
#
# Usage: ./tools/test-dashboard-summary-zombie.sh
# Exit 0 on full pass.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COLLECTOR="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-collector.py"
RENDERER="$REPO_ROOT/federation-dashboard/lib/federation-dashboard-renderer.py"
TEMPLATE="$REPO_ROOT/federation-dashboard/lib/federation-dashboard.html.template"

PASS=0
FAIL=0
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "[FAIL] $1${2:+: $2}"; FAIL=$((FAIL + 1)); }

if [ ! -r "$COLLECTOR" ]; then
    fail "0: federation-dashboard-collector.py not readable" "$COLLECTOR"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if [ ! -r "$RENDERER" ]; then
    fail "0: federation-dashboard-renderer.py not readable" "$RENDERER"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if [ ! -r "$TEMPLATE" ]; then
    fail "0: federation-dashboard.html.template not readable" "$TEMPLATE"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Synthetic federation fixture ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.dashboard" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/experience" \
         "$FED_DIR/stub-colony/agents" \
         "$FED_DIR/stub-colony/config"

cat > "$FED_DIR/stub-colony/config/colony.toml" <<'TOML'
[colony]
name = "stub-colony"
TOML

# Generate 21 stub .ag agents so the collector iterates 21 times.
ALL_AGENTS=()
for i in $(seq -w 1 21); do
    name="zombie_agent_${i}"
    ALL_AGENTS+=("$name")
    cat > "$FED_DIR/stub-colony/agents/${name}.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
done

# --- Synthetic daemons JSON ---
# 10 alive (PID = $$, this shell — guaranteed alive while the test runs)
# 11 zombies (high PID that cannot exist on a normal Linux/macOS system)
# All 21 rows carry state=running, which is the pre-#300 trigger for the
# stat box to count them as "running" regardless of pid_alive.
ALIVE_PID="$$"
DEAD_PID=2147483600   # near INT32_MAX — well above kernel.pid_max default
DAEMONS_JSON_FILE="$TMPDIR_TEST/daemons.json"
python3 - "$DAEMONS_JSON_FILE" "$ALIVE_PID" "$DEAD_PID" <<'PY'
import json, sys
out, alive_pid, dead_pid = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = []
for i in range(1, 22):
    name = f"zombie_agent_{i:02d}"
    pid = alive_pid if i <= 10 else dead_pid
    rows.append({
        "agent_id": f"agentid{i:04x}",
        "source": f"stub-colony/agents/{name}.ag",
        "state": "running",
        "health": "healthy",
        "pid": pid,
        "started_at": 1700000000,
        "tick_ok": 1,
        "tick_err": 0,
    })
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

AGENT_MAP_FILE="$TMPDIR_TEST/agent_map.json"
python3 - "$AGENT_MAP_FILE" <<'PY'
import json, sys
out = sys.argv[1]
rows = [{"agent": f"zombie_agent_{i:02d}", "colony": "stub-colony"} for i in range(1, 22)]
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

# --- Run the collector ---
COLLECTOR_OUT="$TMPDIR_TEST/collector.json"
EPOCH="$(date '+%s')"
python3 "$COLLECTOR" \
    "@$DAEMONS_JSON_FILE" \
    "$(cat "$AGENT_MAP_FILE")" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$FED_DIR/.dashboard" \
    '["stub-colony"]' \
    '' \
    "${ALL_AGENTS[@]}" \
    > "$COLLECTOR_OUT" 2>"$TMPDIR_TEST/collector.err"

if [ ! -s "$COLLECTOR_OUT" ]; then
    fail "1: collector produced empty output" "stderr: $(cat "$TMPDIR_TEST/collector.err" 2>/dev/null | head -3 | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: emitted is_running counts match the input split. ---
COUNT_LINE="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
agents = blob.get("agents", [])
running_true = sum(1 for a in agents if a.get("is_running") is True)
running_false = sum(1 for a in agents if a.get("is_running") is False)
total = len(agents)
print(f"{running_true} {running_false} {total}")
PY
)"
RUNNING_TRUE="$(echo "$COUNT_LINE" | awk '{print $1}')"
RUNNING_FALSE="$(echo "$COUNT_LINE" | awk '{print $2}')"
TOTAL="$(echo "$COUNT_LINE" | awk '{print $3}')"
if [ "$RUNNING_TRUE" = "10" ] && [ "$RUNNING_FALSE" = "11" ] && [ "$TOTAL" = "21" ]; then
    pass "1: collector emits is_running=true for 10 alive PIDs and false for 11 zombies (10/11 split out of 21)"
else
    fail "1: is_running split wrong — expected 10 true / 11 false / 21 total, got $RUNNING_TRUE / $RUNNING_FALSE / $TOTAL"
fi

# --- Test 2: every record carries the new field (no missing keys). ---
MISSING="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
miss = [a.get("name", "?") for a in blob.get("agents", []) if "is_running" not in a]
print(len(miss))
PY
)"
if [ "$MISSING" = "0" ]; then
    pass "2: every per-agent record carries the new is_running key"
else
    fail "2: $MISSING per-agent records missing is_running key"
fi

# --- Test 3: registry state on the zombies still reads 'running' ---
# Sanity check — proves the test fixture actually drives the zombie code
# path. If the fixture were degenerate (e.g. all rows state=stopped) the
# is_running split above would still pass while the regression remained
# uncaught. Pre-#300 the stat box used a.state === 'running' which means
# all 21 must read state=running for the bug to be reproducible.
STATES_RUNNING="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
print(sum(1 for a in blob.get("agents", []) if a.get("state") == "running"))
PY
)"
if [ "$STATES_RUNNING" = "21" ]; then
    pass "3: all 21 agents have state=running (pre-#300 stat box would say 21/21)"
else
    fail "3: fixture degenerate — only $STATES_RUNNING/21 records carry state=running"
fi

# --- Test 4: template's stats-row predicate switched to is_running. ---
# Direct grep of the template — protects against an accidental revert of
# the consumer side. The new predicate is `a.is_running`; the pre-#300
# `agents.filter(a => a.state === 'running')` form must NOT survive in
# the stats-row IIFE.
if grep -q 'agents.filter(a => a.is_running)' "$TEMPLATE"; then
    pass "4: template stats-row counter uses agents.filter(a => a.is_running)"
else
    fail "4: template stats-row counter does not use a.is_running predicate"
fi

# --- Test 5: render the page and confirm both pieces land in HTML. ---
HTML_OUT="$TMPDIR_TEST/index.html"
python3 "$RENDERER" \
    "$TEMPLATE" \
    "$HTML_OUT" \
    "stub-fed" \
    '"stub-fed"' \
    "1" \
    "21" \
    "$EPOCH" \
    "2026-01-01 00:00:00" \
    "@$COLLECTOR_OUT" \
    '[]' \
    '[]' \
    '["stub-colony"]'

if [ ! -s "$HTML_OUT" ]; then
    fail "5: renderer produced empty index.html"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Embedded predicate (matches the post-#300 template line).
if grep -q 'agents.filter(a => a.is_running)' "$HTML_OUT"; then
    t5a=1
else
    t5a=0
fi
# Embedded JSON: parse out the COLLECTOR_JSON the JS reads from the page
# and recount. This exercises the full collector -> renderer -> template
# pipeline end-to-end. Uses json.JSONDecoder.raw_decode rather than a
# regex because the embedded JSON contains nested braces that no lazy
# pattern can balance.
DATA_RUNNING_TRUE="$(python3 - "$HTML_OUT" <<'PY'
import json, sys
html = open(sys.argv[1], encoding="utf-8").read()
needle = "const data = "
idx = html.find(needle)
if idx < 0:
    print("ERR")
    sys.exit(0)
start = idx + len(needle)
try:
    blob, _end = json.JSONDecoder().raw_decode(html, start)
except ValueError:
    print("ERR")
    sys.exit(0)
print(sum(1 for a in blob.get("agents", []) if a.get("is_running") is True))
PY
)"
if [ "$t5a" -eq 1 ] && [ "$DATA_RUNNING_TRUE" = "10" ]; then
    pass "5: rendered HTML carries a.is_running predicate AND embeds 10/21 is_running=true records"
else
    fail "5: rendered HTML missing pieces — predicate_present=$t5a, is_running_true_in_data=$DATA_RUNNING_TRUE (want 1, 10)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
