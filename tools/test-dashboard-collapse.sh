#!/bin/bash
# tools/test-dashboard-collapse.sh: regression test for #412 — the dashboard's
# per-agent table must render N rows (one per `(colony, agent_name)` pair),
# not 1 row, when N colonies share an agent role basename.
#
# Pre-#412 the collector keyed `name_to_colony` and `role_to_daemon` by role
# alone. `dev-apprenticeship`'s 21 agents have globally-unique names so the
# bug was invisible there; `tribes-bench`'s 5 colonies × 1 agent named `hunter`
# each collapsed into a single rendered row because the dict overwrote on
# every duplicate key.
#
# Fix:
#   1. `role_to_daemon` is keyed by `(colony, role)` tuple; the colony half
#      is derived from the daemon's `source` field
#      (`<colony>/agents/<role>.ag` → `<colony>`).
#   2. The agent loop iterates `agent_map` (per-(colony, agent) records the
#      entry script builds from the on-disk colony×agents/*.ag tree) instead
#      of the flat `all_agents` list. Each (colony, agent_name) pair gets
#      its own record in the emitted JSON.
#
# Strategy (mirrors test-dashboard-summary-zombie.sh):
#   - Drive federation-dashboard-collector.py against a synthetic 2-colony
#     fixture where both colonies have an agent named `worker`.
#   - Assert the emitted JSON `agents` array has exactly 2 records (not 1)
#     and that they carry distinct `colony` fields.
#   - Render via federation-dashboard-renderer.py and assert the embedded
#     COLLECTOR_JSON in the rendered HTML still has both records.
#
# Usage: ./tools/test-dashboard-collapse.sh
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

# --- Synthetic federation fixture: 2 colonies × 1 agent named `worker` ---
FED_DIR="$TMPDIR_TEST/fed"
mkdir -p "$FED_DIR/.dashboard" \
         "$FED_DIR/.agentis/logs" \
         "$FED_DIR/.agentis/experience" \
         "$FED_DIR/colony-a/agents" \
         "$FED_DIR/colony-a/config" \
         "$FED_DIR/colony-b/agents" \
         "$FED_DIR/colony-b/config"

for col in colony-a colony-b; do
    cat > "$FED_DIR/$col/config/colony.toml" <<TOML
[colony]
name = "$col"
TOML
    cat > "$FED_DIR/$col/agents/worker.ag" <<'AG'
cb 100;
fn tick() { return Void; }
AG
done

# --- Synthetic daemons JSON ---
# Two daemons, both named `worker`, in different colonies. Different agent_id
# values (sha-8 prefix); both alive (PID = $$, this shell). Pre-#412 the
# `role_to_daemon` map keyed by `worker` alone would have kept only the
# colony-b daemon; post-#412 the (colony, role) tuple keeps both.
ALIVE_PID="$$"
DAEMONS_JSON_FILE="$TMPDIR_TEST/daemons.json"
python3 - "$DAEMONS_JSON_FILE" "$ALIVE_PID" <<'PY'
import json, sys
out, alive_pid = sys.argv[1], int(sys.argv[2])
rows = [
    {
        "agent_id": "aaaa1111",
        "source": "colony-a/agents/worker.ag",
        "state": "running",
        "health": "healthy",
        "pid": alive_pid,
        "started_at": 1700000000,
        "tick_ok": 7,
        "tick_err": 0,
    },
    {
        "agent_id": "bbbb2222",
        "source": "colony-b/agents/worker.ag",
        "state": "running",
        "health": "healthy",
        "pid": alive_pid,
        "started_at": 1700000000,
        "tick_ok": 11,
        "tick_err": 0,
    },
]
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

AGENT_MAP_FILE="$TMPDIR_TEST/agent_map.json"
python3 - "$AGENT_MAP_FILE" <<'PY'
import json, sys
out = sys.argv[1]
rows = [
    {"agent": "worker", "colony": "colony-a"},
    {"agent": "worker", "colony": "colony-b"},
]
with open(out, "w", encoding="utf-8") as f:
    json.dump(rows, f)
PY

# --- Run the collector ---
COLLECTOR_OUT="$TMPDIR_TEST/collector.json"
EPOCH="$(date '+%s')"
# Pass `worker` twice in all_agents — mirrors the bin script's flat array
# (no dedup) for an N-colony × M-agents-per-colony tree.
python3 "$COLLECTOR" \
    "@$DAEMONS_JSON_FILE" \
    "$(cat "$AGENT_MAP_FILE")" \
    "$FED_DIR" \
    "$EPOCH" \
    "$FED_DIR/.agentis/experience" \
    "$FED_DIR/.agentis/logs" \
    "$FED_DIR/.dashboard" \
    '["colony-a","colony-b"]' \
    '' \
    "worker" \
    "worker" \
    > "$COLLECTOR_OUT" 2>"$TMPDIR_TEST/collector.err"

if [ ! -s "$COLLECTOR_OUT" ]; then
    fail "1: collector produced empty output" "stderr: $(head -3 "$TMPDIR_TEST/collector.err" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: emitted agents array has exactly 2 records (not 1). ---
AGENT_COUNT="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
print(len(blob.get("agents", [])))
PY
)"
if [ "$AGENT_COUNT" = "2" ]; then
    pass "1: collector emits 2 agent records for 2 colonies × 1 worker each (was 1 pre-#412)"
else
    fail "1: agent record count wrong — expected 2, got $AGENT_COUNT (regression: roles collapsing again)"
fi

# --- Test 2: the two records carry distinct colonies. ---
DISTINCT_COLONIES="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
agents = blob.get("agents", [])
colonies = sorted({a.get("colony", "") for a in agents if a.get("name") == "worker"})
print(",".join(colonies))
PY
)"
if [ "$DISTINCT_COLONIES" = "colony-a,colony-b" ]; then
    pass "2: the two worker records carry distinct colonies (colony-a + colony-b)"
else
    fail "2: distinct-colony assertion failed — expected 'colony-a,colony-b', got '$DISTINCT_COLONIES'"
fi

# --- Test 3: each record binds to its colony's daemon (distinct agent_id). ---
# Pre-#412 both records would have shared the colony-b daemon's agent_id
# because the role_to_daemon dict overwrote on every duplicate key. Post-#412
# the (colony, role) tuple preserves both daemons, so each agent record
# carries its own agent_id.
DISTINCT_AIDS="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
agents = blob.get("agents", [])
# Build (colony, agent_id) pairs and sort for deterministic output.
pairs = sorted(
    (a.get("colony", ""), a.get("agent_id", ""))
    for a in agents if a.get("name") == "worker"
)
print(";".join("%s=%s" % (c, aid) for c, aid in pairs))
PY
)"
if [ "$DISTINCT_AIDS" = "colony-a=aaaa1111;colony-b=bbbb2222" ]; then
    pass "3: each (colony, worker) record binds to its colony's daemon (distinct agent_id)"
else
    fail "3: agent_id binding wrong — expected 'colony-a=aaaa1111;colony-b=bbbb2222', got '$DISTINCT_AIDS'"
fi

# --- Test 4: render the page and confirm both records survive in the HTML. ---
HTML_OUT="$TMPDIR_TEST/index.html"
python3 "$RENDERER" \
    "$TEMPLATE" \
    "$HTML_OUT" \
    "stub-fed" \
    '"stub-fed"' \
    "2" \
    "2" \
    "$EPOCH" \
    "2026-05-02 00:00:00" \
    "@$COLLECTOR_OUT" \
    '[]' \
    '[]' \
    '["colony-a","colony-b"]'

if [ ! -s "$HTML_OUT" ]; then
    fail "4: renderer produced empty index.html"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# Embedded JSON: parse out the COLLECTOR_JSON the JS reads from the page
# and recount. Mirrors the technique in test-dashboard-summary-zombie.sh.
DATA_AGENTS="$(python3 - "$HTML_OUT" <<'PY'
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
print(len(blob.get("agents", [])))
PY
)"
if [ "$DATA_AGENTS" = "2" ]; then
    pass "4: rendered HTML embeds 2 worker records (one per colony)"
else
    fail "4: rendered HTML lost a record — expected 2, got $DATA_AGENTS"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
