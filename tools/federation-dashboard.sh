#!/bin/bash
# federation-dashboard.sh - Web dashboard for any Agentis federation
#
# Auto-discovers colonies and agents from the federation directory
# structure. Collects data from the agentis CLI, generates a static
# HTML page, and serves it with a built-in kill switch.
#
# Usage: ./tools/federation-dashboard.sh <federation-dir> [port]
#        ./tools/federation-dashboard.sh dev-apprenticeship
#        ./tools/federation-dashboard.sh dev-apprenticeship 9000
#
# The federation directory must contain colony subdirectories, each
# with agents/*.ag files and config/colony.toml.
#
# Prerequisites: agentis, python3

set -e

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <federation-dir> [port]"
    echo "Example: $0 dev-apprenticeship"
    exit 1
fi

FED_DIR="$REPO_ROOT/$1"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$1"  # try as absolute/relative path
fi
if [ ! -d "$FED_DIR" ]; then
    echo "Federation directory not found: $1"
    exit 1
fi

PORT="${2:-8420}"
FED_NAME="$(basename "$FED_DIR")"
DASH_DIR="$FED_DIR/.dashboard"
HTML_FILE="$DASH_DIR/index.html"
HISTORY_FILE="$DASH_DIR/history.json"

mkdir -p "$DASH_DIR"

if [ ! -f "$HISTORY_FILE" ]; then
    echo '[]' > "$HISTORY_FILE"
fi

# --- Auto-discover colonies and agents ---

discover() {
    COLONIES=()
    ALL_AGENTS=()
    AGENT_COLONY_MAP=""  # agent:colony pairs for JS

    for colony_dir in "$FED_DIR"/*/; do
        [ -d "${colony_dir}agents" ] || continue
        local colony_name
        colony_name="$(basename "$colony_dir")"
        COLONIES+=("$colony_name")

        for ag_file in "${colony_dir}agents/"*.ag; do
            [ -f "$ag_file" ] || continue
            local agent_name
            agent_name="$(basename "$ag_file" .ag)"
            ALL_AGENTS+=("$agent_name")
            AGENT_COLONY_MAP="${AGENT_COLONY_MAP}{\"agent\":\"${agent_name}\",\"colony\":\"${colony_name}\"},"
        done
    done
    AGENT_COLONY_MAP="[${AGENT_COLONY_MAP%,}]"

    COLONY_COUNT="${#COLONIES[@]}"
    AGENT_COUNT="${#ALL_AGENTS[@]}"
}

discover

if [ "$COLONY_COUNT" -eq 0 ]; then
    echo "No colonies found in $FED_DIR"
    exit 1
fi

echo ""
echo "Federation Dashboard: $FED_NAME"
echo "Discovered: $COLONY_COUNT colonies, $AGENT_COUNT agents"
echo ""

# --- Collect data and generate HTML ---

generate() {
    local TIMESTAMP
    TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S')"
    local EPOCH
    EPOCH="$(date '+%s')"
    # Per-PID temp file so concurrent generate() invocations (60 s background
    # loop + POST /refresh subprocess, see #98) don't stomp on each other or
    # let a SimpleHTTPRequestHandler read a half-written index.html. Final
    # `mv` below is atomic on the same filesystem.
    local HTML_TMP="$HTML_FILE.tmp.$$"

    local DAEMONS
    DAEMONS="$(agentis daemon list --json 2>/dev/null || echo '[]')"

    # Count experience entries per colony.
    #
    # #111: the dashboard used to call `agentis knowledge list`, but agents
    # write with `learn(...)` which persists to `.agentis/experience/`, not
    # the knowledge base. Two parallel stores, two parallel CLIs — the
    # knowledge counter was always 0 on a real federation. We now count
    # JSONL line entries in the experience dir and aggregate per colony via
    # the daemon's own `colony` field. The output JSON shape is still
    # `{total, <col>}` for compatibility with history.json and the HTML
    # chart.
    #
    # Experience files are named by daemon-assigned `agent_id` (opaque hex,
    # see src/cli/daemon.rs:907), not the `.ag` basename. We map back via
    # `agentis daemon list --json`: for daemons started with `--colony`
    # (which `start-colony.sh` always does) the `colony` field is
    # authoritative. For daemons started without it we fall back to
    # basename(source, .ag) → AGENT_COLONY_MAP, which is lossy when two
    # colonies ship an agent with the same filename but is the best we can
    # do for bare `agentis daemon <file>` invocations.
    local COLONY_LIST_PY=""
    for col in "${COLONIES[@]}"; do
        COLONY_LIST_PY="${COLONY_LIST_PY}\"${col}\","
    done
    COLONY_LIST_PY="[${COLONY_LIST_PY%,}]"

    # Match the LOG_DIR convention (line 187): prefer $FED_DIR/../.agentis,
    # fall back to cwd-relative for operators invoking from the federation
    # root. Experience dir existence is re-checked inside python so a
    # missing path degrades to zeros rather than crashing.
    local EXPERIENCE_DIR="${FED_DIR}/../.agentis/experience"
    if [ ! -d "$EXPERIENCE_DIR" ]; then
        EXPERIENCE_DIR=".agentis/experience"
    fi

    local EXPERIENCE_COUNTS
    EXPERIENCE_COUNTS="$(python3 - "$EXPERIENCE_DIR" "$DAEMONS" "$AGENT_COLONY_MAP" "$COLONY_LIST_PY" <<'PY' 2>/dev/null
import sys, os, json
exp_dir, daemons_json, map_json, colony_list_json = sys.argv[1:5]
try:
    daemons = json.loads(daemons_json)
except (json.JSONDecodeError, ValueError):
    daemons = []
try:
    agent_map = json.loads(map_json)
except (json.JSONDecodeError, ValueError):
    agent_map = []
try:
    colonies = json.loads(colony_list_json)
except (json.JSONDecodeError, ValueError):
    colonies = []
# Basename-keyed fallback for daemons launched without --colony. Collisions
# (same .ag filename across two colonies) silently last-writer-wins here,
# which is a known limitation; the authoritative path uses d["colony"].
name_to_colony = {e.get("agent", ""): e.get("colony", "") for e in agent_map}
counts = {c: 0 for c in colonies}
counts["total"] = 0
if os.path.isdir(exp_dir):
    for d in daemons:
        agent_id = d.get("agent_id") or ""
        if not agent_id:
            continue
        colony = d.get("colony") or ""
        if not colony:
            source = d.get("source") or ""
            if source:
                name = os.path.basename(source)
                if name.endswith(".ag"):
                    name = name[:-3]
                colony = name_to_colony.get(name, "")
        if not colony or colony not in counts:
            continue
        path = os.path.join(exp_dir, agent_id + ".jsonl")
        if not os.path.isfile(path):
            continue
        n = 0
        try:
            with open(path) as f:
                for line in f:
                    if line.strip():
                        n += 1
        except OSError:
            continue
        counts[colony] += n
        counts["total"] += n
print(json.dumps(counts))
PY
)"
    # The python block is wrapped in try/except for every input, so a bad
    # arg silently yields `{"total":0,...}` — but if the interpreter itself
    # dies (SIGKILL, disk full, bad shebang) we get an empty string and the
    # `const experienceCounts = ${EXPERIENCE_COUNTS};` injection below would
    # produce a JS syntax error that breaks every other IIFE on the page.
    # Validate the result parses as JSON; on failure, substitute the same
    # shape the python block emits on empty input.
    if ! echo "$EXPERIENCE_COUNTS" | python3 -c 'import sys, json; json.loads(sys.stdin.read())' 2>/dev/null; then
        EXPERIENCE_COUNTS='{"total":0}'
    fi

    local REMEDIATION
    REMEDIATION="$(agentis remediation history --limit 5 --json 2>/dev/null || echo '[]')"

    # Confidence values. `agentis memo get` on a missing key exits 0 with
    # empty stdout (not non-zero), so `|| echo ''` is not what catches the
    # missing-key case — the `${conf:-0.0}` default on the next line is
    # (#96). But the `|| echo ''` is still needed to keep the script
    # running under `set -e` (L17) if `agentis` itself exits non-zero
    # (binary missing, store lock contention, etc.).
    local CONFIDENCES=""
    for i in "${!ALL_AGENTS[@]}"; do
        local agent="${ALL_AGENTS[$i]}"
        local conf
        conf="$(agentis memo get "${agent}:confidence" 2>/dev/null || echo '')"
        CONFIDENCES="${CONFIDENCES}${conf:-0.0},"
    done
    CONFIDENCES="[${CONFIDENCES%,}]"

    # Recent suggestions
    local LOG_DIR="${FED_DIR}/../.agentis/logs"
    if [ ! -d "$LOG_DIR" ]; then
        LOG_DIR=".agentis/logs"
    fi
    local SUGGESTIONS="[]"
    if [ -d "$LOG_DIR" ]; then
        SUGGESTIONS="$(grep -ihE 'suggest|draft|finding' "$LOG_DIR"/*.log 2>/dev/null | tail -50 | python3 -c '
import sys, json
lines = [line.strip() for line in sys.stdin if line.strip()]
print(json.dumps(lines))
' 2>/dev/null || echo '[]')"
    fi

    # Append to history
    python3 - "$HISTORY_FILE" "$EPOCH" "$EXPERIENCE_COUNTS" "$CONFIDENCES" "$AGENT_COLONY_MAP" <<'PY'
import sys, os, json
def _safe_json(s, default, label):
    try:
        return json.loads(s)
    except (json.JSONDecodeError, TypeError, ValueError) as e:
        # Surface real breakages (daemon crash, store corruption) rather
        # than silently rendering "0 entries" forever. On a fresh
        # federation the inputs are legitimately empty strings and
        # `json.loads("")` fails — that is expected and noisy but
        # short-lived (one tick per agent until memos are seeded).
        sys.stderr.write(f"[dashboard] {label} parse failed: {e}; using default\n")
        return default
path, epoch = sys.argv[1], int(sys.argv[2])
# Defensive parse: on a fresh federation any of these shell-assembled JSON
# blobs may be malformed (see #96). Fall back to empty structures so the
# dashboard still renders — the resulting history entry just has empty
# `experience` / `confidence` fields for this tick.
ec = _safe_json(sys.argv[3], {"total": 0}, "experience_counts")
conf_vals = _safe_json(sys.argv[4], [], "confidences")
agent_map = _safe_json(sys.argv[5], [], "agent_colony_map")
try:
    with open(path) as f:
        history = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    history = []
colony_conf = {}
colony_count = {}
for i, am in enumerate(agent_map):
    col = am["colony"]
    v = conf_vals[i] if i < len(conf_vals) else 0.0
    colony_conf[col] = colony_conf.get(col, 0) + v
    colony_count[col] = colony_count.get(col, 0) + 1
avg_conf = {col: round(colony_conf[col] / colony_count[col], 3) for col in colony_conf if colony_count[col]}
# #111: the history key is `experience` now (previously `knowledge`, which
# was always 0 because of the wrong CLI). Old history entries from v1.1.8
# and earlier will be missing this field and silently skipped by the
# Experience Growth chart — acceptable, since those entries recorded zeros.
entry = {"t": epoch, "experience": ec, "confidence": avg_conf}
history.append(entry)
cutoff = epoch - 7 * 86400
history = [h for h in history if h["t"] > cutoff]
# Per-PID temp + os.replace: atomic on the same filesystem so concurrent
# generate() writers don't leave a partially-written history.json readable.
tmp = f"{path}.tmp.{os.getpid()}"
with open(tmp, "w") as f:
    json.dump(history, f)
os.replace(tmp, path)
PY

    local HISTORY
    HISTORY="$(cat "$HISTORY_FILE" 2>/dev/null || echo '[]')"

    # Build JS-friendly agent data by merging map + confidence values
    local AGENT_DATA=""
    for i in "${!ALL_AGENTS[@]}"; do
        local agent="${ALL_AGENTS[$i]}"
        local conf_val
        conf_val="$(echo "$CONFIDENCES" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[$i])" 2>/dev/null || echo "0.0")"
        local colony
        colony="$(echo "$AGENT_COLONY_MAP" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())[$i]['colony'])" 2>/dev/null || echo "")"
        AGENT_DATA="${AGENT_DATA}{\"agent\":\"${agent}\",\"colony\":\"${colony}\",\"confidence\":${conf_val}},"
    done
    AGENT_DATA="[${AGENT_DATA%,}]"

    local COLONY_LIST_JS=""
    for col in "${COLONIES[@]}"; do
        COLONY_LIST_JS="${COLONY_LIST_JS}\"${col}\","
    done
    COLONY_LIST_JS="[${COLONY_LIST_JS%,}]"

    {
    cat <<HEADEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta http-equiv="refresh" content="60">
<title>${FED_NAME} // Agentis Federation</title>
HEADEOF
    cat <<'HTMLEOF'
<style>
  @import url('https://fonts.googleapis.com/css2?family=Share+Tech+Mono&display=swap');
  :root {
    --bg: #0a0a0a; --surface: rgba(0,0,0,0.85); --border: rgba(0,255,255,0.2);
    --text: #c0e8e8; --muted: rgba(0,255,255,0.4); --cyan: #00ffff;
    --green: #00ff00; --yellow: #ffff00; --red: #ff4444;
    --magenta: #ff00ff; --orange: #ff8800; --copper: #b87333;
    --grid: rgba(0,100,150,0.07);
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: var(--bg); color: var(--text);
    font-family: 'Share Tech Mono', 'Courier New', monospace;
    font-size: 13px; padding: 24px; line-height: 1.6;
    background-image:
      linear-gradient(var(--grid) 1px, transparent 1px),
      linear-gradient(90deg, var(--grid) 1px, transparent 1px);
    background-size: 50px 50px;
    min-height: 100vh;
  }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 24px; padding-bottom: 16px;
    border-bottom: 1px solid var(--border);
  }
  .header-left h1 {
    font-size: 22px; font-weight: 400; color: var(--cyan);
    text-shadow: 0 0 20px rgba(0,255,255,0.5);
    letter-spacing: 2px; text-transform: uppercase;
  }
  .header-left .subtitle {
    font-size: 11px; color: var(--muted); letter-spacing: 4px;
    text-transform: uppercase; margin-top: 2px;
  }
  .header-right { text-align: right; font-size: 11px; color: var(--muted); }
  .header-right .time { color: var(--cyan); font-size: 13px; text-shadow: 0 0 8px rgba(0,255,255,0.3); }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
  .card {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 4px; padding: 16px;
    box-shadow: 0 0 15px rgba(0,255,255,0.05);
    backdrop-filter: blur(4px);
  }
  .card.full { grid-column: 1 / -1; }
  .card h2 {
    font-size: 12px; font-weight: 400; color: var(--yellow);
    text-transform: uppercase; letter-spacing: 3px;
    margin-bottom: 12px; padding-bottom: 6px;
    border-bottom: 1px solid rgba(255,255,0,0.15);
    text-shadow: 0 0 8px rgba(255,255,0,0.3);
  }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th {
    text-align: left; padding: 4px 8px; color: var(--muted); font-weight: 400;
    font-size: 10px; text-transform: uppercase; letter-spacing: 1px;
    border-bottom: 1px solid var(--border);
  }
  td { padding: 5px 8px; border-bottom: 1px solid rgba(0,255,255,0.05); }
  tr:last-child td { border-bottom: none; }
  tr:hover td { background: rgba(0,255,255,0.03); }
  .agent-name { color: var(--cyan); text-shadow: 0 0 6px rgba(0,255,255,0.2); }
  .colony-name { color: var(--copper); }
  .badge {
    display: inline-block; padding: 1px 8px; border-radius: 2px;
    font-size: 10px; letter-spacing: 1px; text-transform: uppercase;
  }
  .badge-running { border: 1px solid var(--green); color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.3); }
  .badge-stopped { border: 1px solid var(--red); color: var(--red); }
  .badge-healthy { border: 1px solid var(--green); color: var(--green); }
  .badge-degraded { border: 1px solid var(--yellow); color: var(--yellow); }
  .badge-error { border: 1px solid var(--red); color: var(--red); }
  .badge-quarantine { border: 1px solid var(--magenta); color: var(--magenta); text-shadow: 0 0 6px rgba(255,0,255,0.3); }
  .badge-observe { border: 1px solid var(--muted); color: var(--muted); }
  .badge-suggest { border: 1px solid var(--yellow); color: var(--yellow); text-shadow: 0 0 6px rgba(255,255,0,0.3); }
  .badge-act { border: 1px solid var(--green); color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.3); }
  .conf-bar-bg { height: 6px; background: rgba(0,255,255,0.08); border-radius: 3px; overflow: hidden; margin-top: 2px; }
  .conf-bar-fill { height: 100%; border-radius: 3px; transition: width 0.5s; }
  .phase-row { display: flex; align-items: center; gap: 12px; margin: 8px 0; }
  .phase-colony { width: 120px; flex-shrink: 0; color: var(--cyan); font-size: 12px; text-shadow: 0 0 6px rgba(0,255,255,0.2); }
  .phase-bar-outer {
    flex: 1; height: 24px; background: rgba(0,255,255,0.05);
    border: 1px solid var(--border); border-radius: 2px; position: relative;
  }
  .phase-bar-inner {
    height: 100%; border-radius: 1px; transition: width 0.5s;
    display: flex; align-items: center; justify-content: flex-end;
    padding-right: 8px; font-size: 11px;
  }
  .phase-marker { position: absolute; top: -2px; bottom: -2px; width: 1px; border-left: 1px dashed rgba(255,255,255,0.2); }
  .phase-marker-label { position: absolute; top: -16px; font-size: 9px; color: var(--muted); transform: translateX(-50%); white-space: nowrap; }
  .phase-eta { width: 140px; flex-shrink: 0; text-align: right; font-size: 11px; color: var(--muted); }
  .chart-container { margin: 8px 0; }
  .chart-legend { display: flex; gap: 16px; margin-top: 8px; font-size: 11px; flex-wrap: wrap; }
  .chart-legend span { display: flex; align-items: center; gap: 4px; }
  .legend-dot { width: 8px; height: 8px; border-radius: 1px; display: inline-block; }
  .log-feed { max-height: 260px; overflow-y: auto; font-size: 11px; color: var(--muted); line-height: 1.8; }
  .log-feed div { padding: 2px 0; border-bottom: 1px solid rgba(0,255,255,0.03); }
  .log-feed div:hover { color: var(--cyan); }
  .empty { color: var(--muted); font-style: italic; font-size: 11px; }
  .colony-header { font-size: 10px; color: var(--copper); text-transform: uppercase; letter-spacing: 2px; padding: 8px 8px 4px; text-shadow: 0 0 6px rgba(184,115,51,0.3); }
  .stats-row { display: flex; gap: 24px; margin-bottom: 16px; }
  .stat-box {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 4px; padding: 12px 16px; flex: 1; text-align: center;
    box-shadow: 0 0 15px rgba(0,255,255,0.05);
  }
  .stat-value { font-size: 28px; color: var(--cyan); text-shadow: 0 0 15px rgba(0,255,255,0.4); }
  .stat-label { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 4px; }
  .refresh-btn {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: inherit; font-size: 12px;
    padding: 0 6px; cursor: pointer; border-radius: 2px;
    line-height: 1.4; vertical-align: middle;
    transition: color 0.15s, border-color 0.15s, transform 0.15s;
  }
  .refresh-btn:hover { color: var(--cyan); border-color: var(--cyan); }
  .refresh-btn.spinning { animation: spin 0.6s linear infinite; }
  @keyframes spin {
    from { transform: rotate(0deg); } to { transform: rotate(360deg); }
  }
  .conf-btn {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: inherit; font-size: 10px;
    padding: 1px 6px; margin-right: 2px; cursor: pointer;
    border-radius: 2px; line-height: 1.4;
    transition: color 0.15s, border-color 0.15s;
  }
  .conf-btn:hover:not(:disabled) { color: var(--cyan); border-color: var(--cyan); }
  .conf-btn:disabled { opacity: 0.25; cursor: not-allowed; }
  .conf-btn-act { border-color: var(--green); color: var(--green); }
  .conf-btn-act:hover:not(:disabled) { background: var(--green); color: #000; box-shadow: 0 0 8px rgba(0,255,0,0.4); }
  .kill-btn {
    background: transparent; border: 2px solid var(--red);
    color: var(--red); font-family: 'Share Tech Mono', monospace;
    font-size: 11px; padding: 6px 16px; cursor: pointer;
    text-transform: uppercase; letter-spacing: 2px;
    border-radius: 2px; transition: all 0.2s;
  }
  .kill-btn:hover { background: var(--red); color: #000; box-shadow: 0 0 20px rgba(255,68,68,0.5); }
  .kill-btn:active { transform: scale(0.95); }
  .kill-btn.confirm { border-color: var(--magenta); color: var(--magenta); animation: pulse-kill 0.8s infinite; }
  .kill-btn.confirm:hover { background: var(--magenta); color: #000; box-shadow: 0 0 30px rgba(255,0,255,0.6); }
  .kill-btn.killed { border-color: var(--muted); color: var(--muted); cursor: default; pointer-events: none; }
  @keyframes pulse-kill {
    0%, 100% { box-shadow: 0 0 10px rgba(255,0,255,0.3); }
    50% { box-shadow: 0 0 25px rgba(255,0,255,0.6); }
  }
  .toast {
    position: fixed; right: 16px; bottom: 16px; z-index: 9999;
    max-width: 420px; padding: 12px 14px 12px 16px;
    background: var(--surface); border: 1px solid var(--yellow);
    border-radius: 4px; color: var(--text);
    font-family: 'Share Tech Mono', 'Courier New', monospace;
    font-size: 12px; line-height: 1.6;
    box-shadow: 0 0 20px rgba(255,255,0,0.35);
    cursor: pointer;
    animation: toast-in 0.25s ease-out;
  }
  .toast.toast-ok { border-color: var(--green); box-shadow: 0 0 20px rgba(0,255,0,0.35); }
  .toast.toast-err { border-color: var(--red); box-shadow: 0 0 20px rgba(255,68,68,0.4); }
  .toast .toast-head {
    color: var(--yellow); font-size: 11px; letter-spacing: 2px;
    text-transform: uppercase; margin-bottom: 6px;
    text-shadow: 0 0 6px rgba(255,255,0,0.4);
  }
  .toast.toast-ok .toast-head { color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.4); }
  .toast.toast-err .toast-head { color: var(--red); text-shadow: 0 0 6px rgba(255,68,68,0.4); }
  .toast pre {
    margin: 6px 0; padding: 6px 8px; background: rgba(0,255,255,0.05);
    border-left: 2px solid var(--cyan); color: var(--cyan);
    font-size: 11px; white-space: pre-wrap; word-break: break-all;
  }
  .toast .toast-foot { color: var(--muted); font-size: 10px; margin-top: 6px; }
  .toast .toast-step {
    display: flex; align-items: center; gap: 8px;
    font-size: 11px; margin: 2px 0; color: var(--muted);
  }
  .toast .toast-step.active { color: var(--yellow); text-shadow: 0 0 4px rgba(255,255,0,0.3); }
  .toast .toast-step.done { color: var(--green); }
  .toast .toast-step.err { color: var(--red); }
  .toast .toast-spin {
    display: inline-block; width: 10px; height: 10px;
    border: 1px solid rgba(255,255,0,0.2); border-top-color: var(--yellow);
    border-radius: 50%; animation: spin 0.8s linear infinite;
  }
  @keyframes toast-in {
    from { opacity: 0; transform: translateY(8px); }
    to   { opacity: 1; transform: translateY(0); }
  }
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
</style>
</head>
<body>
HTMLEOF
    } > "$HTML_TMP"

    {
    cat <<HEADEREOF
<div class="header">
  <div class="header-left">
    <h1>${FED_NAME}</h1>
    <div class="subtitle">Agentis Federation // ${COLONY_COUNT} colonies // ${AGENT_COUNT} agents</div>
  </div>
  <div class="header-right" style="display:flex;align-items:center;gap:16px;">
    <div>
      <div class="time" id="clock"></div>
      <div><span id="countdown">auto-refresh in 60s</span> <button class="refresh-btn" id="refresh-btn" onclick="manualRefresh()" title="Refresh now (press 'r')" aria-label="Refresh now">&#x21bb;</button></div>
    </div>
    <button class="kill-btn" id="kill-btn" onclick="killSwitch()">Kill Federation</button>
  </div>
</div>
HEADEREOF

    cat <<'HTMLEOF'
<div class="stats-row" id="stats-row"></div>

<div class="grid">

<div class="card full">
<h2>Phase Readiness</h2>
<div id="readiness"></div>
</div>

<div class="card">
<h2>Agents</h2>
<div id="agents" style="max-height:400px;overflow-y:auto;"></div>
</div>

<div class="card">
<h2>Confidence Levels</h2>
<div id="confidence" style="max-height:400px;overflow-y:auto;"></div>
</div>

<div class="card">
<h2>Experience Growth</h2>
<div id="experience-trend" class="chart-container"></div>
</div>

<div class="card">
<h2>Remediation</h2>
<div id="remediation"></div>
</div>

<div class="card full">
<h2>Suggestion Feed</h2>
<div id="suggestions" class="log-feed"></div>
</div>

</div>

<script>
HTMLEOF

    # Inject data
    cat <<DATAEOF
const daemons = ${DAEMONS};
const confidences = ${AGENT_DATA};
const colonyList = ${COLONY_LIST_JS};
const suggestions = ${SUGGESTIONS};
const remediation = ${REMEDIATION};
const experienceCounts = ${EXPERIENCE_COUNTS};
const history = ${HISTORY};
const nowEpoch = ${EPOCH};
const timestamp = "${TIMESTAMP}";
const totalAgents = ${AGENT_COUNT};
DATAEOF

    cat <<'JSEOF'

// Auto-assign colors to colonies
const palette = ['#58a6ff','#00ff00','#ffff00','#ff8800','#ff00ff','#00ffcc','#ff6666','#aa88ff'];
const colonyColors = {};
colonyList.forEach((c, i) => colonyColors[c] = palette[i % palette.length]);

document.getElementById('clock').textContent = timestamp;

// --- Refresh countdown ---
// The meta-refresh fires 60 s after the page loads. Mirror that here so
// the operator always knows when the next reload happens and can trigger
// one manually (button or 'r' key).
(function() {
  const REFRESH_MS = 60000;
  const el = document.getElementById('countdown');
  if (!el) return;
  const loadedAt = Date.now();
  function tick() {
    const remaining = Math.max(0, REFRESH_MS - (Date.now() - loadedAt));
    const s = Math.ceil(remaining / 1000);
    el.textContent = 'auto-refresh in ' + String(Math.floor(s/60)).padStart(2,'0') + ':' + String(s%60).padStart(2,'0');
  }
  tick();
  setInterval(tick, 1000);
})();

function manualRefresh() {
  const btn = document.getElementById('refresh-btn');
  if (btn) btn.classList.add('spinning');
  // #98: ask the server to regenerate the static HTML snapshot before we
  // reload. The background loop only runs every 60 s, so without this POST
  // a manual refresh would just re-render the stale on-disk file. Errors
  // are swallowed — reload anyway so the operator sees *something* rather
  // than a wedged spinner.
  fetch('/refresh', { method: 'POST' })
    .catch(() => {})
    .finally(() => location.reload());
}

document.addEventListener('keydown', (e) => {
  // Ignore Ctrl/Meta/Alt/Shift combinations (browser reserves Ctrl-R,
  // Shift-R is a legitimate uppercase R the operator may type elsewhere)
  // and held-down repeats so a single press only fires one reload.
  if (e.key === 'r' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && !e.repeat) {
    const tag = (e.target && e.target.tagName) || '';
    // Don't steal 'r' from text fields or contenteditable regions.
    if (tag === 'INPUT' || tag === 'TEXTAREA' || (e.target && e.target.isContentEditable)) return;
    e.preventDefault();
    manualRefresh();
  }
});

// --- Stats row ---
(function() {
  const el = document.getElementById('stats-row');
  const running = daemons.filter(d => (d.state || d.STATE || '') === 'running').length;
  const totalExperience = experienceCounts.total || 0;
  let avgConf = 0;
  confidences.forEach(c => avgConf += c.confidence);
  avgConf = confidences.length ? (avgConf / confidences.length) : 0;
  const phase = avgConf >= 0.85 ? 'AUTONOMOUS' : avgConf >= 0.6 ? 'SUGGEST' : 'OBSERVE';
  const quarantined = daemons.filter(d => (d.quarantine || d.QUARANTINE || '') === 'yes').length;
  el.innerHTML =
    '<div class="stat-box"><div class="stat-value">' + running + '/' + totalAgents + '</div><div class="stat-label">Agents Running</div></div>' +
    '<div class="stat-box"><div class="stat-value" style="color:' + (avgConf >= 0.85 ? 'var(--green)' : avgConf >= 0.6 ? 'var(--yellow)' : 'var(--cyan)') + '">' + avgConf.toFixed(2) + '</div><div class="stat-label">Avg Confidence // ' + phase + '</div></div>' +
    '<div class="stat-box"><div class="stat-value">' + totalExperience + '</div><div class="stat-label">Experience Entries</div></div>' +
    '<div class="stat-box"><div class="stat-value" style="color:' + (quarantined > 0 ? 'var(--magenta)' : 'var(--green)') + '">' + quarantined + '</div><div class="stat-label">Quarantined</div></div>';
})();

// --- Agents table ---
(function() {
  const el = document.getElementById('agents');
  if (!daemons.length) { el.innerHTML = '<span class="empty">No running daemons. Start federation first.</span>'; return; }
  let html = '<table><tr><th>Agent</th><th>State</th><th>Health</th><th>Colony</th></tr>';
  daemons.forEach(d => {
    const state = d.state || d.STATE || 'unknown';
    const health = d.health || d.HEALTH || 'unknown';
    const colony = d.colony || d.COLONY || '';
    const quar = d.quarantine || d.QUARANTINE || '';
    const name = d.name || d.agent_id || d.source || '';
    const sc = state === 'running' ? 'running' : 'stopped';
    const hc = quar === 'yes' ? 'quarantine' : (health === 'healthy' ? 'healthy' : health === 'degraded' ? 'degraded' : 'error');
    html += '<tr><td class="agent-name">' + name + '</td>';
    html += '<td><span class="badge badge-' + sc + '">' + state + '</span></td>';
    html += '<td><span class="badge badge-' + hc + '">' + (quar === 'yes' ? 'quarantine' : health) + '</span></td>';
    html += '<td class="colony-name">' + colony + '</td></tr>';
  });
  html += '</table>';
  el.innerHTML = html;
})();

// --- Confidence per agent ---
// #105: bump up/down buttons let the operator walk through the three
// canonical steps (0.5 observe → 0.6 suggest → 0.85 autonomous) without
// shelling out to `agentis memo set`. Promotions to ≥ 0.85 get a confirm()
// dialog (two-click safety, mirrors the Kill Federation precedent from #91).
const CONF_STEPS = [0.5, 0.6, 0.85];
function nextStep(cur, dir) {
  // Snap current value to the nearest step, then move by one. Returning
  // null means "already at the boundary" and the caller disables the button.
  let idx = 0;
  let best = Math.abs(cur - CONF_STEPS[0]);
  for (let i = 1; i < CONF_STEPS.length; i++) {
    const d = Math.abs(cur - CONF_STEPS[i]);
    if (d < best) { best = d; idx = i; }
  }
  const target = idx + dir;
  if (target < 0 || target >= CONF_STEPS.length) return null;
  return CONF_STEPS[target];
}

function setConfidence(agent, value) {
  // ≥ 0.85 unlocks autonomous GitLab writes (MRs, comments, labels). Make
  // the operator confirm before the button bumps the agent into act mode.
  if (value >= 0.85) {
    if (!confirm('Promote ' + agent + ' to ' + value.toFixed(2) + ' (AUTONOMOUS)?\n\nAt this level the agent will act directly on GitLab — posting comments, applying labels, opening MRs, approving reviews. Proceed?')) {
      return;
    }
  }
  // The page has <meta http-equiv="refresh" content="60"> in <head>. Auto-
  // restart takes up to ~30 s end-to-end and we want the result toast to
  // stay readable — same rationale as the kill-switch handler.
  const m = document.querySelector('meta[http-equiv="refresh"]');
  if (m) m.remove();

  const toast = createProgressToast(agent, value);
  // Client-side timers narrate stages the server does not stream (the
  // /confidence POST is a single synchronous request because HTTPServer is
  // single-threaded and SSE adds more moving parts than this operator
  // tool warrants). If the real response lands before a given timer, the
  // real terminal state wins — see applyResult() below.
  // Timers spread to match the server worst case: stop can take up to
  // 12 s (5 s poll + 5 s SIGTERM + 2 s SIGKILL), spawn ~1 s, verify up
  // to 15 s. We advance optimistically; the real terminal state wins on
  // server response regardless.
  const t1 = setTimeout(() => toast.setStep('stop', 'active'), 400);
  const t2 = setTimeout(() => { toast.setStep('stop', 'done'); toast.setStep('spawn', 'active'); }, 12000);
  const t3 = setTimeout(() => { toast.setStep('spawn', 'done'); toast.setStep('verify', 'active'); }, 15000);
  const clearFakes = () => { clearTimeout(t1); clearTimeout(t2); clearTimeout(t3); };

  const body = 'agent=' + encodeURIComponent(agent) + '&value=' + encodeURIComponent(value);
  fetch('/confidence', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: body,
  })
    .then(r => {
      // 200 returns application/json; 4xx/5xx return text/plain.
      if (r.ok) return r.json().then(data => ({ok: true, data}));
      return r.text().then(text => ({ok: false, text}));
    })
    .then(result => {
      clearFakes();
      if (!result.ok) {
        toast.renderHttpError(result.text);
        scheduleReload(30000);
        return;
      }
      toast.applyResult(result.data);
      const succeeded = result.data && result.data.restart && result.data.restart.succeeded;
      scheduleReload(succeeded ? 12000 : 30000);
    })
    .catch(e => {
      clearFakes();
      toast.renderHttpError(String(e));
      scheduleReload(30000);
    });
}

function scheduleReload(delayMs) {
  // Defer the static-HTML regen + reload so the result toast stays
  // readable. Success uses the Option 1 12 s window; failure gives the
  // operator 30 s to copy the manual-respawn command before reload.
  setTimeout(() => {
    fetch('/refresh', { method: 'POST' }).catch(() => {}).finally(() => location.reload());
  }, delayMs);
}

function createProgressToast(agent, requestedValue) {
  const el = document.createElement('div');
  el.className = 'toast';
  el.setAttribute('role', 'status');
  el.setAttribute('aria-live', 'polite');

  const head = document.createElement('div');
  head.className = 'toast-head';
  head.textContent = 'Auto-restart: ' + agent + ' = ' + requestedValue.toFixed(2);
  el.appendChild(head);

  const stepsBox = document.createElement('div');
  const steps = {};
  function addStep(key, label) {
    const row = document.createElement('div');
    row.className = 'toast-step';
    const icon = document.createElement('span');
    icon.className = 'toast-spin';
    icon.style.visibility = 'hidden';
    const text = document.createElement('span');
    text.textContent = label;
    row.appendChild(icon);
    row.appendChild(text);
    stepsBox.appendChild(row);
    steps[key] = { row, icon, text, label };
  }
  addStep('memo', 'Memo written');
  addStep('stop', 'Stopping daemon…');
  addStep('spawn', 'Respawning…');
  addStep('verify', 'Verifying new daemon…');
  el.appendChild(stepsBox);

  // Memo is confirmed the moment we got HTTP 200 (applyResult fills it in),
  // but we mark it active immediately so the toast never looks empty.
  steps.memo.row.classList.add('active');
  steps.memo.icon.style.visibility = 'visible';

  const foot = document.createElement('div');
  foot.className = 'toast-foot';
  foot.textContent = 'Click to dismiss';
  el.appendChild(foot);

  el.addEventListener('click', () => el.remove());
  document.body.appendChild(el);
  // Don't auto-dismiss while the restart is in flight — the response can
  // take up to ~30 s in the worst case (stop timeout + SIGTERM + SIGKILL
  // + verify poll). The dismiss timer is armed only once applyResult /
  // renderHttpError produces a terminal state.
  let dismissTimer = null;
  function armDismiss(ms) {
    if (dismissTimer) clearTimeout(dismissTimer);
    dismissTimer = setTimeout(() => { if (el.parentNode) el.remove(); }, ms);
  }

  function setStep(key, state) {
    const s = steps[key];
    if (!s) return;
    s.row.classList.remove('active', 'done', 'err');
    if (state === 'active') {
      s.row.classList.add('active');
      s.icon.style.visibility = 'visible';
    } else if (state === 'done') {
      s.row.classList.add('done');
      s.icon.style.visibility = 'hidden';
      s.text.textContent = '\u2713 ' + s.label.replace('…', '').replace(/^[\u2713\u2717]\s*/, '');
    } else if (state === 'err') {
      s.row.classList.add('err');
      s.icon.style.visibility = 'hidden';
      s.text.textContent = '\u2717 ' + s.label.replace('…', '').replace(/^[\u2713\u2717]\s*/, '');
    }
  }

  function renderHttpError(text) {
    // No server response or HTTP 4xx/5xx — memo probably did not land.
    // Fall back to Option 1 wording so the operator has a working recovery.
    foot.textContent = 'Click to dismiss';
    el.classList.add('toast-err');
    head.textContent = 'Request failed — ' + agent + ' not updated';
    // Clear step rows; replace with error body.
    while (stepsBox.firstChild) stepsBox.removeChild(stepsBox.firstChild);
    const line = document.createElement('div');
    line.textContent = 'Server error: ' + (text || 'unknown');
    stepsBox.appendChild(line);
    const retry = document.createElement('div');
    retry.style.marginTop = '6px';
    retry.textContent = 'Retry via CLI:';
    stepsBox.appendChild(retry);
    const pre = document.createElement('pre');
    pre.textContent =
      'agentis memo set ' + agent + ':confidence ' + requestedValue.toFixed(3) + '\n' +
      'agentis daemon stop --all && ./start-federation.sh';
    stepsBox.appendChild(pre);
    armDismiss(30000);
  }

  function applyResult(data) {
    // Server-authoritative value (it's what landed on disk).
    const serverValue = data && typeof data.value === 'string' ? parseFloat(data.value) : NaN;
    const v = Number.isFinite(serverValue) ? serverValue : requestedValue;
    const auditOk = !data || data.audit_logged !== false;

    const restart = (data && data.restart) || {};
    // Success path: auto-restart worked end-to-end.
    if (restart.succeeded) {
      el.classList.add('toast-ok');
      head.textContent = 'Loaded ' + v.toFixed(2) + ' \u2713 ' + agent;
      setStep('memo', 'done');
      setStep('stop', 'done');
      setStep('spawn', 'done');
      setStep('verify', 'done');
      const detail = document.createElement('div');
      detail.className = 'toast-foot';
      const oldPid = restart.old_pid || 0;
      const newPid = restart.new_pid || 0;
      const started = restart.new_started_at ? new Date(restart.new_started_at * 1000).toLocaleTimeString() : '?';
      detail.textContent =
        'old pid ' + (oldPid || 'n/a') + ' → new pid ' + newPid +
        ' (started ' + started + ')' +
        (auditOk ? '' : ' — audit log write failed');
      stepsBox.appendChild(detail);
      foot.textContent = 'Auto-dismiss in 12s — click to dismiss now';
      armDismiss(12000);
      return;
    }

    // Failure path: memo was written, but restart step failed. Give the
    // operator the exact command they can paste for a manual respawn,
    // plus the whole-federation fallback that the Option 1 toast used.
    el.classList.add('toast-err');
    head.textContent = 'Auto-restart failed — manual step required';
    setStep('memo', 'done');
    // Mark the last completed step per the events trail, if present.
    const events = Array.isArray(restart.events) ? restart.events : [];
    const stepMap = { stop: 'stop', sigterm: 'stop', sigkill: 'stop', wait_exit: 'stop',
                      cleanup: 'stop', spawn: 'spawn', verify: 'verify' };
    const seen = { stop: null, spawn: null, verify: null };
    events.forEach(e => {
      const bucket = stepMap[e.step];
      if (!bucket) return;
      if (e.status === 'error') seen[bucket] = 'err';
      else if (e.status === 'ok' && seen[bucket] !== 'err') seen[bucket] = 'done';
    });
    Object.keys(seen).forEach(k => { if (seen[k]) setStep(k, seen[k]); });

    const reason = document.createElement('div');
    reason.textContent = 'Memo written to ' + agent + ':confidence = ' + v.toFixed(3) +
                         ' on disk. Restart step failed: ' + (restart.error || 'unknown');
    stepsBox.appendChild(reason);

    if (restart.manual_command) {
      const label = document.createElement('div');
      label.style.marginTop = '6px';
      label.textContent = 'Respawn this agent:';
      stepsBox.appendChild(label);
      const pre = document.createElement('pre');
      pre.textContent = restart.manual_command;
      stepsBox.appendChild(pre);
    }

    const fallbackLabel = document.createElement('div');
    fallbackLabel.style.marginTop = '6px';
    fallbackLabel.textContent = 'Or restart the whole federation:';
    stepsBox.appendChild(fallbackLabel);
    const fb = document.createElement('pre');
    fb.textContent = 'agentis daemon stop --all && ./start-federation.sh';
    stepsBox.appendChild(fb);

    if (!auditOk) {
      const auditWarn = document.createElement('div');
      auditWarn.className = 'toast-foot';
      auditWarn.textContent = 'Audit log write failed.';
      stepsBox.appendChild(auditWarn);
    }
    foot.textContent = 'Click to dismiss';
    // Error toasts get a longer window — the operator needs time to copy
    // the manual command.
    armDismiss(30000);
  }

  return { el, setStep, renderHttpError, applyResult };
}

(function() {
  const el = document.getElementById('confidence');
  const colonies = {};
  confidences.forEach(c => { if (!colonies[c.colony]) colonies[c.colony] = []; colonies[c.colony].push(c); });
  let html = '<table>';
  Object.keys(colonies).forEach(colony => {
    html += '<tr><td colspan="4" class="colony-header">' + colony + '</td></tr>';
    colonies[colony].forEach(c => {
      const v = parseFloat(c.confidence) || 0;
      const pct = Math.round(v * 100);
      const phase = v >= 0.85 ? 'act' : v >= 0.6 ? 'suggest' : 'observe';
      const color = v >= 0.85 ? 'var(--green)' : v >= 0.6 ? 'var(--yellow)' : 'var(--muted)';
      const down = nextStep(v, -1);
      const up = nextStep(v, 1);
      const downAttr = down === null
        ? 'disabled title="Already at minimum step"'
        : 'onclick="setConfidence(\'' + c.agent + '\',' + down + ')" title="Bump down to ' + down.toFixed(2) + '"';
      const upAttr = up === null
        ? 'disabled title="Already at maximum step"'
        : 'onclick="setConfidence(\'' + c.agent + '\',' + up + ')" title="Bump up to ' + up.toFixed(2) + '"';
      const upClass = (up !== null && up >= 0.85) ? 'conf-btn conf-btn-act' : 'conf-btn';
      html += '<tr><td class="agent-name" style="width:160px">' + c.agent + '</td>';
      html += '<td style="width:80px"><span class="badge badge-' + phase + '">' + v.toFixed(2) + '</span></td>';
      html += '<td style="width:70px;white-space:nowrap">';
      html += '<button class="conf-btn" ' + downAttr + '>&#x25bc;</button>';
      html += '<button class="' + upClass + '" ' + upAttr + '>&#x25b2;</button>';
      html += '</td>';
      html += '<td><div class="conf-bar-bg"><div class="conf-bar-fill" style="width:' + pct + '%;background:' + color + ';box-shadow:0 0 6px ' + color + '"></div></div></td></tr>';
    });
  });
  html += '</table>';
  el.innerHTML = html;
})();

// --- Phase readiness ---
(function() {
  const el = document.getElementById('readiness');
  const avgConf = {};
  const confCount = {};
  confidences.forEach(c => {
    avgConf[c.colony] = (avgConf[c.colony] || 0) + c.confidence;
    confCount[c.colony] = (confCount[c.colony] || 0) + 1;
  });
  colonyList.forEach(col => { avgConf[col] = confCount[col] ? avgConf[col] / confCount[col] : 0; });

  function estimateEta(colony, cur) {
    if (cur >= 0.85) return { text: 'AUTONOMOUS', color: 'var(--green)' };
    const target = cur < 0.6 ? 0.6 : 0.85;
    const label = target === 0.6 ? 'SUGGEST' : 'AUTONOMOUS';
    if (history.length < 120) return { text: 'collecting data...', color: 'var(--muted)' };
    const dayAgo = nowEpoch - 86400;
    const pts = history.filter(h => h.t > dayAgo && h.confidence && h.confidence[colony] !== undefined).map(h => ({t:h.t,v:h.confidence[colony]}));
    if (pts.length < 60) return { text: 'collecting data...', color: 'var(--muted)' };
    const n = pts.length; let sX=0,sY=0,sXY=0,sX2=0;
    pts.forEach(p => { sX+=p.t; sY+=p.v; sXY+=p.t*p.v; sX2+=p.t*p.t; });
    const slope = (n*sXY - sX*sY) / (n*sX2 - sX*sX);
    if (slope <= 0.000001) return { text: 'stable', color: 'var(--muted)' };
    const days = Math.round((target - cur) / slope / 86400);
    if (days < 1) return { text: label + ' today', color: 'var(--green)' };
    if (days === 1) return { text: label + ' tomorrow', color: 'var(--yellow)' };
    if (days > 90) return { text: label + ' > 90d', color: 'var(--red)' };
    return { text: label + ' in ~' + days + 'd', color: 'var(--yellow)' };
  }

  let html = '';
  colonyList.forEach(col => {
    const v = avgConf[col] || 0;
    const pct = Math.min(Math.round(v * 100), 100);
    const color = colonyColors[col];
    const eta = estimateEta(col, v);
    html += '<div class="phase-row"><span class="phase-colony">' + col + '</span>';
    html += '<div class="phase-bar-outer">';
    html += '<div class="phase-marker" style="left:60%"><span class="phase-marker-label">0.6 suggest</span></div>';
    html += '<div class="phase-marker" style="left:85%"><span class="phase-marker-label">0.85 autonomous</span></div>';
    html += '<div class="phase-bar-inner" style="width:' + pct + '%;background:' + color + ';box-shadow:0 0 10px ' + color + '50;color:#000">' + v.toFixed(2) + '</div>';
    html += '</div><span class="phase-eta" style="color:' + eta.color + '">' + eta.text + '</span></div>';
  });
  el.innerHTML = html;
})();

// --- Experience trend ---
// #111: history key is `experience` as of this commit. Older history
// entries (pre-#111) carried `knowledge` with value 0 on real runs, so
// falling back to that key would just seed the chart with zeros — we
// drop them entirely and let the trend grow fresh.
(function() {
  const el = document.getElementById('experience-trend');
  if (history.length < 2) { el.innerHTML = '<span class="empty">Trend available after 2+ data points</span>'; return; }
  const W = 480, H = 140, PAD = 35;
  const tMin = history[0].t, tMax = history[history.length - 1].t;
  const tRange = Math.max(tMax - tMin, 1);
  let kMax = 1;
  history.forEach(h => { if (h.experience) colonyList.forEach(c => { if ((h.experience[c]||0) > kMax) kMax = h.experience[c]; }); });
  let svg = '<svg width="100%" viewBox="0 0 '+W+' '+(H+20)+'">';
  for (let i = 0; i <= 4; i++) { const y = 10+(H-10)*i/4; svg += '<line x1="'+PAD+'" y1="'+y+'" x2="'+W+'" y2="'+y+'" stroke="rgba(0,255,255,0.06)" />'; }
  svg += '<line x1="'+PAD+'" y1="'+H+'" x2="'+W+'" y2="'+H+'" stroke="var(--border)" />';
  svg += '<text x="'+PAD+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9">'+new Date(tMin*1000).toLocaleDateString()+'</text>';
  svg += '<text x="'+W+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9" text-anchor="end">'+new Date(tMax*1000).toLocaleDateString()+'</text>';
  colonyList.forEach(col => {
    const pts = history.filter(h => h.experience && h.experience[col] !== undefined).map(h => {
      const x = PAD+((h.t-tMin)/tRange)*(W-PAD); const y = H-((h.experience[col]||0)/kMax)*(H-10);
      return x.toFixed(1)+','+y.toFixed(1);
    });
    if (pts.length > 1) {
      svg += '<polyline points="'+pts.join(' ')+'" fill="none" stroke="'+colonyColors[col]+'" stroke-width="1.5" opacity="0.8" />';
      svg += '<polyline points="'+pts.join(' ')+'" fill="none" stroke="'+colonyColors[col]+'" stroke-width="4" opacity="0.15" />';
    }
  });
  svg += '</svg>';
  let legend = '<div class="chart-legend">';
  colonyList.forEach(col => { legend += '<span><span class="legend-dot" style="background:'+colonyColors[col]+';box-shadow:0 0 4px '+colonyColors[col]+'"></span>'+col+' ('+(experienceCounts[col]||0)+')</span>'; });
  legend += '</div>';
  el.innerHTML = svg + legend;
})();

// --- Remediation ---
(function() {
  const el = document.getElementById('remediation');
  if (!Array.isArray(remediation) || !remediation.length) { el.innerHTML = '<span class="empty">No remediation actions recorded</span>'; return; }
  let html = '<table><tr><th>Time</th><th>Action</th><th>Agent</th></tr>';
  remediation.forEach(r => {
    html += '<tr><td>'+(r.timestamp||r.time||'')+'</td><td><span class="badge badge-quarantine">'+(r.action||r.type||'')+'</span></td><td class="agent-name">'+(r.agent||r.agent_id||'')+'</td></tr>';
  });
  html += '</table>';
  el.innerHTML = html;
})();

// --- Suggestions ---
(function() {
  const el = document.getElementById('suggestions');
  if (!suggestions.length) { el.innerHTML = '<span class="empty">No suggestions yet. Agents in observe mode or no GitLab activity.</span>'; return; }
  el.innerHTML = suggestions.map(s => '<div>'+s.replace(/</g,'&lt;').replace(/\[(.*?)\]/g,'<span style="color:var(--cyan)">[$1]</span>')+'</div>').join('');
  el.scrollTop = el.scrollHeight;
})();

// --- Kill switch ---
let killArmed = false;
function killSwitch() {
  const btn = document.getElementById('kill-btn');
  if (!killArmed) {
    killArmed = true;
    btn.textContent = 'Confirm Kill';
    btn.className = 'kill-btn confirm';
    setTimeout(() => { if (killArmed) { killArmed = false; btn.textContent = 'Kill Federation'; btn.className = 'kill-btn'; } }, 5000);
    return;
  }
  btn.textContent = 'Killing...';
  btn.className = 'kill-btn killed';
  fetch('/kill', { method: 'POST' })
    .then(r => r.text().then(t => ({ok: r.ok, text: t})))
    .then(({ok, text}) => {
      if (!ok) {
        // Server returned non-2xx: surface the message and allow retry.
        btn.textContent = 'Kill Failed: ' + text.split('\n')[0].slice(0,60);
        btn.className = 'kill-btn';
        killArmed = false;
        return;
      }
      // First line of reply is the count, e.g. "5 daemon(s) stopped".
      // "0 daemon(s) stopped" means we clicked but there was nothing to kill
      // — leave the meta-refresh in place and let the operator retry.
      const first = text.split('\n')[0] || 'Federation Stopped';
      btn.textContent = first;
      if (!/^0 /.test(first)) {
        const m = document.querySelector('meta[http-equiv="refresh"]');
        if (m) m.remove();
      } else {
        btn.className = 'kill-btn';
        killArmed = false;
      }
    })
    .catch(() => { btn.textContent = 'Kill Failed'; btn.className = 'kill-btn'; killArmed = false; });
}
</script>
</body>
</html>
JSEOF
    } >> "$HTML_TMP"
    # Atomic publish: mv(2) on the same filesystem replaces the inode in a
    # single syscall, so any HTTP reader sees either the old or the new file
    # in full — never a truncated-in-progress state.
    mv "$HTML_TMP" "$HTML_FILE"
}

# --- Regen-only mode ---
# When invoked by POST /refresh from the running dashboard server (see the
# PYSERVER block below), re-execute generate and exit. The active server
# process keeps serving; only the static HTML snapshot is refreshed.
# Without this, manual refresh just reloads the stale on-disk HTML — see #98.
if [ "${DASHBOARD_REGEN_ONLY:-0}" = "1" ]; then
    generate
    exit 0
fi

# --- Main ---

echo "Starting web server on http://localhost:$PORT"
echo "Press Ctrl+C to stop"
echo ""

generate

# Background: regenerate every 60 seconds
(
    while true; do
        sleep 60
        generate 2>/dev/null
    done
) &
REGEN_PID=$!
trap 'kill $REGEN_PID 2>/dev/null; exit 0' INT TERM

# Serve with kill switch + refresh + confidence endpoints. SCRIPT_PATH and
# FED_DIR are passed through so POST /refresh can re-exec this script in
# regen-only mode. ALL_AGENTS_CSV is the allowlist for POST /confidence —
# operator-supplied agent names must match exactly or the endpoint rejects
# with 400 (never pass user strings to subprocess unchecked, #105).
ALL_AGENTS_CSV="$(IFS=,; echo "${ALL_AGENTS[*]}")"
python3 - "$DASH_DIR" "$PORT" "$SCRIPT_PATH" "$FED_DIR" "$ALL_AGENTS_CSV" "$AGENT_COLONY_MAP" <<'PYSERVER'
import sys, os, subprocess, json, time, signal, shutil, shlex, urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler

serve_dir, port = sys.argv[1], int(sys.argv[2])
script_path, fed_dir_arg = sys.argv[3], sys.argv[4]
allowed_agents = set(a for a in sys.argv[5].split(',') if a)
try:
    _map = json.loads(sys.argv[6])
except (json.JSONDecodeError, ValueError, IndexError):
    _map = []
agent_to_colony = {e.get('agent',''): e.get('colony','') for e in _map if e.get('agent')}
# serve_dir is $FED_DIR/.dashboard; the federation root (parent of serve_dir)
# is the cwd we want agentis to resolve .agentis/ from. We still os.chdir to
# serve_dir so SimpleHTTPRequestHandler serves index.html from here.
os.chdir(serve_dir)
fed_dir = os.path.dirname(serve_dir)
confidence_log = os.path.join(serve_dir, 'confidence-log.jsonl')


def parse_toml_section(toml_path, section):
    """Extract key=value pairs under [section] from a colony TOML file.

    Mirrors tools/parse-toml.sh semantics: strips matching surrounding
    quotes and ignores inline `#` comments (respecting quoted strings).
    Returns an empty dict if the file is missing or the section absent.
    """
    out = {}
    try:
        with open(toml_path, 'r', encoding='utf-8') as f:
            in_section = False
            for raw in f:
                line = raw.rstrip('\n')
                # Strip inline comment outside of quotes.
                stripped_chars = []
                quote = None
                i = 0
                while i < len(line):
                    ch = line[i]
                    if quote:
                        stripped_chars.append(ch)
                        if ch == '\\' and i + 1 < len(line):
                            stripped_chars.append(line[i + 1])
                            i += 2
                            continue
                        if ch == quote:
                            quote = None
                    else:
                        if ch == '#':
                            break
                        if ch in ('"', "'"):
                            quote = ch
                        stripped_chars.append(ch)
                    i += 1
                s = ''.join(stripped_chars).strip()
                if not s:
                    continue
                if s.startswith('[') and s.endswith(']'):
                    in_section = (s[1:-1].strip() == section)
                    continue
                if not in_section or '=' not in s:
                    continue
                k, _, v = s.partition('=')
                k = k.strip()
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
                    v = v[1:-1]
                out[k] = v
    except OSError:
        pass
    return out


def list_daemons():
    try:
        result = subprocess.run(
            ['agentis', 'daemon', 'list', '--json'],
            capture_output=True, text=True, cwd=fed_dir, timeout=5,
        )
        if result.returncode != 0:
            return []
        return json.loads(result.stdout or '[]')
    except (OSError, subprocess.SubprocessError, json.JSONDecodeError, ValueError):
        return []


def find_agent_daemon(agent):
    """Return the running daemon record whose `source` basename matches
    <agent>.ag, or None. Prefers `state == running`; falls back to any
    record so the stop/cleanup path can tidy zombies."""
    ag_file = f'{agent}.ag'
    running = None
    any_match = None
    for d in list_daemons():
        src = d.get('source') or ''
        if not src:
            continue
        if os.path.basename(src) != ag_file:
            continue
        any_match = any_match or d
        if d.get('state') == 'running' and running is None:
            running = d
    return running or any_match


def pid_alive(pid):
    if not pid or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def wait_for_exit(pid, timeout_s):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not pid_alive(pid):
            return True
        time.sleep(0.2)
    return not pid_alive(pid)


def cleanup_sidecars(agent_id):
    """Remove stale per-daemon files under $FED_DIR/.agentis/daemon/.

    `agentis daemon stop` normally tidies these, but #523 makes that
    unreliable; leaving a stale `.heartbeat` behind causes the next
    spawn's watchdog to read the old mtime and kill its fresh child on
    the first tick (same root cause as the wipe in start-federation.sh
    after laptop sleep). Safe to call unconditionally.
    """
    sidecar_dir = os.path.join(fed_dir, '.agentis', 'daemon')
    removed = []
    for ext in ('pid', 'watchdog.pid', 'colony', 'heartbeat', 'status', 'stop'):
        p = os.path.join(sidecar_dir, f'{agent_id}.{ext}')
        try:
            os.remove(p)
            removed.append(os.path.basename(p))
        except FileNotFoundError:
            pass
        except OSError:
            pass
    inbox = os.path.join(sidecar_dir, f'{agent_id}.inbox')
    try:
        shutil.rmtree(inbox)
        removed.append(os.path.basename(inbox))
    except FileNotFoundError:
        pass
    except OSError:
        pass
    return removed


def build_manual_command(colony, colony_dir, agent_file):
    """Single-line respawn command the operator can paste if auto-restart
    fails. Mirrors the flags in each colony's start-colony.sh.

    Env vars are referenced as $VARIABLE (not expanded) — the operator's
    shell already has them exported via start-colony.sh. Embedding the
    real GITLAB_TOKEN would leak credentials into the DOM, browser cache,
    and DevTools (QA review #1).
    """
    env_refs = (
        'GITLAB_URL="$GITLAB_URL" GITLAB_TOKEN="$GITLAB_TOKEN" '
        'GITLAB_PROJECT="$GITLAB_PROJECT" GITLAB_ME="$GITLAB_ME" '
        f'COLONY_DIR={shlex.quote(colony_dir)}'
    )
    return (
        f'cd {shlex.quote(colony_dir)} && '
        f'{env_refs} '
        f'agentis daemon {shlex.quote(agent_file)}'
        f' --colony {shlex.quote(colony)}'
        f' --enable-exec --enable-messaging --tick-interval 60000 &'
    )


def restart_daemon(agent):
    """Stop+cleanup+respawn sequence for one agent. Returns a dict with
    step-level outcomes + final success/failure + a manual fallback
    command for operator copy-paste on failure (#137)."""
    events = []

    def rec(step, status, **kw):
        entry = {'step': step, 'status': status}
        entry.update(kw)
        events.append(entry)

    colony = agent_to_colony.get(agent, '')
    if not colony:
        rec('lookup', 'error', message=f'no colony mapping for {agent}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'no colony mapping for {agent}',
            'events': events,
        }

    colony_dir = os.path.join(fed_dir, colony)
    agent_file = os.path.join(colony_dir, 'agents', f'{agent}.ag')
    if not os.path.isfile(agent_file):
        rec('lookup', 'error', message=f'missing {agent_file}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'missing {agent_file}',
            'events': events,
        }

    # Read gitlab config up front so a malformed colony.toml fails fast
    # before we stop the running daemon.
    config_path = os.path.join(colony_dir, 'config', 'colony.toml')
    gitlab = parse_toml_section(config_path, 'gitlab')
    gl_url = gitlab.get('url', '')
    gl_token = gitlab.get('token', '')
    gl_project_raw = gitlab.get('project', '')
    gl_me = gitlab.get('me', '')
    gl_project = gl_project_raw.replace('/', '%2F')
    env_overrides = {
        'GITLAB_URL': gl_url,
        'GITLAB_TOKEN': gl_token,
        'GITLAB_PROJECT': gl_project,
        'GITLAB_ME': gl_me,
        'COLONY_DIR': colony_dir,
    }
    manual_cmd = build_manual_command(colony, colony_dir, agent_file)

    # Resolve current daemon (may already be stopped — we still spawn).
    old = find_agent_daemon(agent)
    old_agent_id = (old or {}).get('agent_id') or ''
    old_pid = (old or {}).get('pid') or 0
    old_started_at = (old or {}).get('started_at') or 0
    rec('resolve', 'ok', agent_id=old_agent_id, pid=old_pid,
        running=(old is not None and old.get('state') == 'running'))

    # Stop the running daemon (if any). #523: `daemon stop <id>` can be a
    # no-op; fall through to SIGTERM/SIGKILL if the pid doesn't exit.
    if old and old.get('state') == 'running' and old_agent_id:
        rec('stop', 'start')
        try:
            result = subprocess.run(
                ['agentis', 'daemon', 'stop', old_agent_id],
                capture_output=True, text=True, cwd=fed_dir, timeout=10,
            )
            rec('stop', 'ok' if result.returncode == 0 else 'warn',
                stdout=(result.stdout or '').strip(),
                stderr=(result.stderr or '').strip(),
                returncode=result.returncode)
        except (OSError, subprocess.SubprocessError) as e:
            rec('stop', 'warn', message=str(e))

        if old_pid:
            rec('wait_exit', 'start', pid=old_pid, timeout_s=5)
            if wait_for_exit(old_pid, 5.0):
                rec('wait_exit', 'ok')
            else:
                rec('sigterm', 'start',
                    message='daemon stop did not land within 5s, sending SIGTERM')
                try:
                    os.kill(old_pid, signal.SIGTERM)
                except OSError as e:
                    rec('sigterm', 'warn', message=str(e))
                if wait_for_exit(old_pid, 5.0):
                    rec('sigterm', 'ok')
                else:
                    rec('sigkill', 'start',
                        message='SIGTERM did not land within 5s, sending SIGKILL')
                    try:
                        os.kill(old_pid, signal.SIGKILL)
                    except OSError as e:
                        rec('sigkill', 'warn', message=str(e))
                    if not wait_for_exit(old_pid, 2.0):
                        rec('verify_dead', 'error',
                            message=f'pid {old_pid} survived SIGKILL')
                        return {
                            'attempted': True, 'succeeded': False,
                            'error': f'pid {old_pid} survived SIGKILL',
                            'manual_command': manual_cmd,
                            'events': events,
                        }
                    rec('sigkill', 'ok')

    # Cleanup sidecars (safe even if stop already tidied them).
    if old_agent_id:
        removed = cleanup_sidecars(old_agent_id)
        rec('cleanup', 'ok', removed=removed)

    # Respawn detached so the dashboard process can die without taking
    # the fresh daemon with it.
    rec('spawn', 'start')
    env = dict(os.environ)
    env.update(env_overrides)
    spawn_ts = int(time.time())
    try:
        proc = subprocess.Popen(
            [
                'agentis', 'daemon', agent_file,
                '--colony', colony,
                '--enable-exec',
                '--enable-messaging',
                '--tick-interval', '60000',
            ],
            cwd=colony_dir,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except (OSError, subprocess.SubprocessError) as e:
        rec('spawn', 'error', message=str(e))
        return {
            'attempted': True, 'succeeded': False,
            'error': f'spawn failed: {e}',
            'manual_command': manual_cmd,
            'events': events,
        }
    rec('spawn', 'ok', launcher_pid=proc.pid, spawn_ts=spawn_ts)

    # Verify: new daemon appears in `daemon list --json` with a different
    # pid than `old_pid` (if there was one) AND `started_at` >= spawn_ts.
    # Poll for up to 15s — first tick takes a moment to register.
    rec('verify', 'start', timeout_s=15)
    deadline = time.monotonic() + 15.0
    new_daemon = None
    while time.monotonic() < deadline:
        for d in list_daemons():
            src = d.get('source') or ''
            if not src or os.path.basename(src) != f'{agent}.ag':
                continue
            if d.get('state') != 'running':
                continue
            new_pid = d.get('pid') or 0
            if old_pid and new_pid == old_pid:
                continue
            if (d.get('started_at') or 0) < spawn_ts - 1:
                continue
            new_daemon = d
            break
        if new_daemon:
            break
        time.sleep(0.5)

    if not new_daemon:
        code = proc.poll()
        rec('verify', 'error',
            message=f'new daemon not registered within 15s (launcher exit={code})')
        return {
            'attempted': True, 'succeeded': False,
            'error': 'new daemon not registered within 15s',
            'manual_command': manual_cmd,
            'events': events,
        }

    # Reap the launcher wrapper so it does not linger as a zombie in the
    # dashboard's process table. The actual daemon child is already
    # detached (start_new_session=True) and outlives the launcher.
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass

    rec('verify', 'ok',
        new_pid=new_daemon.get('pid'),
        new_agent_id=new_daemon.get('agent_id'),
        new_started_at=new_daemon.get('started_at'),
        new_confidence=new_daemon.get('confidence'))

    return {
        'attempted': True, 'succeeded': True,
        'old_pid': old_pid,
        'old_started_at': old_started_at,
        'new_pid': new_daemon.get('pid'),
        'new_agent_id': new_daemon.get('agent_id'),
        'new_started_at': new_daemon.get('started_at'),
        'new_confidence': new_daemon.get('confidence'),
        'manual_command': manual_cmd,
        'events': events,
    }

class Handler(SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/refresh':
            # #98: regenerate the static HTML snapshot on operator request.
            # The background loop only regenerates every 60 s; without this
            # endpoint the ↻ button and `r` key just reload the stale file.
            env = dict(os.environ)
            env['DASHBOARD_REGEN_ONLY'] = '1'
            try:
                result = subprocess.run(
                    ['bash', script_path, fed_dir_arg],
                    capture_output=True, text=True,
                    env=env,
                    timeout=30,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'regen failed: {e}'.encode())
                return
            if result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                msg = (result.stderr or result.stdout or 'regen failed').strip()
                self.wfile.write(msg.encode() or b'regen failed')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'ok')
            return
        if self.path == '/confidence':
            # #105: operator-driven bump up/down from the dashboard. Body is
            # form-encoded (agent=<name>&value=<float>). We enforce three
            # layers of validation before touching subprocess:
            #   1. agent name must be in the discovered ALL_AGENTS allowlist
            #      (prevents operator-supplied strings from reaching the CLI)
            #   2. value must parse as float and land in [0.0, 1.0]
            #   3. any CLI failure is reported with 500, not silently swallowed
            length = int(self.headers.get('Content-Length', '0') or '0')
            if length <= 0 or length > 4096:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'empty or oversized body')
                return
            try:
                raw = self.rfile.read(length).decode('utf-8', errors='replace')
                params = urllib.parse.parse_qs(raw, keep_blank_values=False)
            except (ValueError, UnicodeDecodeError):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'malformed form body')
                return
            agent = (params.get('agent') or [''])[0]
            value_raw = (params.get('value') or [''])[0]
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            try:
                value = float(value_raw)
            except ValueError:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'value not a float: {value_raw!r}'.encode())
                return
            if not (0.0 <= value <= 1.0):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'value out of [0,1]: {value}'.encode())
                return
            # `agentis memo set <agent>:confidence <value>` — cwd=fed_dir so
            # agentis walks up from the federation root to find .agentis/.
            try:
                result = subprocess.run(
                    ['agentis', 'memo', 'set', f'{agent}:confidence', f'{value:.3f}'],
                    capture_output=True, text=True,
                    cwd=fed_dir,
                    timeout=10,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            if result.returncode != 0:
                msg = (result.stderr or result.stdout or 'memo set failed').strip()
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(msg.encode() or b'memo set failed')
                return
            # Audit log: append a JSONL row per change. .dashboard/ is
            # already operator-visible (index.html, history.json live here)
            # so this keeps all per-federation dashboard state colocated.
            audit_ok = False
            try:
                with open(confidence_log, 'a') as f:
                    f.write(json.dumps({
                        't': int(time.time()),
                        'agent': agent,
                        'value': value,
                        'remote': self.client_address[0],
                    }) + '\n')
                audit_ok = True
            except OSError:
                # Audit write failure must not mask the successful memo set.
                pass
            # #137 Option 2: auto-restart the agent's daemon so the memo
            # takes effect immediately — without this the running daemon
            # keeps using its in-flight value until the next tick and
            # spawn-time decisions never reload at all. On failure the
            # response still reports memo_written=true and the client
            # falls back to the Option 1 restart-required toast.
            restart = restart_daemon(agent)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'value': f'{value:.3f}',
                'memo_written': True,
                'audit_logged': audit_ok,
                # restart_required flips to false only when the whole
                # restart sequence succeeded end-to-end. UI uses this to
                # decide between the "Loaded ✓" success state and the
                # fallback "manual restart required" toast.
                'restart_required': not restart.get('succeeded', False),
                'restart': restart,
            }).encode())
            return
        if self.path == '/kill':
            # Run from fed_dir, not .dashboard. The actual fix for #91 is
            # the v1.1.7 walk-up in agentis_root() (Replikanti/agentis-core#499)
            # which finds .agentis/ in any ancestor; passing cwd=fed_dir
            # just makes the intent explicit and stops .dashboard/ from
            # appearing as a plausible agentis root in future agentis
            # versions that might use some other marker than .agentis/objects.
            try:
                result = subprocess.run(
                    ['agentis', 'daemon', 'stop', '--all'],
                    capture_output=True, text=True,
                    cwd=fed_dir,
                    timeout=15,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            # `agentis daemon stop --all` emits to stderr:
            #   "No running daemons to stop." or one "stop signal sent: <id>"
            #   line per daemon. Count them so the button reports real state.
            err = (result.stderr or '').strip()
            lines = [l for l in err.splitlines() if l]
            stopped = [l for l in lines if l.startswith('stop signal sent:')]
            if result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write((err or 'agentis daemon stop failed').encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            summary = f'{len(stopped)} daemon(s) stopped'
            body = summary + ('\n' + err if err else '')
            self.wfile.write(body.encode())
        else:
            self.send_error(404)
    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
PYSERVER
