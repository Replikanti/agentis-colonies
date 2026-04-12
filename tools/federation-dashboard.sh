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

    local DAEMONS
    DAEMONS="$(agentis daemon list --json 2>/dev/null || echo '[]')"

    # Parse knowledge count per colony
    local COLONY_LIST_PY=""
    for col in "${COLONIES[@]}"; do
        COLONY_LIST_PY="${COLONY_LIST_PY}\"${col}\","
    done
    COLONY_LIST_PY="[${COLONY_LIST_PY%,}]"

    local KNOWLEDGE_COUNTS
    KNOWLEDGE_COUNTS="$(agentis knowledge list 2>/dev/null | python3 -c "
import sys, json
colonies = ${COLONY_LIST_PY}
counts = {c: 0 for c in colonies}
counts['total'] = 0
for line in sys.stdin:
    counts['total'] += 1
    for colony in colonies:
        if colony in line.lower():
            counts[colony] += 1
            break
print(json.dumps(counts))
" 2>/dev/null || echo '{"total":0}')"

    local REMEDIATION
    REMEDIATION="$(agentis remediation history --limit 5 --json 2>/dev/null || echo '[]')"

    # Confidence values
    local CONFIDENCES=""
    for i in "${!ALL_AGENTS[@]}"; do
        local agent="${ALL_AGENTS[$i]}"
        local conf
        conf="$(agentis memo get "${agent}:confidence" 2>/dev/null || echo '0.0')"
        CONFIDENCES="${CONFIDENCES}${conf},"
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
    python3 - "$HISTORY_FILE" "$EPOCH" "$KNOWLEDGE_COUNTS" "$CONFIDENCES" "$AGENT_COLONY_MAP" <<'PY'
import sys, json
path, epoch = sys.argv[1], int(sys.argv[2])
kc = json.loads(sys.argv[3])
conf_vals = json.loads(sys.argv[4])
agent_map = json.loads(sys.argv[5])
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
entry = {"t": epoch, "knowledge": kc, "confidence": avg_conf}
history.append(entry)
cutoff = epoch - 7 * 86400
history = [h for h in history if h["t"] > cutoff]
with open(path, "w") as f:
    json.dump(history, f)
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
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
</style>
</head>
<body>
HTMLEOF
    } > "$HTML_FILE"

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
      <div>auto-refresh 60s</div>
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
<h2>Knowledge Growth</h2>
<div id="knowledge-trend" class="chart-container"></div>
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
const knowledgeCounts = ${KNOWLEDGE_COUNTS};
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

// --- Stats row ---
(function() {
  const el = document.getElementById('stats-row');
  const running = daemons.filter(d => (d.state || d.STATE || '') === 'running').length;
  const totalKnowledge = knowledgeCounts.total || 0;
  let avgConf = 0;
  confidences.forEach(c => avgConf += c.confidence);
  avgConf = confidences.length ? (avgConf / confidences.length) : 0;
  const phase = avgConf >= 0.85 ? 'AUTONOMOUS' : avgConf >= 0.6 ? 'SUGGEST' : 'OBSERVE';
  const quarantined = daemons.filter(d => (d.quarantine || d.QUARANTINE || '') === 'yes').length;
  el.innerHTML =
    '<div class="stat-box"><div class="stat-value">' + running + '/' + totalAgents + '</div><div class="stat-label">Agents Running</div></div>' +
    '<div class="stat-box"><div class="stat-value" style="color:' + (avgConf >= 0.85 ? 'var(--green)' : avgConf >= 0.6 ? 'var(--yellow)' : 'var(--cyan)') + '">' + avgConf.toFixed(2) + '</div><div class="stat-label">Avg Confidence // ' + phase + '</div></div>' +
    '<div class="stat-box"><div class="stat-value">' + totalKnowledge + '</div><div class="stat-label">Knowledge Entries</div></div>' +
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
(function() {
  const el = document.getElementById('confidence');
  const colonies = {};
  confidences.forEach(c => { if (!colonies[c.colony]) colonies[c.colony] = []; colonies[c.colony].push(c); });
  let html = '<table>';
  Object.keys(colonies).forEach(colony => {
    html += '<tr><td colspan="3" class="colony-header">' + colony + '</td></tr>';
    colonies[colony].forEach(c => {
      const v = parseFloat(c.confidence) || 0;
      const pct = Math.round(v * 100);
      const phase = v >= 0.85 ? 'act' : v >= 0.6 ? 'suggest' : 'observe';
      const color = v >= 0.85 ? 'var(--green)' : v >= 0.6 ? 'var(--yellow)' : 'var(--muted)';
      html += '<tr><td class="agent-name" style="width:160px">' + c.agent + '</td>';
      html += '<td style="width:80px"><span class="badge badge-' + phase + '">' + v.toFixed(2) + '</span></td>';
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

// --- Knowledge trend ---
(function() {
  const el = document.getElementById('knowledge-trend');
  if (history.length < 2) { el.innerHTML = '<span class="empty">Trend available after 2+ data points</span>'; return; }
  const W = 480, H = 140, PAD = 35;
  const tMin = history[0].t, tMax = history[history.length - 1].t;
  const tRange = Math.max(tMax - tMin, 1);
  let kMax = 1;
  history.forEach(h => { if (h.knowledge) colonyList.forEach(c => { if ((h.knowledge[c]||0) > kMax) kMax = h.knowledge[c]; }); });
  let svg = '<svg width="100%" viewBox="0 0 '+W+' '+(H+20)+'">';
  for (let i = 0; i <= 4; i++) { const y = 10+(H-10)*i/4; svg += '<line x1="'+PAD+'" y1="'+y+'" x2="'+W+'" y2="'+y+'" stroke="rgba(0,255,255,0.06)" />'; }
  svg += '<line x1="'+PAD+'" y1="'+H+'" x2="'+W+'" y2="'+H+'" stroke="var(--border)" />';
  svg += '<text x="'+PAD+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9">'+new Date(tMin*1000).toLocaleDateString()+'</text>';
  svg += '<text x="'+W+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9" text-anchor="end">'+new Date(tMax*1000).toLocaleDateString()+'</text>';
  colonyList.forEach(col => {
    const pts = history.filter(h => h.knowledge && h.knowledge[col] !== undefined).map(h => {
      const x = PAD+((h.t-tMin)/tRange)*(W-PAD); const y = H-((h.knowledge[col]||0)/kMax)*(H-10);
      return x.toFixed(1)+','+y.toFixed(1);
    });
    if (pts.length > 1) {
      svg += '<polyline points="'+pts.join(' ')+'" fill="none" stroke="'+colonyColors[col]+'" stroke-width="1.5" opacity="0.8" />';
      svg += '<polyline points="'+pts.join(' ')+'" fill="none" stroke="'+colonyColors[col]+'" stroke-width="4" opacity="0.15" />';
    }
  });
  svg += '</svg>';
  let legend = '<div class="chart-legend">';
  colonyList.forEach(col => { legend += '<span><span class="legend-dot" style="background:'+colonyColors[col]+';box-shadow:0 0 4px '+colonyColors[col]+'"></span>'+col+' ('+(knowledgeCounts[col]||0)+')</span>'; });
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
    .then(r => r.text())
    .then(() => { btn.textContent = 'Federation Stopped'; const m = document.querySelector('meta[http-equiv="refresh"]'); if (m) m.remove(); })
    .catch(() => { btn.textContent = 'Kill Failed'; btn.className = 'kill-btn'; killArmed = false; });
}
</script>
</body>
</html>
JSEOF
    } >> "$HTML_FILE"
}

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

# Serve with kill switch endpoint
python3 - "$DASH_DIR" "$PORT" <<'PYSERVER'
import sys, os, subprocess
from http.server import HTTPServer, SimpleHTTPRequestHandler

serve_dir, port = sys.argv[1], int(sys.argv[2])
os.chdir(serve_dir)

class Handler(SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/kill':
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            result = subprocess.run(
                ['agentis', 'daemon', 'stop', '--all'],
                capture_output=True, text=True
            )
            msg = result.stdout.strip() or result.stderr.strip() or 'Federation stopped'
            self.wfile.write(msg.encode())
        else:
            self.send_error(404)
    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
PYSERVER
