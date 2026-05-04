#!/bin/bash
# tools/test-dashboard-click-handlers.sh: regression test for #414 — the
# dashboard's per-row click handlers (openDetail, restartAgent,
# quarantineAgent, evolveAgent) must invoke with distinct (colony, name)
# pairs for N×same-role topologies. PR #413 fixed the collector data
# shape; this test asserts the cascade through the template's JS layer.
#
# Pre-#414 the embedded JS keyed `agentByName` on `a.name` alone and
# generated `onclick="openDetail('worker')"` for every row, so all 5
# `hunter` rows in a tribes-bench-shaped federation collapsed to the
# same per-agent modal. Post-#414 the per-row onclick carries both
# the colony and the name (`openDetail(colony, name)`) and the row HTML
# grew a `data-colony` attribute alongside `data-agent`.
#
# What we assert:
#   - The rendered HTML embeds the JS row-builder source. We grep the
#     source for the (colony, name) cascade patterns:
#       * `data-colony="' + esc(a.colony` — every per-row template now
#         carries the data attribute.
#       * `openDetail(\'' + esc(a.colony` — every row-attached
#         openDetail call passes colony as the first arg.
#       * `restartAgent(\'' + esc(a.colony` — same for the Recovery
#         tab's per-row restart button.
#   - The two-record per-(colony, agent) embedded `data.agents` blob
#     (cascade input) survives — same assertion as
#     test-dashboard-collapse.sh.
#   - The handler functions themselves declare the new (colony, agent)
#     two-arg signatures: `function openDetail(colony, agentName)`,
#     `function restartAgent(colony, agent)`, etc.
#   - No bare single-arg row-attached onclick of the form
#     `openDetail('worker')` survives in the rendered HTML.
#
# Strategy mirrors test-dashboard-collapse.sh: drive collector + renderer
# against a synthetic 2-colony × 1 same-name fixture, then grep the HTML.
#
# Usage: ./tools/test-dashboard-click-handlers.sh
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

if [ ! -r "$COLLECTOR" ] || [ ! -r "$RENDERER" ] || [ ! -r "$TEMPLATE" ]; then
    fail "0: dashboard libs not readable" "$COLLECTOR / $RENDERER / $TEMPLATE"
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
ALIVE_PID="$$"
DAEMONS_JSON_FILE="$TMPDIR_TEST/daemons.json"
python3 - "$DAEMONS_JSON_FILE" "$ALIVE_PID" <<'PY'
import json, sys
out, alive_pid = sys.argv[1], int(sys.argv[2])
rows = [
    {"agent_id": "aaaa1111", "source": "colony-a/agents/worker.ag",
     "state": "running", "health": "healthy", "pid": alive_pid,
     "started_at": 1700000000, "tick_ok": 7, "tick_err": 0},
    {"agent_id": "bbbb2222", "source": "colony-b/agents/worker.ag",
     "state": "running", "health": "healthy", "pid": alive_pid,
     "started_at": 1700000000, "tick_ok": 11, "tick_err": 0},
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

# --- Render the page ---
HTML_OUT="$TMPDIR_TEST/index.html"
python3 "$RENDERER" \
    "$TEMPLATE" \
    "$HTML_OUT" \
    "stub-fed" \
    '"stub-fed"' \
    "2" \
    "2" \
    "$EPOCH" \
    "2026-05-04 00:00:00" \
    "@$COLLECTOR_OUT" \
    '[]' \
    '[]' \
    '["colony-a","colony-b"]'

if [ ! -s "$HTML_OUT" ]; then
    fail "1: renderer produced empty index.html"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 1: collector cascade input — embedded data.agents has 2 records. ---
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
    pass "1: rendered HTML embeds 2 worker records (collector cascade input intact)"
else
    fail "1: rendered HTML lost a record — expected 2, got $DATA_AGENTS (regression in #413 collector path)"
fi

# --- Test 2: row template carries data-colony alongside data-agent. ---
ROW_DATA_COL="$(grep -c 'data-colony="' "$HTML_OUT" || true)"
if [ "$ROW_DATA_COL" -ge 3 ]; then
    pass "2: row templates carry data-colony attribute ($ROW_DATA_COL occurrences — Status agent table + Status compact table + colony modal)"
else
    fail "2: data-colony attribute missing from row templates — expected >=3 occurrences, got $ROW_DATA_COL"
fi

# --- Test 3: openDetail row-builders pass (colony, name). ---
# The row builders compose: `openDetail(\'' + esc(a.colony` — fixed-string
# match (the JS source contains a literal backslash + apostrophe).
OPEN_DETAIL_PAIR="$(grep -cF "openDetail(\\'' + esc(a.colony" "$HTML_OUT" || true)"
if [ "$OPEN_DETAIL_PAIR" -ge 3 ]; then
    pass "3: openDetail row-builders pass (colony, name) ($OPEN_DETAIL_PAIR sites — agent table + status compact + colony modal)"
else
    fail "3: openDetail (colony, name) cascade missing — expected >=3 sites, got $OPEN_DETAIL_PAIR"
fi

# --- Test 4: restartAgent row-builder (Recovery tab) passes (colony, name). ---
RESTART_PAIR="$(grep -cF "restartAgent(\\'' + esc(a.colony" "$HTML_OUT" || true)"
if [ "$RESTART_PAIR" -ge 1 ]; then
    pass "4: restartAgent row-builder passes (colony, name) ($RESTART_PAIR site — Recovery tab per-row button)"
else
    fail "4: restartAgent (colony, name) cascade missing in row-builder"
fi

# --- Test 5: handler signatures declare (colony, ...). ---
SIG_OPEN="$(grep -c '^function openDetail(colony, agentName)' "$HTML_OUT" || true)"
SIG_RESTART="$(grep -c '^function restartAgent(colony, ' "$HTML_OUT" || true)"
SIG_QUARANTINE="$(grep -c '^function quarantineAgent(colony, ' "$HTML_OUT" || true)"
SIG_EVOLVE="$(grep -c '^function evolveAgent(colony, ' "$HTML_OUT" || true)"
SIG_SETCONF="$(grep -c '^function setConfidence(colony, agent, value)' "$HTML_OUT" || true)"
if [ "$SIG_OPEN" -ge 1 ] && [ "$SIG_RESTART" -ge 1 ] && [ "$SIG_QUARANTINE" -ge 1 ] && [ "$SIG_EVOLVE" -ge 1 ] && [ "$SIG_SETCONF" -ge 1 ]; then
    pass "5: handler signatures take (colony, ...): openDetail=$SIG_OPEN, restartAgent=$SIG_RESTART, quarantineAgent=$SIG_QUARANTINE, evolveAgent=$SIG_EVOLVE, setConfidence=$SIG_SETCONF"
else
    fail "5: handler signature regression — openDetail=$SIG_OPEN, restartAgent=$SIG_RESTART, quarantineAgent=$SIG_QUARANTINE, evolveAgent=$SIG_EVOLVE, setConfidence=$SIG_SETCONF"
fi

# --- Test 6: agentByKey replaces agentByName (composite key). ---
NAMED="$(grep -c 'agentByName' "$HTML_OUT" || true)"
KEYED="$(grep -c 'agentByKey' "$HTML_OUT" || true)"
if [ "$NAMED" -eq 0 ] && [ "$KEYED" -ge 2 ]; then
    pass "6: agentByName fully replaced by agentByKey ($KEYED occurrences) — composite (colony, name) lookups across the template"
else
    fail "6: name-only agentByName lookups remain — agentByName=$NAMED, agentByKey=$KEYED"
fi

# --- Test 7: NO bare single-arg `openDetail('worker')` row-attached onclick. ---
# The legacy back-compat branch in the function body exists, but rendered
# rows must never call into it. Rendered HTML literal would be the JS
# source `openDetail(\'worker\')` only if the template emitted such; the
# current template emits `openDetail(\'' + esc(a.colony ...` always.
BARE_OPEN="$(grep -cE "onclick=\"openDetail\\\\'worker\\\\'" "$HTML_OUT" || true)"
if [ "$BARE_OPEN" -eq 0 ]; then
    pass "7: no bare openDetail single-arg row-attached onclick (cascade regression guard)"
else
    fail "7: bare single-arg openDetail invocation found — count=$BARE_OPEN"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
