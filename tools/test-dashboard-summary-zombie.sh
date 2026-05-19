#!/bin/bash
# tools/test-dashboard-summary-zombie.sh: historical regression marker for
# #300 (the `is_running` derived field contract) + #683 (the swap from
# PID-based to memo-freshness liveness).
#
# Pre-#300 the dashboard summary counted `agents.filter(a => a.state ===
# 'running')`, while per-agent rows used `state === 'running' && pid > 0
# && !pid_alive` to flag dead PIDs. When the federation hit the zombie
# pattern, the top said "21/21 running" while every per-agent row
# rendered as DEAD. #300 introduced the derived `is_running` field
# (`state == 'running' AND pid_alive`) to harmonise the two.
#
# Pre-#683 `pid_alive` came from `os.kill(pid, 0)`. That probe required
# the dashboard to share a PID namespace with the daemons, which is
# false on containerized federations (`research-foundry`,
# `tribes-bench`) — every PID looked dead from the host and the banner
# flipped to DEGRADED even when the agents were ticking happily inside
# the container. #683 swapped the PID probe for an `<agent>:last_check`
# memo-freshness check. The derived `is_running` field name + semantics
# (`state == 'running' AND pid_alive`) are preserved so the template +
# stats-row counter stay byte-identical.
#
# Post-#683 this file is a marker, not a behavioural test:
#   Test 1: the collector source no longer contains `os.kill(pid, 0)`.
#           Catches an accidental revert of the #683 swap.
#   Test 2: every per-agent record still carries the `is_running` key.
#           Catches a regression of the #300 derived-field contract.
#   Test 3: with no `<agent>:last_check` memos seeded, every record
#           reads `pid_alive=False` / `is_running=False`. Confirms the
#           new freshness path's safe default (missing memo → not
#           alive) — equivalent in spirit to the pre-#683 dead-PID
#           outcome.
#   Test 4: the template stats-row counter still uses
#           `agents.filter(a => a.is_running)`. Catches a regression of
#           the #300 template change.
#
# The behavioural assertions for the new memo-freshness logic
# (fresh / stale / missing / containerized) live in
# tools/test-dashboard-freshness-liveness.sh (#683).
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

# --- Test 1: #683 marker — PID-kill code path removed from collector. ---
# Pre-#683 the collector contained `os.kill(pid, 0)` inside the daemon
# loop. That call must no longer appear as executable Python (lines
# starting with `#` are comments and are excluded). The remaining
# matches are explanatory comments documenting the removed probe.
EXEC_OS_KILL_COUNT="$(grep -c -E '^[[:space:]]*os\.kill\(pid, *0\)' "$COLLECTOR" || true)"
if [ "$EXEC_OS_KILL_COUNT" != "0" ]; then
    fail "1: collector still contains an executable 'os.kill(pid, 0)' call — #683 PID-kill removal reverted (found $EXEC_OS_KILL_COUNT)"
else
    pass "1: collector contains no executable 'os.kill(pid, 0)' call (#683 swap intact)"
fi

# --- Synthetic federation fixture for tests 2-4 ---
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

# Generate 21 stub .ag agents so the collector iterates 21 times. No
# `<agent>:last_check` memos are seeded — every record should land on
# the freshness path's missing-memo fallback (`pid_alive=False`).
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
# 10 with PIDs of THIS shell (always alive), 11 with high-numbered PIDs
# that cannot exist. Pre-#683 this drove the 10/11 alive/zombie split;
# post-#683 the PIDs are irrelevant — what matters is the absence of
# `<agent>:last_check` memos.
ALIVE_PID="$$"
DEAD_PID=2147483600
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
    fail "1: collector produced empty output" "stderr: $(head -3 "$TMPDIR_TEST/collector.err" 2>/dev/null | tr '\n' ' ')"
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# --- Test 2: every record carries the is_running key (#300 contract). ---
MISSING="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
miss = [a.get("name", "?") for a in blob.get("agents", []) if "is_running" not in a]
print(len(miss))
PY
)"
if [ "$MISSING" = "0" ]; then
    pass "2: every per-agent record carries the is_running key (#300 derived-field contract intact)"
else
    fail "2: $MISSING per-agent records missing is_running key"
fi

# --- Test 3: no last_check memos seeded → every record reads
# `pid_alive=False` and `is_running=False`. The new freshness path's
# missing-memo default. (Pre-#683 this assertion would have been "10
# true / 11 false" based on PID-kill — the historical zombie split.) ---
COUNT_LINE="$(python3 - "$COLLECTOR_OUT" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    blob = json.load(f)
agents = blob.get("agents", [])
pid_alive_true   = sum(1 for a in agents if a.get("pid_alive") is True)
pid_alive_false  = sum(1 for a in agents if a.get("pid_alive") is False)
is_running_true  = sum(1 for a in agents if a.get("is_running") is True)
is_running_false = sum(1 for a in agents if a.get("is_running") is False)
total = len(agents)
print(f"{pid_alive_true} {pid_alive_false} {is_running_true} {is_running_false} {total}")
PY
)"
PA_TRUE="$(echo  "$COUNT_LINE" | awk '{print $1}')"
PA_FALSE="$(echo "$COUNT_LINE" | awk '{print $2}')"
IR_TRUE="$(echo  "$COUNT_LINE" | awk '{print $3}')"
IR_FALSE="$(echo "$COUNT_LINE" | awk '{print $4}')"
TOTAL="$(echo    "$COUNT_LINE" | awk '{print $5}')"
if [ "$PA_TRUE" = "0" ] && [ "$PA_FALSE" = "21" ] && [ "$IR_TRUE" = "0" ] && [ "$IR_FALSE" = "21" ] && [ "$TOTAL" = "21" ]; then
    pass "3: no last_check memos → 0/21 pid_alive=true, 0/21 is_running=true (memo-freshness missing-memo default)"
else
    fail "3: missing-memo default wrong — pid_alive=$PA_TRUE/$PA_FALSE is_running=$IR_TRUE/$IR_FALSE total=$TOTAL (want 0/21 for all)"
fi

# --- Test 4: template's stats-row predicate still uses is_running. ---
# Direct grep of the template — protects against an accidental revert of
# the #300 consumer-side change.
if grep -q 'agents.filter(a => a.is_running)' "$TEMPLATE"; then
    pass "4: template stats-row counter uses agents.filter(a => a.is_running)"
else
    fail "4: template stats-row counter does not use a.is_running predicate"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
