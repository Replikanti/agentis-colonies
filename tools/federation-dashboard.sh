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
    local HTML_TMP="$HTML_FILE.tmp.$$"

    local DAEMONS
    DAEMONS="$(agentis daemon list --json 2>/dev/null || echo '[]')"

    local COLONY_LIST_PY=""
    for col in "${COLONIES[@]}"; do
        COLONY_LIST_PY="${COLONY_LIST_PY}\"${col}\","
    done
    COLONY_LIST_PY="[${COLONY_LIST_PY%,}]"

    local EXPERIENCE_DIR="${FED_DIR}/../.agentis/experience"
    if [ ! -d "$EXPERIENCE_DIR" ]; then
        EXPERIENCE_DIR=".agentis/experience"
    fi
    local LOG_DIR="${FED_DIR}/../.agentis/logs"
    if [ ! -d "$LOG_DIR" ]; then
        LOG_DIR=".agentis/logs"
    fi

    # --- Comprehensive per-agent data collection ---
    # Single python3 invocation collects all enriched data: experience stats,
    # .ag descriptions, log lines, PID liveness, event timeline, and
    # confidence change history. Outputs a single JSON blob consumed by JS.
    local COLLECTOR_JSON
    COLLECTOR_JSON="$(python3 - "$DAEMONS" "$AGENT_COLONY_MAP" "$FED_DIR" "$EPOCH" "$EXPERIENCE_DIR" "$LOG_DIR" "$DASH_DIR" "$COLONY_LIST_PY" <<'PY' "${ALL_AGENTS[@]}"
import sys, os, json, time, re, datetime

daemons_json   = sys.argv[1]
agent_map_json = sys.argv[2]
fed_dir        = sys.argv[3]
epoch          = int(sys.argv[4])
exp_dir        = sys.argv[5]
log_dir        = sys.argv[6]
dash_dir       = sys.argv[7]
colony_list_json = sys.argv[8]
all_agents     = sys.argv[9:]

def safe_json(s, default):
    try: return json.loads(s or '[]')
    except (json.JSONDecodeError, TypeError, ValueError): return default

daemons    = safe_json(daemons_json, [])
agent_map  = safe_json(agent_map_json, [])
colonies   = safe_json(colony_list_json, [])

name_to_colony = {e.get('agent',''): e.get('colony','') for e in agent_map}

# Build role → daemon mapping from daemon list source field
role_to_daemon = {}
id_to_role = {}
for d in daemons:
    src = d.get('source') or ''
    if not src:
        continue
    role = os.path.basename(src)
    if role.endswith('.ag'):
        role = role[:-3]
    role_to_daemon[role] = d
    aid = d.get('agent_id') or ''
    if aid:
        id_to_role[aid] = role

result = []
total_exp = 0
colony_exp = {c: 0 for c in colonies}

for agent in all_agents:
    colony = name_to_colony.get(agent, '')
    daemon = role_to_daemon.get(agent)

    rec = {
        'name': agent, 'colony': colony,
        'confidence': None, 'confidence_generation': None,
        'confidence_written_at': None,
        'health': 'unknown', 'state': 'stopped',
        'pid': 0, 'pid_alive': False,
        'agent_id': '', 'started_at': 0, 'quarantine': '',
        'tick_ok': 0, 'tick_err': 0,
        'experience_count': 0, 'experience_rate': 0.0,
        'experience_outcomes': {'success': 0, 'failure': 0, 'no-op': 0},
        'experience_variance': None, 'experience_slope_recent': None,
        'fitness_window': 0,
        'last_action': '', 'last_action_ts': 0,
        'description': '',
        'recent_experience': [], 'recent_logs': [],
        'source': '',
        'confidence_gates': [], 'confidence_cap': None,
    }

    if daemon:
        rec['confidence'] = daemon.get('confidence')
        rec['confidence_generation'] = daemon.get('confidence_generation')
        rec['confidence_written_at'] = daemon.get('confidence_written_at')
        rec['health'] = daemon.get('health') or 'unknown'
        rec['state'] = daemon.get('state') or 'unknown'
        rec['pid'] = daemon.get('pid') or 0
        rec['agent_id'] = daemon.get('agent_id') or ''
        rec['started_at'] = daemon.get('started_at') or 0
        rec['quarantine'] = daemon.get('quarantine') or ''
        rec['source'] = daemon.get('source') or ''
        rec['tick_ok'] = daemon.get('tick_ok') or daemon.get('ticks_ok') or 0
        rec['tick_err'] = daemon.get('tick_err') or daemon.get('ticks_err') or 0
        pid = rec['pid']
        if pid and pid > 0:
            try:
                os.kill(pid, 0)
                rec['pid_alive'] = True
            except OSError:
                rec['pid_alive'] = False

    # .ag description (first comment block) + confidence gate scan (#160)
    ag_path = os.path.join(fed_dir, colony, 'agents', agent + '.ag') if colony else ''
    if ag_path and os.path.isfile(ag_path):
        desc_lines = []
        ag_lines = []
        try:
            with open(ag_path) as f:
                ag_lines = f.readlines()
        except OSError:
            pass
        # Description from leading comment block
        for line in ag_lines:
            stripped = line.rstrip('\n')
            if stripped.startswith('//'):
                desc_lines.append(stripped[2:].strip())
            elif stripped.strip() == '':
                if desc_lines:
                    break
            else:
                break
        rec['description'] = '\n'.join(desc_lines)

        # #160: extract `if confidence >= X` gates with line numbers, plus
        # clamp_auto cap idiom (currently only labeler.ag, gates promote at 0.85).
        gates = []
        for lineno, line in enumerate(ag_lines, 1):
            m = re.search(r'\bif\s+confidence\s+>=\s+([0-9]+(?:\.[0-9]+)?)', line)
            if m:
                gates.append({'level': float(m.group(1)), 'line': lineno})
        rec['confidence_gates'] = gates
        ag_text = ''.join(ag_lines)
        if re.search(r'\bfn\s+clamp_auto\s*\(', ag_text):
            cm = re.search(r'\blet\s+cap\s*=\s*([0-9]+(?:\.[0-9]+)?)', ag_text)
            if cm:
                rec['confidence_cap'] = float(cm.group(1))

    # Experience data (from .agentis/experience/<agent_id>.jsonl)
    agent_id = rec['agent_id']
    if agent_id and os.path.isdir(exp_dir):
        exp_path = os.path.join(exp_dir, agent_id + '.jsonl')
        if os.path.isfile(exp_path):
            entries = []
            try:
                with open(exp_path) as f:
                    for line in f:
                        line = line.strip()
                        if not line:
                            continue
                        try:
                            entries.append(json.loads(line))
                        except json.JSONDecodeError:
                            continue
            except OSError:
                pass

            rec['experience_count'] = len(entries)
            total_exp += len(entries)
            if colony in colony_exp:
                colony_exp[colony] += len(entries)

            for e in entries:
                outcome = (e.get('outcome') or 'no-op').lower()
                if outcome in rec['experience_outcomes']:
                    rec['experience_outcomes'][outcome] += 1
                else:
                    rec['experience_outcomes']['no-op'] += 1

            # Rate: entries written in the last hour
            hour_ago = epoch - 3600
            recent_hour = [e for e in entries if (e.get('ts') or 0) > hour_ago]
            rec['experience_rate'] = round(len(recent_hour), 1)

            if entries:
                last = entries[-1]
                rec['last_action'] = str(last.get('in') or '')[:80]
                rec['last_action_ts'] = last.get('ts') or 0

            rec['recent_experience'] = entries[-10:]

            # #160: variance + slope over last 100 entries (matches the window
            # auto-promote.sh uses for delta_slope_window). Computing this
            # server-side over the full file means actionGate('evolve') tooltips
            # describe the actual sample size, not just the 10-entry UI slice.
            FITNESS_WINDOW = 100
            deltas_window = [e.get('delta') for e in entries[-FITNESS_WINDOW:] if isinstance(e.get('delta'), (int, float))]
            rec['fitness_window'] = len(deltas_window)
            if len(deltas_window) >= 2:
                mean = sum(deltas_window) / len(deltas_window)
                rec['experience_variance'] = sum((v - mean) ** 2 for v in deltas_window) / len(deltas_window)
            if len(deltas_window) >= 3:
                n = len(deltas_window)
                sX = sum(range(n))
                sY = sum(deltas_window)
                sXY = sum(i * v for i, v in enumerate(deltas_window))
                sX2 = sum(i * i for i in range(n))
                denom = n * sX2 - sX * sX
                if denom != 0:
                    rec['experience_slope_recent'] = (n * sXY - sX * sY) / denom

    # Recent log lines
    if agent_id and os.path.isdir(log_dir):
        log_path = os.path.join(log_dir, agent_id + '.log')
        if os.path.isfile(log_path):
            try:
                with open(log_path) as f:
                    lines = f.readlines()
                rec['recent_logs'] = [l.rstrip('\n') for l in lines[-50:]]
            except OSError:
                pass

    result.append(rec)

colony_exp['total'] = total_exp

# --- Event timeline from log files ---
events = []
if os.path.isdir(log_dir):
    try:
        for fn in sorted(os.listdir(log_dir)):
            if not fn.endswith('.log'):
                continue
            aid = fn[:-4]
            role = id_to_role.get(aid, aid[:8])
            fpath = os.path.join(log_dir, fn)
            try:
                with open(fpath) as f:
                    lines = f.readlines()
                for line in lines[-30:]:
                    line = line.strip()
                    if not line:
                        continue
                    # Try to extract timestamp from line start. Two formats
                    # supported: (1) raw 13-digit epoch-ms produced by the
                    # agentis daemon (the actual production format), (2)
                    # bracketed/ISO YYYY-MM-DD[T ]HH:MM:SS (kept as a
                    # fallback for older logs and external producers; do
                    # NOT remove without auditing every log emitter).
                    ts_ms_match = re.match(r'^(\d{13})\s+(.*)', line)
                    ts_iso_match = re.match(r'^\[?(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2})\]?\s*(.*)', line)
                    ts = 0
                    content = line
                    if ts_ms_match:
                        try:
                            ts = int(ts_ms_match.group(1))
                            content = ts_ms_match.group(2)
                        except ValueError:
                            ts = 0
                    elif ts_iso_match:
                        iso = ts_iso_match.group(1).replace(' ', 'T')
                        try:
                            ts = int(datetime.datetime.fromisoformat(iso).timestamp() * 1000)
                            content = ts_iso_match.group(2)
                        except (ValueError, OSError):
                            ts = 0
                            content = ts_iso_match.group(2)
                    # Classify event type (word-boundary match to avoid
                    # false positives like "react"→action, "referred"→error)
                    etype = 'log'
                    cl = content.lower()
                    if re.search(r'\bemit\b', cl):
                        etype = 'emit'
                    elif re.search(r'\brecv\b|\blisten\b', cl):
                        etype = 'recv'
                    elif re.search(r'\bsuggest', cl):
                        etype = 'suggest'
                    elif re.search(r'\berror\b|\bfailed\b', cl):
                        etype = 'error'
                    elif re.search(r'\baction\b|\bdraft\b', cl):
                        etype = 'action'
                    elif re.search(r'\bfinding', cl):
                        etype = 'finding'
                    # Only include interesting events in timeline
                    if etype != 'log':
                        events.append({
                            'ts': ts,
                            'agent': role,
                            'type': etype,
                            'content': content[:200],
                        })
            except OSError:
                pass
    except OSError:
        pass
# Sort by timestamp descending, limit to 100. ts is integer epoch-ms; entries
# with ts == 0 (unparseable) sort to the end.
events.sort(key=lambda e: e.get('ts', 0), reverse=True)
events = events[:100]

# --- Confidence change log ---
conf_changes = []
conf_log_path = os.path.join(dash_dir, 'confidence-log.jsonl')
if os.path.isfile(conf_log_path):
    try:
        with open(conf_log_path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    conf_changes.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except OSError:
        pass
conf_changes = conf_changes[-50:]

output = {
    'agents': result,
    'experience_counts': colony_exp,
    'events': events,
    'confidence_changes': conf_changes,
}
print(json.dumps(output))
PY
    )"
    if ! echo "$COLLECTOR_JSON" | python3 -c 'import sys,json;json.loads(sys.stdin.read())' 2>/dev/null; then
        COLLECTOR_JSON='{"agents":[],"experience_counts":{"total":0},"events":[],"confidence_changes":[]}'
    fi

    local REMEDIATION
    REMEDIATION="$(agentis remediation history --limit 5 --json 2>/dev/null || echo '[]')"

    # --- History append ---
    # #143: aggregator never writes 0.0 for null confidence. Colonies where
    # every agent has null confidence are excluded from the history entry
    # entirely (they don't appear in the avg_conf dict). Regression code
    # on the JS side filters stale zeros from old entries.
    python3 - "$HISTORY_FILE" "$EPOCH" "$COLLECTOR_JSON" "$COLONY_LIST_PY" <<'PYHISTORY'
import sys, os, json
path, epoch = sys.argv[1], int(sys.argv[2])
try:
    collector = json.loads(sys.argv[3])
except (json.JSONDecodeError, TypeError, ValueError):
    collector = {'agents': [], 'experience_counts': {'total': 0}}
try:
    colony_list = json.loads(sys.argv[4])
except (json.JSONDecodeError, TypeError, ValueError):
    colony_list = []
try:
    with open(path) as f:
        history = json.load(f)
except (json.JSONDecodeError, FileNotFoundError):
    history = []
# Compute per-colony average confidence, skipping null agents (#140, #143)
colony_conf = {}
colony_count = {}
for a in collector.get('agents', []):
    col = a.get('colony', '')
    v = a.get('confidence')
    if v is None or not col:
        continue
    colony_conf[col] = colony_conf.get(col, 0.0) + v
    colony_count[col] = colony_count.get(col, 0) + 1
# #143: only include colonies with real data — never write 0.0 for all-null
avg_conf = {}
for col in colony_conf:
    if colony_count.get(col, 0) > 0:
        avg_conf[col] = round(colony_conf[col] / colony_count[col], 3)
entry = {
    't': epoch,
    'experience': collector.get('experience_counts', {'total': 0}),
    'confidence': avg_conf,
}
history.append(entry)
cutoff = epoch - 7 * 86400
history = [h for h in history if h['t'] > cutoff]
tmp = path + '.tmp.' + str(os.getpid())
with open(tmp, 'w') as f:
    json.dump(history, f)
os.replace(tmp, path)
PYHISTORY

    local HISTORY
    HISTORY="$(cat "$HISTORY_FILE" 2>/dev/null || echo '[]')"

    local COLONY_LIST_JS=""
    for col in "${COLONIES[@]}"; do
        COLONY_LIST_JS="${COLONY_LIST_JS}\"${col}\","
    done
    COLONY_LIST_JS="[${COLONY_LIST_JS%,}]"

    # --- HTML generation ---
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
    --bg: #0a0a0a; --surface: rgba(0,0,0,0.85); --surface2: rgba(0,20,30,0.7);
    --border: rgba(0,255,255,0.2); --border2: rgba(0,255,255,0.08);
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

  /* --- Federation Down Banner --- */
  .fed-down-banner {
    display: none; padding: 14px 20px; margin-bottom: 16px;
    background: rgba(255,255,0,0.08); border: 2px solid var(--yellow);
    border-radius: 4px; color: var(--yellow); font-size: 14px;
    text-align: center; letter-spacing: 1px;
    text-shadow: 0 0 10px rgba(255,255,0,0.3);
    animation: pulse-banner 2s infinite;
  }
  .fed-down-banner.visible { display: block; }
  @keyframes pulse-banner {
    0%,100% { box-shadow: 0 0 10px rgba(255,255,0,0.15); }
    50% { box-shadow: 0 0 25px rgba(255,255,0,0.3); }
  }
  .fed-down-banner .start-btn {
    background: transparent; border: 1px solid var(--yellow); color: var(--yellow);
    font-family: inherit; font-size: 11px; padding: 4px 12px; cursor: pointer;
    border-radius: 2px; margin-left: 16px; letter-spacing: 1px;
    transition: all 0.2s;
  }
  .fed-down-banner .start-btn:hover { background: var(--yellow); color: #000; }

  /* --- Stats Row --- */
  .stats-row { display: flex; gap: 16px; margin-bottom: 16px; flex-wrap: wrap; }
  .stat-box {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 4px; padding: 12px 16px; flex: 1; min-width: 140px; text-align: center;
    box-shadow: 0 0 15px rgba(0,255,255,0.05);
  }
  .stat-value { font-size: 28px; color: var(--cyan); text-shadow: 0 0 15px rgba(0,255,255,0.4); }
  .stat-label { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 2px; margin-top: 4px; }

  /* --- Grid & Cards --- */
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

  /* --- Tables --- */
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th {
    text-align: left; padding: 6px 8px; color: var(--muted); font-weight: 400;
    font-size: 10px; text-transform: uppercase; letter-spacing: 1px;
    border-bottom: 1px solid var(--border); cursor: pointer; user-select: none;
    white-space: nowrap;
  }
  th:hover { color: var(--cyan); }
  th .sort-arrow { font-size: 9px; margin-left: 2px; }
  td { padding: 5px 8px; border-bottom: 1px solid var(--border2); }
  tr:last-child td { border-bottom: none; }
  tr.clickable { cursor: pointer; }
  tr.clickable:hover td { background: rgba(0,255,255,0.05); }

  /* --- Badges --- */
  .badge {
    display: inline-block; padding: 1px 8px; border-radius: 2px;
    font-size: 10px; letter-spacing: 1px; text-transform: uppercase;
  }
  .badge-running { border: 1px solid var(--green); color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.3); }
  .badge-stopped { border: 1px solid var(--red); color: var(--red); }
  .badge-healthy { border: 1px solid var(--green); color: var(--green); }
  .badge-degraded { border: 1px solid var(--yellow); color: var(--yellow); }
  .badge-error { border: 1px solid var(--red); color: var(--red); }
  .badge-critical { border: 1px solid var(--red); color: var(--red); text-shadow: 0 0 6px rgba(255,68,68,0.4); }
  .badge-quarantine { border: 1px solid var(--magenta); color: var(--magenta); text-shadow: 0 0 6px rgba(255,0,255,0.3); }
  .badge-observe { border: 1px solid var(--muted); color: var(--muted); }
  .badge-suggest { border: 1px solid var(--yellow); color: var(--yellow); text-shadow: 0 0 6px rgba(255,255,0,0.3); }
  .badge-act { border: 1px solid var(--green); color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.3); }
  .badge-na { border: 1px solid var(--muted); color: var(--muted); }
  .badge-dead { border: 1px solid var(--red); color: var(--red); background: rgba(255,68,68,0.1); }
  .agent-name { color: var(--cyan); text-shadow: 0 0 6px rgba(0,255,255,0.2); }
  .colony-name { color: var(--copper); }
  .muted { color: var(--muted); font-style: italic; }
  .conf-indicator { font-size: 11px; margin-left: 4px; }
  .conf-indicator.up { color: var(--green); }
  .conf-indicator.down { color: var(--red); }
  .conf-indicator.evolve { color: var(--magenta); }
  .empty { color: var(--muted); font-style: italic; font-size: 11px; }

  /* --- Phase Readiness --- */
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

  /* --- Promote Candidates --- */
  .promote-item { padding: 6px 0; border-bottom: 1px solid var(--border2); font-size: 12px; }
  .promote-item:last-child { border-bottom: none; }
  .promote-check { color: var(--green); margin-right: 6px; }
  .promote-cross { color: var(--red); margin-right: 6px; }
  .promote-reason { color: var(--muted); font-size: 11px; }
  .promote-suggest { color: var(--yellow); font-size: 11px; }

  /* --- Event Timeline --- */
  .timeline-header { display: flex; justify-content: space-between; align-items: center; }
  .timeline-clear-btn {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: 'Share Tech Mono', monospace;
    font-size: 10px; padding: 3px 8px; cursor: pointer;
    text-transform: uppercase; letter-spacing: 1px;
    border-radius: 2px; transition: all 0.15s;
  }
  .timeline-clear-btn:hover { color: var(--text); border-color: var(--text); }
  .timeline-banner {
    padding: 6px 10px; background: rgba(255,255,255,0.04);
    border-left: 2px solid var(--muted); font-size: 11px;
    color: var(--muted); margin-bottom: 6px;
  }
  .timeline-banner-show-all {
    background: transparent; border: none; color: var(--muted);
    font-family: 'Share Tech Mono', monospace; font-size: 11px;
    cursor: pointer; padding: 0; text-decoration: none;
  }
  .timeline-banner-show-all:hover { text-decoration: underline; color: var(--text); }
  .timeline { max-height: 300px; overflow-y: auto; overflow-x: visible; font-size: 11px; line-height: 1.8; }
  .timeline-entry { padding: 3px 0; border-bottom: 1px solid var(--border2); display: flex; gap: 8px; overflow: visible; }
  .timeline-entry:hover { background: rgba(0,255,255,0.03); }
  .timeline-ts { color: var(--muted); width: 145px; flex-shrink: 0; }
  .timeline-agent { color: var(--cyan); width: 130px; flex-shrink: 0; }
  .timeline-type { width: 60px; flex-shrink: 0; font-size: 10px; text-transform: uppercase; letter-spacing: 1px; }
  .timeline-type.emit { color: var(--green); }
  .timeline-type.recv { color: var(--yellow); }
  .timeline-type.suggest { color: var(--orange); }
  .timeline-type.error { color: var(--red); }
  .timeline-type.action { color: var(--cyan); }
  .timeline-type.finding { color: var(--magenta); }
  .timeline-content { color: var(--text); flex: 1; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

  /* --- Charts --- */
  .chart-container { margin: 8px 0; }
  .chart-legend { display: flex; gap: 16px; margin-top: 8px; font-size: 11px; flex-wrap: wrap; }
  .chart-legend span { display: flex; align-items: center; gap: 4px; }
  .legend-dot { width: 8px; height: 8px; border-radius: 1px; display: inline-block; }

  /* --- Detail Modal --- */
  .modal-overlay {
    display: none; position: fixed; inset: 0; z-index: 9000;
    background: rgba(0,0,0,0.8); backdrop-filter: blur(4px);
    justify-content: center; align-items: flex-start;
    padding: 40px 20px; overflow-y: auto;
  }
  .modal-overlay.visible { display: flex; }
  .modal-content {
    width: 100%; max-width: 900px;
    background: var(--bg); border: 1px solid var(--cyan);
    border-radius: 6px; box-shadow: 0 0 40px rgba(0,255,255,0.2);
    padding: 24px;
  }
  .modal-header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 16px; padding-bottom: 12px;
    border-bottom: 1px solid var(--border);
  }
  .modal-header h2 {
    font-size: 16px; font-weight: 400; color: var(--cyan);
    text-shadow: 0 0 12px rgba(0,255,255,0.4);
    letter-spacing: 1px; border-bottom: none; margin-bottom: 0; padding-bottom: 0;
  }
  .modal-header .colony-tag { color: var(--copper); font-size: 12px; margin-left: 12px; }
  .modal-close {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: inherit; font-size: 16px;
    width: 32px; height: 32px; cursor: pointer; border-radius: 2px;
    transition: all 0.15s; line-height: 1;
  }
  .modal-close:hover { color: var(--cyan); border-color: var(--cyan); }
  .modal-desc { color: var(--muted); font-size: 11px; margin-bottom: 16px; line-height: 1.6; white-space: pre-wrap; }
  .modal-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px; }
  .modal-section { margin-bottom: 16px; }
  .modal-section h3 {
    font-size: 11px; color: var(--yellow); text-transform: uppercase;
    letter-spacing: 2px; margin-bottom: 8px; font-weight: 400;
  }
  .modal-meta { display: flex; gap: 24px; flex-wrap: wrap; margin-bottom: 16px; font-size: 12px; }
  .modal-meta-item { display: flex; flex-direction: column; gap: 2px; }
  .modal-meta-label { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 1px; }
  .modal-meta-value { color: var(--cyan); }
  .outcomes-bar { display: flex; height: 20px; border-radius: 2px; overflow: hidden; margin-top: 6px; }
  .outcomes-bar .seg { display: flex; align-items: center; justify-content: center; font-size: 9px; color: #000; }
  .outcomes-bar .seg-success { background: var(--green); }
  .outcomes-bar .seg-failure { background: var(--red); }
  .outcomes-bar .seg-noop { background: var(--muted); }
  .outcomes-legend { display: flex; gap: 16px; margin-top: 6px; font-size: 11px; }
  .log-feed { max-height: 200px; overflow-y: auto; font-size: 11px; color: var(--muted); line-height: 1.8; }
  .log-feed div { padding: 1px 0; border-bottom: 1px solid var(--border2); }
  .log-feed div:hover { color: var(--cyan); }
  .exp-table { max-height: 250px; overflow-y: auto; }
  .exp-table table { font-size: 11px; }

  /* --- Action Buttons --- */
  .action-bar { display: flex; gap: 8px; flex-wrap: wrap; padding-top: 16px; border-top: 1px solid var(--border); }
  .action-btn {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: inherit; font-size: 11px;
    padding: 6px 14px; cursor: pointer; border-radius: 2px;
    letter-spacing: 1px; transition: all 0.15s;
  }
  .action-btn:hover { color: var(--cyan); border-color: var(--cyan); }
  .action-btn.promote { border-color: var(--green); color: var(--green); }
  .action-btn.promote:hover { background: var(--green); color: #000; box-shadow: 0 0 8px rgba(0,255,0,0.4); }
  .action-btn.demote { border-color: var(--orange); color: var(--orange); }
  .action-btn.demote:hover { background: var(--orange); color: #000; }
  .action-btn.restart { border-color: var(--yellow); color: var(--yellow); }
  .action-btn.restart:hover { background: var(--yellow); color: #000; }
  .action-btn.quarantine-btn { border-color: var(--magenta); color: var(--magenta); }
  .action-btn.quarantine-btn:hover { background: var(--magenta); color: #000; }
  .action-btn.evolve { border-color: var(--cyan); color: var(--cyan); }
  .action-btn.evolve:hover { background: var(--cyan); color: #000; }
  .action-btn:disabled { opacity: 0.3; cursor: not-allowed; }
  /* #160: clickable "disabled" state opens the Why panel instead of being inert */
  .action-btn.is-disabled {
    opacity: 0.35; cursor: help; background: transparent !important;
    color: var(--muted) !important; border-color: var(--border) !important;
    box-shadow: none !important;
  }
  .action-btn.is-disabled:hover {
    opacity: 0.6; color: var(--muted) !important; border-color: var(--muted) !important;
  }

  /* #160: Why panel — slides in from the right when a disabled button or
     skipped recommendation is clicked. Explains the gating rule + evidence. */
  .why-panel {
    position: fixed; top: 0; right: 0; bottom: 0; width: 360px;
    background: var(--bg); border-left: 1px solid var(--cyan);
    box-shadow: -4px 0 24px rgba(0,255,255,0.15);
    z-index: 9500; padding: 20px; overflow-y: auto;
    transform: translateX(100%); transition: transform 0.2s ease-out;
    font-size: 12px;
  }
  .why-panel.visible { transform: translateX(0); }
  .why-panel-header {
    display: flex; justify-content: space-between; align-items: center;
    padding-bottom: 10px; margin-bottom: 14px; border-bottom: 1px solid var(--border);
  }
  .why-panel-header h3 {
    font-size: 11px; color: var(--yellow); text-transform: uppercase;
    letter-spacing: 2px; font-weight: 400; margin: 0;
  }
  .why-panel-close {
    background: transparent; border: 1px solid var(--border); color: var(--muted);
    width: 28px; height: 28px; cursor: pointer; border-radius: 2px;
    font-size: 16px; line-height: 1;
  }
  .why-panel-close:hover { color: var(--cyan); border-color: var(--cyan); }
  .why-panel-section { margin-bottom: 16px; }
  .why-panel-section h4 {
    font-size: 10px; color: var(--muted); text-transform: uppercase;
    letter-spacing: 1.5px; margin: 0 0 6px 0; font-weight: 400;
  }
  .why-panel-rule { color: var(--orange); line-height: 1.5; }
  .why-panel-evidence { color: var(--cyan); font-family: 'Share Tech Mono', monospace; line-height: 1.6; }
  .why-panel-action { color: var(--green); line-height: 1.5; }

  /* #160: skipped-candidates collapsed sub-section under Promote panel */
  .skipped-section { margin-top: 10px; }
  .skipped-section summary {
    cursor: pointer; color: var(--muted); font-size: 11px;
    padding: 4px 0; outline: none; user-select: none;
  }
  .skipped-section summary:hover { color: var(--cyan); }
  .skipped-row {
    display: flex; align-items: center; gap: 8px;
    padding: 4px 0; font-size: 11px; color: var(--muted);
  }
  .skipped-info {
    cursor: help; color: var(--yellow); border: 1px solid var(--border);
    padding: 0 5px; border-radius: 2px; font-size: 10px; line-height: 1.4;
  }
  .skipped-info:hover { color: var(--cyan); border-color: var(--cyan); }

  /* --- Buttons --- */
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

  /* --- Toast --- */
  .toast {
    position: fixed; right: 16px; bottom: 16px; z-index: 9999;
    max-width: 420px; padding: 12px 14px 12px 16px;
    background: var(--surface); border: 1px solid var(--yellow);
    border-radius: 4px; color: var(--text);
    font-family: 'Share Tech Mono', 'Courier New', monospace;
    font-size: 12px; line-height: 1.6;
    box-shadow: 0 0 20px rgba(255,255,0,0.35);
    cursor: pointer; animation: toast-in 0.25s ease-out;
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

  /* --- Notification region (persistent, in-page; for kill-button outcomes) --- */
  #notification-region { padding: 0 16px; }
  .notice {
    margin: 8px 0; padding: 10px 12px;
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 4px; color: var(--text);
    font-family: 'Share Tech Mono', 'Courier New', monospace;
    font-size: 12px; line-height: 1.6;
  }
  .notice-err { border-color: var(--red); box-shadow: 0 0 20px rgba(255,68,68,0.4); color: var(--red); }
  .notice-ok  { border-color: var(--green); box-shadow: 0 0 20px rgba(0,255,0,0.35); color: var(--green); }
  .notice-summary {
    font-size: 11px; letter-spacing: 2px; text-transform: uppercase;
    margin-bottom: 6px;
  }
  .notice-err .notice-summary { color: var(--red); text-shadow: 0 0 6px rgba(255,68,68,0.4); }
  .notice-ok  .notice-summary { color: var(--green); text-shadow: 0 0 6px rgba(0,255,0,0.4); }
  .notice details { margin-top: 6px; color: var(--text); }
  .notice details summary {
    cursor: pointer; color: var(--muted); font-size: 11px;
    user-select: none;
  }
  .notice details summary:hover { color: var(--text); }
  .notice .notice-json {
    margin: 6px 0 0; padding: 6px 8px;
    background: rgba(0,255,255,0.05);
    border-left: 2px solid var(--cyan); color: var(--cyan);
    font-family: 'Share Tech Mono', 'Courier New', monospace;
    font-size: 11px; white-space: pre-wrap; word-break: break-all;
    max-height: 240px; overflow: auto;
  }
  .notice-actions { display: flex; gap: 8px; margin-top: 8px; }
  .notice-dismiss, .notice-copy {
    background: transparent; border: 1px solid var(--border);
    color: var(--muted); font-family: 'Share Tech Mono', monospace;
    font-size: 10px; padding: 4px 10px; cursor: pointer;
    text-transform: uppercase; letter-spacing: 1px;
    border-radius: 2px; transition: all 0.15s;
  }
  .notice-dismiss:hover, .notice-copy:hover { color: var(--text); border-color: var(--text); }

  .tooltip {
    position: relative; cursor: help;
  }
  .tooltip .tip-text {
    visibility: hidden; opacity: 0; position: absolute;
    bottom: 100%; left: 50%; transform: translateX(-50%);
    background: #111; border: 1px solid var(--border); color: var(--text);
    padding: 6px 10px; border-radius: 3px; font-size: 11px;
    white-space: pre-wrap; max-width: 320px; z-index: 100;
    transition: opacity 0.15s; pointer-events: none;
  }
  .tooltip:hover .tip-text { visibility: visible; opacity: 1; }
  ::-webkit-scrollbar { width: 4px; }
  ::-webkit-scrollbar-track { background: transparent; }
  ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 2px; }
</style>
</head>
<body>
HTMLEOF

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
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px;">
      <button class="kill-btn" id="kill-btn" onclick="killSwitch()">Kill Federation</button>
      <label style="font-size:10px;color:var(--muted);letter-spacing:1px;cursor:pointer;"><input type="checkbox" id="kill-no-backup" style="vertical-align:middle;margin-right:4px;"> skip backup</label>
    </div>
  </div>
</div>
<div id="notification-region" aria-live="polite"></div>
HEADEREOF

    cat <<'HTMLEOF'
<div class="fed-down-banner" id="fed-down-banner">
  &#x26A0; Federation is stopped — showing last-seen data
  <button class="start-btn" onclick="startFederation()">Start Federation</button>
</div>

<div class="stats-row" id="stats-row"></div>

<div class="grid">

<div class="card full">
<h2>Agents</h2>
<div id="agent-table" style="overflow-x:auto;"></div>
</div>

<div class="card">
<h2>Phase Readiness</h2>
<div id="readiness"></div>
</div>

<div class="card">
<h2>Promote Candidates</h2>
<div id="promote-candidates"></div>
</div>

<div class="card full">
<div class="timeline-header">
  <h2>Event Timeline</h2>
  <button class="timeline-clear-btn" id="timeline-clear-btn">Clear</button>
</div>
<div class="timeline-banner" id="timeline-banner" hidden></div>
<div id="event-timeline" class="timeline"></div>
</div>

<div class="card">
<h2>Experience Growth</h2>
<div id="experience-trend" class="chart-container"></div>
</div>

<div class="card">
<h2>Confidence Trend</h2>
<div id="confidence-trend" class="chart-container"></div>
</div>

</div>

<!-- Detail Modal -->
<div class="modal-overlay" id="detail-modal">
<div class="modal-content" id="modal-body"></div>
</div>

<!-- #160: Why panel for disabled buttons + skipped recommendations -->
<div class="why-panel" id="why-panel">
  <div class="why-panel-header">
    <h3 id="why-panel-title">Why this is unavailable</h3>
    <button class="why-panel-close" onclick="closeWhyPanel()" title="Close (Esc)">&times;</button>
  </div>
  <div id="why-panel-body"></div>
</div>

<script>
HTMLEOF

    # Inject data
    cat <<DATAEOF
const data = ${COLLECTOR_JSON};
const history = ${HISTORY};
const remediation = ${REMEDIATION};
const colonyList = ${COLONY_LIST_JS};
const nowEpoch = ${EPOCH};
const timestamp = "${TIMESTAMP}";
const totalAgents = ${AGENT_COUNT};
const FED_NAME = "${FED_NAME}";
DATAEOF

    cat <<'JSEOF'

// --- Palette & Utilities ---
const palette = ['#58a6ff','#00ff00','#ffff00','#ff8800','#ff00ff','#00ffcc','#ff6666','#aa88ff'];
const colonyColors = {};
colonyList.forEach((c, i) => colonyColors[c] = palette[i % palette.length]);

document.getElementById('clock').textContent = timestamp;

function esc(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }

function relTime(ts) {
  if (!ts) return '';
  const diff = nowEpoch - ts;
  if (diff < 0) return 'just now';
  if (diff < 60) return diff + 's ago';
  if (diff < 3600) return Math.floor(diff/60) + 'm ago';
  if (diff < 86400) return Math.floor(diff/3600) + 'h ago';
  return Math.floor(diff/86400) + 'd ago';
}

function formatTimestamp(ms) {
  if (!ms) return '';
  const d = new Date(ms);
  const pad = n => String(n).padStart(2, '0');
  return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate())
       + ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

const TIMELINE_CURSOR_KEY = 'dashboard.timeline.cursorMs.' + FED_NAME;

// --- Refresh countdown ---
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
  fetch('/refresh', { method: 'POST' })
    .catch(() => {})
    .finally(() => location.reload());
}

document.addEventListener('keydown', (e) => {
  if (e.key === 'r' && !e.ctrlKey && !e.metaKey && !e.altKey && !e.shiftKey && !e.repeat) {
    const tag = (e.target && e.target.tagName) || '';
    if (tag === 'INPUT' || tag === 'TEXTAREA' || (e.target && e.target.isContentEditable)) return;
    e.preventDefault();
    manualRefresh();
  }
  if (e.key === 'Escape') { closeModal(); closeWhyPanel(); }
});

const agents = data.agents || [];
const experienceCounts = data.experience_counts || {};
const events = data.events || [];
const confChanges = data.confidence_changes || [];

// --- Federation Down Detection ---
(function() {
  const running = agents.filter(a => a.state === 'running');
  if (running.length === 0 && agents.length > 0) {
    document.getElementById('fed-down-banner').classList.add('visible');
  }
})();

// --- Stats Row ---
(function() {
  const el = document.getElementById('stats-row');
  const running = agents.filter(a => a.state === 'running').length;
  const totalExperience = experienceCounts.total || 0;
  let sum = 0, n = 0;
  agents.forEach(a => { if (a.confidence != null) { sum += a.confidence; n += 1; } });
  const avgConf = n ? sum / n : 0;
  // #144: consistent NO DATA label when all agents are null
  const phase = n === 0 ? 'NO DATA' : avgConf >= 0.85 ? 'AUTONOMOUS' : avgConf >= 0.6 ? 'SUGGEST' : 'OBSERVE';
  const avgColor = n === 0 ? 'var(--muted)' : avgConf >= 0.85 ? 'var(--green)' : avgConf >= 0.6 ? 'var(--yellow)' : 'var(--cyan)';
  const avgLabel = n === 0 ? '\u2014' : avgConf.toFixed(2);
  const quarantined = agents.filter(a => a.quarantine === 'yes').length;
  const deadPids = agents.filter(a => a.state === 'running' && a.pid > 0 && !a.pid_alive).length;
  el.innerHTML =
    '<div class="stat-box"><div class="stat-value">' + running + '/' + totalAgents + '</div><div class="stat-label">Agents Running</div></div>' +
    '<div class="stat-box"><div class="stat-value" style="color:' + avgColor + '">' + avgLabel + '</div><div class="stat-label">Avg Confidence // ' + phase + '</div></div>' +
    '<div class="stat-box"><div class="stat-value">' + totalExperience + '</div><div class="stat-label">Experience Entries</div></div>' +
    '<div class="stat-box"><div class="stat-value" style="color:' + (quarantined > 0 ? 'var(--magenta)' : 'var(--green)') + '">' + quarantined + '</div><div class="stat-label">Quarantined</div></div>' +
    (deadPids > 0 ? '<div class="stat-box"><div class="stat-value" style="color:var(--red)">' + deadPids + ' \uD83D\uDC80</div><div class="stat-label">Dead PIDs</div></div>' : '');
})();

// --- Single Agent Table ---
let sortCol = 'colony';
let sortDir = 1;

function renderAgentTable() {
  const el = document.getElementById('agent-table');
  if (!agents.length) {
    el.innerHTML = '<span class="empty">No agents discovered.</span>';
    return;
  }
  const sorted = [...agents].sort((a, b) => {
    let va = a[sortCol], vb = b[sortCol];
    if (sortCol === 'confidence') { va = va == null ? -1 : va; vb = vb == null ? -1 : vb; }
    if (sortCol === 'experience_count' || sortCol === 'experience_rate' || sortCol === 'tick_ok') {
      va = va || 0; vb = vb || 0;
    }
    if (sortCol === 'success_pct') {
      va = (a.tick_ok + a.tick_err) > 0 ? a.tick_ok / (a.tick_ok + a.tick_err) : -1;
      vb = (b.tick_ok + b.tick_err) > 0 ? b.tick_ok / (b.tick_ok + b.tick_err) : -1;
    }
    if (typeof va === 'string') va = va.toLowerCase();
    if (typeof vb === 'string') vb = vb.toLowerCase();
    if (va < vb) return -sortDir;
    if (va > vb) return sortDir;
    return 0;
  });

  function thSort(col, label) {
    const arrow = sortCol === col ? (sortDir === 1 ? ' \u25B2' : ' \u25BC') : '';
    return '<th onclick="doSort(\'' + col + '\')">' + label + '<span class="sort-arrow">' + arrow + '</span></th>';
  }

  // Confidence change indicators from recent confidence log
  const recentChanges = {};
  const dayAgo = nowEpoch - 86400;
  confChanges.forEach(c => {
    if ((c.t || 0) > dayAgo) {
      const prev = recentChanges[c.agent];
      recentChanges[c.agent] = { value: c.value, t: c.t, prev: prev ? prev.value : null };
    }
  });

  let html = '<table>' +
    '<tr>' + thSort('name', 'Name') + thSort('colony', 'Colony') +
    thSort('confidence', 'Confidence') +
    '<th>Health</th>' +
    thSort('tick_ok', 'Ticks') +
    thSort('success_pct', 'Success%') +
    thSort('experience_count', 'Learning') +
    '<th>Last Action</th></tr>';

  sorted.forEach(a => {
    const isDead = a.state === 'running' && a.pid > 0 && !a.pid_alive;
    const isQuar = a.quarantine === 'yes';

    // Confidence display
    let confHtml;
    if (a.confidence == null) {
      confHtml = '<span class="badge badge-na">\u2014</span>';
    } else {
      const phase = a.confidence >= 0.85 ? 'act' : a.confidence >= 0.6 ? 'suggest' : 'observe';
      confHtml = '<span class="badge badge-' + phase + '">' + a.confidence.toFixed(2) + '</span>';
      // #145: tooltip with generation + written_at
      if (a.confidence_generation != null || a.confidence_written_at) {
        const gen = a.confidence_generation != null ? 'gen ' + a.confidence_generation : '';
        const wrt = a.confidence_written_at ? relTime(a.confidence_written_at) : '';
        const tipParts = [gen, wrt].filter(Boolean).join(', ');
        confHtml = '<span class="tooltip">' + confHtml + '<span class="tip-text">' + esc(tipParts) + '</span></span>';
      }
      // Confidence change indicator
      const ch = recentChanges[a.name];
      if (ch && ch.prev !== null && ch.prev !== undefined) {
        if (ch.value > ch.prev) confHtml += '<span class="conf-indicator up">\u25B2</span>';
        else if (ch.value < ch.prev) confHtml += '<span class="conf-indicator down">\u25BC</span>';
      }
    }

    // Health display
    let healthHtml;
    if (isDead) {
      healthHtml = '<span class="badge badge-dead">\uD83D\uDC80 dead</span>';
    } else if (isQuar) {
      healthHtml = '<span class="badge badge-quarantine">quarantine</span>';
    } else if (a.state !== 'running') {
      healthHtml = '<span class="badge badge-stopped">stopped</span>';
    } else {
      const hc = a.health === 'healthy' ? 'healthy' : a.health === 'degraded' ? 'degraded' : a.health === 'critical' ? 'critical' : 'error';
      healthHtml = '<span class="badge badge-' + hc + '">' + esc(a.health) + '</span>';
    }

    // Ticks
    const ticksHtml = (a.state === 'running') ? a.tick_ok + '/' + a.tick_err : '<span class="muted">\u2014</span>';

    // Success %
    const total = a.tick_ok + a.tick_err;
    const successHtml = total > 0 ? Math.round(a.tick_ok / total * 100) + '%' : '<span class="muted">\u2014</span>';

    // Learning
    let learnHtml;
    if (a.experience_count > 0) {
      learnHtml = a.experience_count + ' entries';
      if (a.experience_rate > 0) learnHtml += ' <span style="color:var(--green)">(+' + a.experience_rate + '/h)</span>';
    } else if (a.state === 'running' && a.experience_count === 0) {
      learnHtml = '<span class="muted">(none \u2014 reactive)</span>';
    } else {
      learnHtml = '<span class="muted">\u2014</span>';
    }

    // Last action
    let actionHtml;
    if (a.last_action) {
      const truncated = a.last_action.length > 40 ? a.last_action.slice(0, 40) + '\u2026' : a.last_action;
      actionHtml = '\u201C' + esc(truncated) + '\u201D <span class="muted">' + relTime(a.last_action_ts) + '</span>';
    } else if (a.state === 'running' && a.started_at) {
      actionHtml = '<span class="muted">(idle since ' + new Date(a.started_at * 1000).toLocaleTimeString() + ')</span>';
    } else {
      actionHtml = '<span class="muted">\u2014</span>';
    }

    html += '<tr class="clickable" onclick="openDetail(\'' + esc(a.name) + '\')">' +
      '<td class="agent-name">' + esc(a.name) + '</td>' +
      '<td class="colony-name">' + esc(a.colony) + '</td>' +
      '<td>' + confHtml + '</td>' +
      '<td>' + healthHtml + '</td>' +
      '<td>' + ticksHtml + '</td>' +
      '<td>' + successHtml + '</td>' +
      '<td>' + learnHtml + '</td>' +
      '<td>' + actionHtml + '</td>' +
      '</tr>';
  });
  html += '</table>';
  el.innerHTML = html;
}

function doSort(col) {
  if (sortCol === col) sortDir *= -1;
  else { sortCol = col; sortDir = 1; }
  renderAgentTable();
}

renderAgentTable();

// --- Phase Readiness ---
// #144: colony with all-null agents renders muted "—" instead of 0.00
(function() {
  const el = document.getElementById('readiness');
  const avgConf = {};
  const confCount = {};
  agents.forEach(a => {
    if (a.confidence == null) return;
    avgConf[a.colony] = (avgConf[a.colony] || 0) + a.confidence;
    confCount[a.colony] = (confCount[a.colony] || 0) + 1;
  });
  colonyList.forEach(col => {
    if (confCount[col]) avgConf[col] = avgConf[col] / confCount[col];
  });

  function estimateEta(colony, cur, hasData) {
    if (!hasData) return { text: '\u2014', color: 'var(--muted)' };
    if (cur >= 0.85) return { text: 'AUTONOMOUS', color: 'var(--green)' };
    const target = cur < 0.6 ? 0.6 : 0.85;
    const label = target === 0.6 ? 'SUGGEST' : 'AUTONOMOUS';
    if (history.length < 120) return { text: 'collecting data...', color: 'var(--muted)' };
    const dayAgo = nowEpoch - 86400;
    // #143: filter stale zeros from regression — old history entries may
    // have 0.0 for colonies that were actually all-null before the fix.
    const pts = history
      .filter(h => h.t > dayAgo && h.confidence && h.confidence[colony] != null && h.confidence[colony] > 0)
      .map(h => ({t:h.t, v:h.confidence[colony]}));
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
    const hasData = !!confCount[col];
    const v = hasData ? avgConf[col] : 0;
    const pct = Math.min(Math.round(v * 100), 100);
    const color = colonyColors[col];
    const eta = estimateEta(col, v, hasData);
    html += '<div class="phase-row"><span class="phase-colony">' + esc(col) + '</span>';
    html += '<div class="phase-bar-outer">';
    html += '<div class="phase-marker" style="left:60%"><span class="phase-marker-label">0.6 suggest</span></div>';
    html += '<div class="phase-marker" style="left:85%"><span class="phase-marker-label">0.85 autonomous</span></div>';
    if (hasData) {
      html += '<div class="phase-bar-inner" style="width:' + pct + '%;background:' + color + ';box-shadow:0 0 10px ' + color + '50;color:#000">' + v.toFixed(2) + '</div>';
    } else {
      // #144: muted "—" label for all-null colonies
      html += '<div class="phase-bar-inner" style="width:0%;"></div>';
      html += '<span style="position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);color:var(--muted);font-size:11px;font-style:italic">\u2014</span>';
    }
    html += '</div><span class="phase-eta" style="color:' + eta.color + '">' + eta.text + '</span></div>';
  });
  el.innerHTML = html;
})();

// --- Promote Candidates (#160 actionable-only filter) ---
// Four filter rules in order:
//   1. fitness criteria (>=200 entries, success>=95%, slope>=0) — same as #148 cron
//   2. target level exists in agent's confidence_gates (no-op-at-source guard)
//   3. action would cross a behavioural tier (observable change)
//   4. target not above clamp_auto cap
// Only rows passing all four appear in the main list. Everything else falls
// into a collapsed "Skipped candidates" section with the reason + Why button.
(function() {
  const el = document.getElementById('promote-candidates');
  const SUGGEST_TARGET = 0.85;
  let actionableHtml = '';
  let skippedHtml = '';
  let actionableCount = 0;
  let skippedCount = 0;

  agents.forEach(a => {
    const f = computeFitness(a);
    const fitnessOK = f.count >= 200 && f.successRate >= 0.95 && f.slope >= 0;

    // Skip silently: no entries AND not running. Stats row already surfaces
    // these as inactive — listing them as "skipped" is just noise.
    if (f.count === 0 && a.state !== 'running') return;

    if (!fitnessOK) {
      let reason;
      if (f.count === 0) reason = '0 entries \u2014 reactive (no fitness signal yet)';
      else if (f.count < 200) reason = f.count + ' entries \u2014 below 200 threshold';
      else if (f.successRate < 0.95) reason = Math.round(f.successRate * 100) + '% success \u2014 below 95% threshold';
      else reason = (f.slope >= 0 ? '+' : '') + f.slope.toFixed(3) + ' slope \u2014 fitness regressing';
      skippedHtml += '<div class="skipped-row"><span class="agent-name">' + esc(a.name) + '</span><span>\u2014 ' + esc(reason) + '</span></div>';
      skippedCount++;
      return;
    }

    // Fitness passed — does the agent's source actually support promote-to-suggest?
    const promoteGate = actionGate(a, 'promote', SUGGEST_TARGET);
    if (!promoteGate.enabled) {
      registerWhy(a.name, 'rec-promote', promoteGate);
      skippedHtml += '<div class="skipped-row"><span class="agent-name">' + esc(a.name) + '</span>';
      skippedHtml += '<span>\u2014 promote to ' + SUGGEST_TARGET.toFixed(2) + ' would be a no-op</span>';
      skippedHtml += '<span class="skipped-info" onclick="showWhy(\'' + esc(a.name) + '\',\'rec-promote\')">why?</span></div>';
      skippedCount++;
      return;
    }

    actionableCount++;
    actionableHtml += '<div class="promote-item"><span class="promote-check">\u2713</span>';
    actionableHtml += '<span class="agent-name">' + esc(a.name) + '</span> ';
    actionableHtml += f.count + ' entries, ' + Math.round(f.successRate * 100) + '% success, ';
    actionableHtml += (f.slope >= 0 ? '+' : '') + f.slope.toFixed(3) + ' slope';
    if (a.confidence != null) actionableHtml += ', on ' + a.confidence.toFixed(2);
    actionableHtml += ' <span class="promote-suggest">\u2192 suggest ' + SUGGEST_TARGET.toFixed(2) + '</span>';
    actionableHtml += '</div>';
  });

  let html = '';
  if (actionableCount === 0) {
    html += '<span class="empty">No agents meet all the criteria right now \u2014 ready + feasible + beneficial.</span>';
  } else {
    html += actionableHtml;
  }
  if (skippedCount > 0) {
    html += '<details class="skipped-section"><summary>Skipped candidates (' + skippedCount + ')</summary>';
    html += skippedHtml;
    html += '</details>';
  }
  el.innerHTML = html;
})();

// --- Event Timeline ---
(function() {
  const el = document.getElementById('event-timeline');
  const banner = document.getElementById('timeline-banner');
  const cursor = parseInt(localStorage.getItem(TIMELINE_CURSOR_KEY) || '0', 10);
  // Filter rule: entries with ts === 0 (no parseable timestamp) always pass
  // through so the operator can still see them; entries with ts >= cursor
  // pass; older entries are hidden until "Show all" is clicked.
  const filtered = events.filter(e => !cursor || !e.ts || e.ts >= cursor);
  const hidden = events.length - filtered.length;

  if (banner) {
    if (hidden > 0) {
      banner.hidden = false;
      banner.innerHTML = 'Hidden ' + hidden + ' entries before ' +
        esc(formatTimestamp(cursor)) +
        ' &mdash; <button type="button" class="timeline-banner-show-all" id="timeline-show-all">Show all</button>';
      const showAll = document.getElementById('timeline-show-all');
      if (showAll) {
        showAll.addEventListener('click', () => {
          localStorage.removeItem(TIMELINE_CURSOR_KEY);
          location.reload();
        });
      }
    } else {
      banner.hidden = true;
      banner.innerHTML = '';
    }
  }

  if (!filtered.length) {
    el.innerHTML = '<span class="empty">No inter-agent events captured yet.</span>';
  } else {
    let html = '';
    filtered.forEach(e => {
      const tsDisplay = formatTimestamp(e.ts) || '?';
      let tip;
      if (e.ts) {
        try { tip = new Date(e.ts).toISOString() + '\n' + relTime(e.ts / 1000); }
        catch (err) { tip = String(e.ts); }
      } else {
        tip = 'no timestamp parsed from log line';
      }
      html += '<div class="timeline-entry">' +
        '<span class="timeline-ts tooltip">' + esc(tsDisplay) +
          '<span class="tip-text">' + esc(tip) + '</span>' +
        '</span>' +
        '<span class="timeline-agent">' + esc(e.agent) + '</span>' +
        '<span class="timeline-type ' + e.type + '">' + esc(e.type) + '</span>' +
        '<span class="timeline-content">' + esc(e.content) + '</span>' +
        '</div>';
    });
    el.innerHTML = html;
  }

  // Wire Clear: stamp the cursor at "now" and reload (the dashboard's
  // existing meta-refresh idiom — see <meta http-equiv="refresh"> at top).
  const clearBtn = document.getElementById('timeline-clear-btn');
  if (clearBtn) {
    // TODO(#167): selective-clear in v2 — see issue
    clearBtn.addEventListener('click', () => {
      localStorage.setItem(TIMELINE_CURSOR_KEY, String(Date.now()));
      location.reload();
    });
  }
})();

// --- Experience Growth Chart ---
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

// --- Confidence Trend Chart ---
(function() {
  const el = document.getElementById('confidence-trend');
  // #143: filter stale zeros from old history entries
  const validHistory = history.filter(h => h.confidence && Object.keys(h.confidence).length > 0);
  if (validHistory.length < 2) { el.innerHTML = '<span class="empty">Trend available after 2+ data points</span>'; return; }
  const W = 480, H = 140, PAD = 35;
  const tMin = validHistory[0].t, tMax = validHistory[validHistory.length - 1].t;
  const tRange = Math.max(tMax - tMin, 1);
  let svg = '<svg width="100%" viewBox="0 0 '+W+' '+(H+20)+'">';
  // Y axis: 0 to 1
  for (let i = 0; i <= 4; i++) {
    const y = 10+(H-10)*i/4;
    const label = (1 - i/4).toFixed(1);
    svg += '<line x1="'+PAD+'" y1="'+y+'" x2="'+W+'" y2="'+y+'" stroke="rgba(0,255,255,0.06)" />';
    svg += '<text x="'+(PAD-4)+'" y="'+(y+3)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="8" text-anchor="end">'+label+'</text>';
  }
  // Phase markers
  const suggestY = 10+(H-10)*(1-0.6);
  const actY = 10+(H-10)*(1-0.85);
  svg += '<line x1="'+PAD+'" y1="'+suggestY+'" x2="'+W+'" y2="'+suggestY+'" stroke="rgba(255,255,0,0.15)" stroke-dasharray="4,4" />';
  svg += '<line x1="'+PAD+'" y1="'+actY+'" x2="'+W+'" y2="'+actY+'" stroke="rgba(0,255,0,0.15)" stroke-dasharray="4,4" />';
  svg += '<line x1="'+PAD+'" y1="'+H+'" x2="'+W+'" y2="'+H+'" stroke="var(--border)" />';
  svg += '<text x="'+PAD+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9">'+new Date(tMin*1000).toLocaleDateString()+'</text>';
  svg += '<text x="'+W+'" y="'+(H+14)+'" fill="var(--muted)" font-family="Share Tech Mono,monospace" font-size="9" text-anchor="end">'+new Date(tMax*1000).toLocaleDateString()+'</text>';
  colonyList.forEach(col => {
    // #143: skip 0.0 values (stale zeros from before null-handling fix)
    const pts = validHistory.filter(h => h.confidence[col] != null && h.confidence[col] > 0).map(h => {
      const x = PAD+((h.t-tMin)/tRange)*(W-PAD);
      const y = 10+(H-10)*(1-h.confidence[col]);
      return x.toFixed(1)+','+y.toFixed(1);
    });
    if (pts.length > 1) {
      svg += '<polyline points="'+pts.join(' ')+'" fill="none" stroke="'+colonyColors[col]+'" stroke-width="1.5" opacity="0.8" />';
    }
  });
  svg += '</svg>';
  let legend = '<div class="chart-legend">';
  colonyList.forEach(col => { legend += '<span><span class="legend-dot" style="background:'+colonyColors[col]+';box-shadow:0 0 4px '+colonyColors[col]+'"></span>'+col+'</span>'; });
  legend += '</div>';
  el.innerHTML = svg + legend;
})();

// --- #160: Capability + fitness gating + Why panel ---
//
// Action buttons (and the "Promote candidates" panel) ask actionGate() whether
// a given action would actually change agent behaviour. The dashboard never
// surfaces actions that are no-ops at the source level.
//
// Tier model: an agent's `confidence_gates` define behavioural thresholds in
// its .ag tick body. Two confidence values fall in the same tier iff no gate
// sits between them — moving across them is a silent no-op. Promoting above a
// `clamp_auto` cap is also a no-op (the daemon clamps back on the next tick).

function computeFitness(a) {
  // Variance + slope are computed server-side over the last 100 entries
  // (parser block in this script). The fields are null when the agent has
  // <2 (variance) or <3 (slope) deltas in window. `window` reports the
  // actual sample size used so reason texts can quote the right number.
  const oc = a.experience_outcomes || { success: 0, failure: 0, 'no-op': 0 };
  const total = (oc.success || 0) + (oc.failure || 0) + (oc['no-op'] || 0);
  const successRate = total > 0 ? oc.success / total : 0;
  return {
    count: a.experience_count || 0,
    window: a.fitness_window || 0,
    successRate: successRate,
    slope: a.experience_slope_recent != null ? a.experience_slope_recent : 0,
    variance: a.experience_variance != null ? a.experience_variance : 0,
    sloperaw: a.experience_slope_recent,
    varianceraw: a.experience_variance,
  };
}

function tierOf(value, gates) {
  // largest gate <= value, or 0 if none (implicit observe-only floor)
  let t = 0;
  gates.forEach(g => { if (g <= value + 1e-9 && g > t) t = g; });
  return t;
}

function actionGate(a, type, target) {
  const gates = (a.confidence_gates || []).map(g => g.level).sort((x, y) => x - y);
  if (type === 'promote' || type === 'demote') {
    if (target == null) {
      return { enabled: false, ruleType: 'no-step', reason: 'Already at the ' + (type === 'promote' ? 'highest' : 'lowest') + ' confidence step.' };
    }
    const cur = a.confidence != null ? a.confidence : 0;
    const curTier = tierOf(cur, gates);
    const tgtTier = tierOf(target, gates);
    if (Math.abs(curTier - tgtTier) < 1e-9) {
      const dirWord = type === 'promote' ? 'Promoting' : 'Demoting';
      return {
        enabled: false, ruleType: 'no-branch',
        reason: dirWord + ' to ' + target.toFixed(2) + ' would not cross any `if confidence >= X` gate in ' + a.name + '.ag — agent stays in the same behavioural tier.',
        evidence: { gates: gates, current: cur, target: target, tier: curTier }
      };
    }
    if (a.confidence_cap != null && target > a.confidence_cap + 1e-9) {
      return {
        enabled: false, ruleType: 'capped',
        reason: 'Source caps confidence at ' + a.confidence_cap.toFixed(2) + ' (`clamp_auto` in ' + a.name + '.ag) — promote above the cap is reverted on next tick.',
        evidence: { cap: a.confidence_cap, target: target }
      };
    }
    return {
      enabled: true, ruleType: 'ok',
      reason: (type === 'promote' ? 'Promote' : 'Demote') + ' to ' + target.toFixed(2) + ': crosses gate (tier ' + curTier.toFixed(2) + ' \u2192 ' + tgtTier.toFixed(2) + ').'
    };
  }
  if (type === 'evolve') {
    const f = computeFitness(a);
    if (f.count < 100) {
      return {
        enabled: false, ruleType: 'few-entries',
        reason: 'Only ' + f.count + ' experience entries \u2014 need at least 100 for evolution to have data to select on.',
        evidence: f
      };
    }
    if (f.window < 2 || f.varianceraw == null) {
      return {
        enabled: false, ruleType: 'no-variance',
        reason: 'No fitness `delta` values in the last ' + f.window + ' entries \u2014 evolve has nothing to measure.',
        evidence: f
      };
    }
    if (f.variance < 1e-9) {
      return {
        enabled: false, ruleType: 'no-variance',
        reason: 'All last ' + f.window + ' entries returned identical fitness delta \u2014 evolve has no signal to select against.',
        evidence: f
      };
    }
    if (Math.abs(f.slope) < 1e-6) {
      return {
        enabled: false, ruleType: 'flat-slope',
        reason: 'Fitness slope flat over the last ' + f.window + ' entries (likely Opus plateau) \u2014 evolve unlikely to find improvement.',
        evidence: f
      };
    }
    return {
      enabled: true, ruleType: 'ok',
      reason: 'Evolve: ' + f.count + ' total entries, ' + f.window + '-entry window: variance ' + f.variance.toFixed(4) + ', slope ' + (f.slope >= 0 ? '+' : '') + f.slope.toFixed(3) + '.'
    };
  }
  return { enabled: true, ruleType: 'ok', reason: '' };
}

const WHY_FIX_HINT = {
  'no-branch': function(a, ev) {
    const existing = (ev.gates && ev.gates.length) ? ev.gates.map(g => g.toFixed(2)).join(', ') : 'none';
    return 'Add `if confidence >= ' + ev.target.toFixed(2) + ' { ... }` branch to ' +
      a.name + '.ag (current gates: ' + existing + ') and respawn the daemon.';
  },
  'capped': function(a, ev) {
    return 'Raise the cap inside `clamp_auto` in ' + a.name + '.ag (currently ' + ev.cap.toFixed(2) + '), or use a different agent that does not clamp.';
  },
  'few-entries': function(a, ev) {
    return 'Let the agent run longer in suggest mode \u2014 evolve needs at least 100 experience entries (currently ' + ev.count + ').';
  },
  'no-variance': function(a) {
    return 'Vary the agent\u2019s inputs or recover non-zero `delta` values from `experience` \u2014 evolve needs measurable fitness differences.';
  },
  'flat-slope': function(a) {
    return 'Wait for fitness signal to move, or accept the plateau \u2014 evolve cannot improve a flat surface.';
  },
  'no-step': function() {
    return 'No further confidence step in this direction. Confidence steps are 0.5 / 0.6 / 0.85.';
  }
};

function renderWhyEvidence(ev) {
  if (!ev) return '';
  const lines = [];
  if (ev.gates !== undefined) lines.push('gates in source: ' + (ev.gates.length ? ev.gates.map(g => g.toFixed(2)).join(', ') : '(none)'));
  if (ev.current !== undefined) lines.push('current confidence: ' + ev.current.toFixed(2));
  if (ev.target !== undefined) lines.push('target: ' + ev.target.toFixed(2));
  if (ev.tier !== undefined) lines.push('current tier: ' + ev.tier.toFixed(2));
  if (ev.cap !== undefined) lines.push('source cap: ' + ev.cap.toFixed(2));
  if (ev.count !== undefined) lines.push('experience entries (total): ' + ev.count);
  if (ev.window !== undefined && ev.window > 0) lines.push('fitness window: last ' + ev.window + ' entries');
  if (ev.varianceraw !== undefined && ev.varianceraw != null) lines.push('window delta variance: ' + ev.varianceraw.toFixed(6));
  if (ev.sloperaw !== undefined && ev.sloperaw != null) lines.push('window delta slope: ' + (ev.sloperaw >= 0 ? '+' : '') + ev.sloperaw.toFixed(4));
  if (ev.successRate !== undefined) lines.push('success rate: ' + Math.round(ev.successRate * 100) + '%');
  return lines.map(esc).join('\n');
}

function openWhyPanel(agentName, gate) {
  const a = agents.find(x => x.name === agentName);
  if (!a || !gate) return;
  const panel = document.getElementById('why-panel');
  const body = document.getElementById('why-panel-body');
  const title = document.getElementById('why-panel-title');
  title.textContent = a.name + ' \u2014 why unavailable';
  const fix = (WHY_FIX_HINT[gate.ruleType] || function() { return 'No specific remediation suggested.'; })(a, gate.evidence || {});
  let html = '';
  html += '<div class="why-panel-section"><h4>Rule</h4><div class="why-panel-rule">' + esc(gate.reason || '') + '</div></div>';
  const ev = renderWhyEvidence(gate.evidence);
  if (ev) html += '<div class="why-panel-section"><h4>Evidence</h4><pre class="why-panel-evidence" style="margin:0;white-space:pre-wrap">' + ev + '</pre></div>';
  html += '<div class="why-panel-section"><h4>How to enable</h4><div class="why-panel-action">' + esc(fix) + '</div></div>';
  body.innerHTML = html;
  panel.classList.add('visible');
}

function closeWhyPanel() {
  const panel = document.getElementById('why-panel');
  if (panel) panel.classList.remove('visible');
}

document.addEventListener('click', function(e) {
  const panel = document.getElementById('why-panel');
  if (!panel || !panel.classList.contains('visible')) return;
  if (panel.contains(e.target)) return;
  // Ignore clicks on elements that themselves open the panel (re-open scenario)
  if (e.target.closest('[data-why]')) return;
  closeWhyPanel();
});

// Stash gate objects keyed by agent+slot so onclick handlers can look them up
// (avoids embedding JSON.stringify in HTML attributes).
const WHY_REGISTRY = {};
function registerWhy(agentName, slot, gate) {
  WHY_REGISTRY[agentName + '|' + slot] = gate;
}
function showWhy(agentName, slot) {
  openWhyPanel(agentName, WHY_REGISTRY[agentName + '|' + slot]);
}

// --- Detail Modal ---
function openDetail(agentName) {
  const a = agents.find(x => x.name === agentName);
  if (!a) return;
  const modal = document.getElementById('detail-modal');
  const body = document.getElementById('modal-body');

  let html = '<div class="modal-header"><div>';
  html += '<h2>' + esc(a.name) + '<span class="colony-tag">' + esc(a.colony) + '</span></h2>';
  html += '</div><button class="modal-close" onclick="closeModal()">\u00D7</button></div>';

  // Description from .ag source
  if (a.description) {
    html += '<div class="modal-desc">' + esc(a.description) + '</div>';
  }

  // Meta info row
  html += '<div class="modal-meta">';
  html += '<div class="modal-meta-item"><span class="modal-meta-label">State</span><span class="modal-meta-value">' + esc(a.state) + '</span></div>';
  html += '<div class="modal-meta-item"><span class="modal-meta-label">Health</span><span class="modal-meta-value">' + esc(a.health) + '</span></div>';
  html += '<div class="modal-meta-item"><span class="modal-meta-label">Confidence</span><span class="modal-meta-value">' + (a.confidence != null ? a.confidence.toFixed(2) : '\u2014') + '</span></div>';
  // #145: confidence_generation + confidence_written_at
  if (a.confidence_generation != null) {
    html += '<div class="modal-meta-item"><span class="modal-meta-label">Generation</span><span class="modal-meta-value">' + esc(a.confidence_generation) + '</span></div>';
  }
  if (a.confidence_written_at) {
    html += '<div class="modal-meta-item"><span class="modal-meta-label">Written</span><span class="modal-meta-value">' + relTime(a.confidence_written_at) + '</span></div>';
  }
  html += '<div class="modal-meta-item"><span class="modal-meta-label">PID</span><span class="modal-meta-value">' + (a.pid || '\u2014') + (a.pid && !a.pid_alive ? ' \uD83D\uDC80' : '') + '</span></div>';
  if (a.agent_id) {
    html += '<div class="modal-meta-item"><span class="modal-meta-label">Agent ID</span><span class="modal-meta-value" style="font-size:10px">' + esc(a.agent_id) + '</span></div>';
  }
  html += '</div>';

  // Charts row (confidence history + learning rate)
  html += '<div class="modal-grid">';

  // Confidence history chart (from global history)
  html += '<div class="modal-section"><h3>Confidence History</h3>';
  // #143: filter stale zeros
  const confPts = history.filter(h => h.confidence && h.confidence[a.colony] != null && h.confidence[a.colony] > 0);
  if (confPts.length >= 2) {
    const W=360, H=80, PAD=30;
    const tMin=confPts[0].t, tMax=confPts[confPts.length-1].t, tR=Math.max(tMax-tMin,1);
    let svg = '<svg width="100%" viewBox="0 0 '+W+' '+H+'">';
    svg += '<line x1="'+PAD+'" y1="'+(H-5)+'" x2="'+W+'" y2="'+(H-5)+'" stroke="var(--border)" />';
    const sY=10+(H-15)*(1-0.6), aY=10+(H-15)*(1-0.85);
    svg += '<line x1="'+PAD+'" y1="'+sY+'" x2="'+W+'" y2="'+sY+'" stroke="rgba(255,255,0,0.2)" stroke-dasharray="3,3" />';
    svg += '<line x1="'+PAD+'" y1="'+aY+'" x2="'+W+'" y2="'+aY+'" stroke="rgba(0,255,0,0.2)" stroke-dasharray="3,3" />';
    const points = confPts.map(h => {
      const x = PAD+((h.t-tMin)/tR)*(W-PAD);
      const y = 10+(H-15)*(1-h.confidence[a.colony]);
      return x.toFixed(1)+','+y.toFixed(1);
    });
    svg += '<polyline points="'+points.join(' ')+'" fill="none" stroke="'+colonyColors[a.colony]+'" stroke-width="2" />';
    svg += '</svg>';
    html += svg;
  } else {
    html += '<span class="empty">Not enough data</span>';
  }
  html += '</div>';

  // Outcomes breakdown
  html += '<div class="modal-section"><h3>Outcomes</h3>';
  const succ = a.experience_outcomes.success;
  const fail = a.experience_outcomes.failure;
  const noop = a.experience_outcomes['no-op'];
  const outTotal = succ + fail + noop;
  if (outTotal > 0) {
    const sp = Math.max(succ/outTotal*100, 0.5);
    const fp = Math.max(fail/outTotal*100, 0.5);
    const np = 100 - sp - fp;
    html += '<div class="outcomes-bar">';
    if (succ > 0) html += '<div class="seg seg-success" style="width:'+sp+'%">' + succ + '</div>';
    if (fail > 0) html += '<div class="seg seg-failure" style="width:'+fp+'%">' + fail + '</div>';
    if (noop > 0) html += '<div class="seg seg-noop" style="width:'+Math.max(np,0.5)+'%">' + noop + '</div>';
    html += '</div>';
    html += '<div class="outcomes-legend">';
    html += '<span style="color:var(--green)">\u2713 ' + succ + ' success</span>';
    html += '<span style="color:var(--red)">\u2717 ' + fail + ' failure</span>';
    html += '<span style="color:var(--muted)">\u25CB ' + noop + ' no-op</span>';
    html += '</div>';
  } else {
    html += '<span class="empty">No experience entries</span>';
  }
  html += '</div>';
  html += '</div>'; // end modal-grid

  // Recent experience entries
  html += '<div class="modal-section"><h3>Recent Experience (last 10)</h3>';
  if (a.recent_experience && a.recent_experience.length > 0) {
    html += '<div class="exp-table"><table><tr><th>Time</th><th>Action</th><th>In</th><th>Outcome</th><th>Delta</th></tr>';
    a.recent_experience.slice().reverse().forEach(e => {
      const ts = e.ts ? relTime(e.ts) : '';
      const action = esc(String(e.action || '').slice(0, 30));
      const inp = esc(String(e.in || '').slice(0, 40));
      const outcome = e.outcome || '';
      const oc = outcome === 'success' ? 'var(--green)' : outcome === 'failure' ? 'var(--red)' : 'var(--muted)';
      const delta = e.delta != null ? (e.delta >= 0 ? '+' : '') + e.delta.toFixed(3) : '';
      html += '<tr><td class="muted">' + ts + '</td><td>' + action + '</td><td>' + inp + '</td>';
      html += '<td style="color:' + oc + '">' + esc(outcome) + '</td>';
      html += '<td>' + delta + '</td></tr>';
    });
    html += '</table></div>';
  } else {
    html += '<span class="empty">No experience entries</span>';
  }
  html += '</div>';

  // Recent logs
  html += '<div class="modal-section"><h3>Recent Logs (last 50)</h3>';
  if (a.recent_logs && a.recent_logs.length > 0) {
    html += '<div class="log-feed">';
    a.recent_logs.forEach(l => {
      html += '<div>' + esc(l) + '</div>';
    });
    html += '</div>';
  } else {
    html += '<span class="empty">No log lines available</span>';
  }
  html += '</div>';

  // Action buttons (uses global CONF_STEPS / nextStep)
  // #160: every button gets a tooltip via title=. promote/demote/evolve also
  // ask actionGate() whether the action would change behaviour. When it would
  // not, the button renders in the .is-disabled state and clicks open the
  // Why panel instead of triggering the no-op.
  html += '<div class="action-bar">';
  const curConf = a.confidence != null ? a.confidence : 0;
  const up = nextStep(curConf, 1);
  const down = nextStep(curConf, -1);
  const upGate = actionGate(a, 'promote', up);
  const downGate = actionGate(a, 'demote', down);
  const evolveGate = actionGate(a, 'evolve', null);
  registerWhy(a.name, 'promote', upGate);
  registerWhy(a.name, 'demote', downGate);
  registerWhy(a.name, 'evolve', evolveGate);

  const promoteLabel = '\u25B2 Promote' + (up != null ? ' to ' + up.toFixed(2) : '');
  if (upGate.enabled) {
    html += '<button class="action-btn promote" title="' + esc(upGate.reason) + '" onclick="setConfidence(\'' + esc(a.name) + '\',' + up + ')">' + promoteLabel + '</button>';
  } else {
    html += '<button class="action-btn promote is-disabled" data-why="promote" title="' + esc(upGate.reason) + ' (click for details)" onclick="showWhy(\'' + esc(a.name) + '\',\'promote\')">' + promoteLabel + '</button>';
  }

  const demoteLabel = '\u25BC Demote' + (down != null ? ' to ' + down.toFixed(2) : '');
  if (downGate.enabled) {
    html += '<button class="action-btn demote" title="' + esc(downGate.reason) + '" onclick="setConfidence(\'' + esc(a.name) + '\',' + down + ')">' + demoteLabel + '</button>';
  } else {
    html += '<button class="action-btn demote is-disabled" data-why="demote" title="' + esc(downGate.reason) + ' (click for details)" onclick="showWhy(\'' + esc(a.name) + '\',\'demote\')">' + demoteLabel + '</button>';
  }

  html += '<button class="action-btn restart" title="Stop the daemon and respawn it (preserves confidence + experience)." onclick="restartAgent(\'' + esc(a.name) + '\')">\u21BB Restart</button>';
  html += '<button class="action-btn quarantine-btn" title="Mark the agent as quarantined: it stops ticking until reset." onclick="quarantineAgent(\'' + esc(a.name) + '\')">\u2298 Quarantine</button>';

  if (evolveGate.enabled) {
    html += '<button class="action-btn evolve" title="' + esc(evolveGate.reason) + '" onclick="evolveAgent(\'' + esc(a.name) + '\')">\u2197 Evolve</button>';
  } else {
    html += '<button class="action-btn evolve is-disabled" data-why="evolve" title="' + esc(evolveGate.reason) + ' (click for details)" onclick="showWhy(\'' + esc(a.name) + '\',\'evolve\')">\u2197 Evolve</button>';
  }

  if (a.pid > 0 && !a.pid_alive && a.agent_id) {
    html += '<button class="action-btn" style="border-color:var(--red);color:var(--red)" title="Remove stale daemon record left by a crashed PID." onclick="cleanupDaemon(\'' + esc(a.agent_id) + '\')">Clean up stale PID</button>';
  }
  html += '</div>';

  body.innerHTML = html;
  modal.classList.add('visible');
}

function closeModal() {
  document.getElementById('detail-modal').classList.remove('visible');
}
document.getElementById('detail-modal').addEventListener('click', function(e) {
  if (e.target === this) closeModal();
});

// --- Confidence set with auto-restart (#137 Option 2) ---
const CONF_STEPS = [0.5, 0.6, 0.85];
function nextStep(cur, dir) {
  let idx = 0, best = Math.abs(cur - CONF_STEPS[0]);
  for (let i = 1; i < CONF_STEPS.length; i++) {
    const d = Math.abs(cur - CONF_STEPS[i]);
    if (d < best) { best = d; idx = i; }
  }
  const target = idx + dir;
  if (target < 0 || target >= CONF_STEPS.length) return null;
  return CONF_STEPS[target];
}

function setConfidence(agent, value) {
  if (value >= 0.85) {
    if (!confirm('Promote ' + agent + ' to ' + value.toFixed(2) + ' (AUTONOMOUS)?\n\nAt this level the agent will act directly on GitLab \u2014 posting comments, applying labels, opening MRs, approving reviews. Proceed?')) {
      return;
    }
  }
  const m = document.querySelector('meta[http-equiv="refresh"]');
  if (m) m.remove();

  const toast = createProgressToast(agent, value);
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
      if (r.ok) return r.json().then(d => ({ok: true, data: d}));
      return r.text().then(text => ({ok: false, text}));
    })
    .then(result => {
      clearFakes();
      if (!result.ok) { toast.renderHttpError(result.text); scheduleReload(30000); return; }
      toast.applyResult(result.data);
      const succeeded = result.data && result.data.restart && result.data.restart.succeeded;
      scheduleReload(succeeded ? 12000 : 30000);
    })
    .catch(e => { clearFakes(); toast.renderHttpError(String(e)); scheduleReload(30000); });
}

function scheduleReload(delayMs) {
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
    row.appendChild(icon); row.appendChild(text);
    stepsBox.appendChild(row);
    steps[key] = { row, icon, text, label };
  }
  addStep('memo', 'Memo written');
  addStep('stop', 'Stopping daemon\u2026');
  addStep('spawn', 'Respawning\u2026');
  addStep('verify', 'Verifying new daemon\u2026');
  el.appendChild(stepsBox);

  steps.memo.row.classList.add('active');
  steps.memo.icon.style.visibility = 'visible';

  const foot = document.createElement('div');
  foot.className = 'toast-foot';
  foot.textContent = 'Click to dismiss';
  el.appendChild(foot);

  el.addEventListener('click', () => el.remove());
  document.body.appendChild(el);
  let dismissTimer = null;
  function armDismiss(ms) {
    if (dismissTimer) clearTimeout(dismissTimer);
    dismissTimer = setTimeout(() => { if (el.parentNode) el.remove(); }, ms);
  }

  function setStep(key, state) {
    const s = steps[key]; if (!s) return;
    s.row.classList.remove('active', 'done', 'err');
    if (state === 'active') { s.row.classList.add('active'); s.icon.style.visibility = 'visible'; }
    else if (state === 'done') { s.row.classList.add('done'); s.icon.style.visibility = 'hidden'; s.text.textContent = '\u2713 ' + s.label.replace('\u2026', '').replace(/^[\u2713\u2717]\s*/, ''); }
    else if (state === 'err') { s.row.classList.add('err'); s.icon.style.visibility = 'hidden'; s.text.textContent = '\u2717 ' + s.label.replace('\u2026', '').replace(/^[\u2713\u2717]\s*/, ''); }
  }

  function renderHttpError(text) {
    foot.textContent = 'Click to dismiss';
    el.classList.add('toast-err');
    head.textContent = 'Request failed \u2014 ' + agent + ' not updated';
    while (stepsBox.firstChild) stepsBox.removeChild(stepsBox.firstChild);
    const line = document.createElement('div');
    line.textContent = 'Server error: ' + (text || 'unknown');
    stepsBox.appendChild(line);
    const retry = document.createElement('div');
    retry.style.marginTop = '6px'; retry.textContent = 'Retry via CLI:';
    stepsBox.appendChild(retry);
    const pre = document.createElement('pre');
    pre.textContent = 'agentis memo set ' + agent + ':confidence ' + requestedValue.toFixed(3) + '\nagentis daemon stop --all && ./start-federation.sh';
    stepsBox.appendChild(pre);
    armDismiss(30000);
  }

  function applyResult(d) {
    const serverValue = d && typeof d.value === 'string' ? parseFloat(d.value) : NaN;
    const v = Number.isFinite(serverValue) ? serverValue : requestedValue;
    const auditOk = !d || d.audit_logged !== false;
    const restart = (d && d.restart) || {};
    if (restart.succeeded) {
      el.classList.add('toast-ok');
      head.textContent = 'Loaded ' + v.toFixed(2) + ' \u2713 ' + agent;
      setStep('memo', 'done'); setStep('stop', 'done'); setStep('spawn', 'done'); setStep('verify', 'done');
      const detail = document.createElement('div'); detail.className = 'toast-foot';
      const oldPid = restart.old_pid || 0, newPid = restart.new_pid || 0;
      const started = restart.new_started_at ? new Date(restart.new_started_at * 1000).toLocaleTimeString() : '?';
      detail.textContent = 'old pid ' + (oldPid || 'n/a') + ' \u2192 new pid ' + newPid + ' (started ' + started + ')' + (auditOk ? '' : ' \u2014 audit log write failed');
      stepsBox.appendChild(detail);
      foot.textContent = 'Auto-dismiss in 12s \u2014 click to dismiss now';
      armDismiss(12000); return;
    }
    el.classList.add('toast-err');
    head.textContent = 'Auto-restart failed \u2014 manual step required';
    setStep('memo', 'done');
    const evts = Array.isArray(restart.events) ? restart.events : [];
    const stepMap = {stop:'stop',sigterm:'stop',sigkill:'stop',wait_exit:'stop',cleanup:'stop',spawn:'spawn',verify:'verify'};
    const seen = {stop:null,spawn:null,verify:null};
    evts.forEach(e => { const b = stepMap[e.step]; if (!b) return; if (e.status==='error') seen[b]='err'; else if (e.status==='ok'&&seen[b]!=='err') seen[b]='done'; });
    Object.keys(seen).forEach(k => { if (seen[k]) setStep(k, seen[k]); });
    const reason = document.createElement('div');
    reason.textContent = 'Memo written to ' + agent + ':confidence = ' + v.toFixed(3) + ' on disk. Restart step failed: ' + (restart.error || 'unknown');
    stepsBox.appendChild(reason);
    if (restart.manual_command) {
      const label = document.createElement('div'); label.style.marginTop = '6px'; label.textContent = 'Respawn this agent:';
      stepsBox.appendChild(label);
      const pre = document.createElement('pre'); pre.textContent = restart.manual_command; stepsBox.appendChild(pre);
    }
    const fbLabel = document.createElement('div'); fbLabel.style.marginTop = '6px'; fbLabel.textContent = 'Or restart the whole federation:';
    stepsBox.appendChild(fbLabel);
    const fb = document.createElement('pre'); fb.textContent = 'agentis daemon stop --all && ./start-federation.sh'; stepsBox.appendChild(fb);
    if (!auditOk) { const aw = document.createElement('div'); aw.className='toast-foot'; aw.textContent='Audit log write failed.'; stepsBox.appendChild(aw); }
    foot.textContent = 'Click to dismiss'; armDismiss(30000);
  }

  return { el, setStep, renderHttpError, applyResult };
}

// --- Action handlers ---
function restartAgent(agent) {
  if (!confirm('Restart daemon for ' + agent + '?')) return;
  const m = document.querySelector('meta[http-equiv="refresh"]');
  if (m) m.remove();
  showSimpleToast('Restarting ' + agent + '\u2026', 'var(--yellow)');
  fetch('/restart', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: 'agent=' + encodeURIComponent(agent),
  })
    .then(r => r.ok ? r.json() : r.text().then(t => { throw new Error(t); }))
    .then(d => {
      if (d.succeeded) showSimpleToast('Restarted ' + agent + ' \u2713 pid=' + (d.new_pid||'?'), 'var(--green)');
      else showSimpleToast('Restart failed: ' + (d.error||'unknown'), 'var(--red)');
      scheduleReload(5000);
    })
    .catch(e => { showSimpleToast('Error: ' + e.message, 'var(--red)'); scheduleReload(10000); });
}

function quarantineAgent(agent) {
  if (!confirm('Quarantine ' + agent + '? This will stop the agent from acting.')) return;
  fetch('/quarantine', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: 'agent=' + encodeURIComponent(agent),
  })
    .then(r => r.ok ? r.json() : r.text().then(t => { throw new Error(t); }))
    .then(d => { showSimpleToast(d.message || 'Quarantine sent', 'var(--magenta)'); scheduleReload(5000); })
    .catch(e => { showSimpleToast('Error: ' + e.message, 'var(--red)'); });
}

function evolveAgent(agent) {
  if (!confirm('Trigger evolution for ' + agent + '?')) return;
  fetch('/evolve', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: 'agent=' + encodeURIComponent(agent),
  })
    .then(r => r.ok ? r.json() : r.text().then(t => { throw new Error(t); }))
    .then(d => { showSimpleToast(d.message || 'Evolve triggered', 'var(--cyan)'); scheduleReload(5000); })
    .catch(e => { showSimpleToast('Error: ' + e.message, 'var(--red)'); });
}

function cleanupDaemon(agentId) {
  if (!confirm('Clean up stale daemon entry for ' + agentId + '?')) return;
  fetch('/cleanup', {
    method: 'POST',
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: 'agent_id=' + encodeURIComponent(agentId),
  })
    .then(r => r.ok ? r.json() : r.text().then(t => { throw new Error(t); }))
    .then(d => { showSimpleToast('Cleaned up: ' + (d.removed||[]).join(', '), 'var(--green)'); scheduleReload(3000); })
    .catch(e => { showSimpleToast('Error: ' + e.message, 'var(--red)'); });
}

function startFederation() {
  if (!confirm('Start the federation? This will launch all colony daemons.')) return;
  showSimpleToast('Starting federation\u2026', 'var(--yellow)');
  fetch('/start', { method: 'POST' })
    .then(r => r.ok ? r.text() : r.text().then(t => { throw new Error(t); }))
    .then(t => { showSimpleToast(t || 'Federation started', 'var(--green)'); scheduleReload(8000); })
    .catch(e => { showSimpleToast('Error: ' + e.message, 'var(--red)'); });
}

function showSimpleToast(msg, color, kind) {
  // Only dismiss prior *success* toasts so a transient "ok" message can
  // make room for the next one. Errors live in #notification-region now
  // (see showError) and progress toasts manage their own lifecycle, so
  // we must not nuke them here.
  document.querySelectorAll('.toast').forEach(t => {
    if (t.dataset && t.dataset.kind === 'success') t.remove();
  });
  const el = document.createElement('div');
  el.className = 'toast';
  if (kind) { el.dataset.kind = kind; }
  el.style.borderColor = color;
  el.style.boxShadow = '0 0 20px ' + color + '50';
  el.innerHTML = '<div class="toast-head" style="color:' + color + '">' + esc(msg) + '</div><div class="toast-foot">Click to dismiss</div>';
  el.addEventListener('click', () => el.remove());
  document.body.appendChild(el);
  setTimeout(() => { if (el.parentNode) el.remove(); }, 15000);
}

// Render a persistent error notice into #notification-region. The button
// label is NEVER touched — issue #161 antipattern. `detail` is rendered
// inside a collapsible <details> block as preformatted text (raw JSON or
// stderr_tail) with a copy + dismiss affordance.
function showError(summary, detail, onDismiss) {
  const region = document.getElementById('notification-region');
  if (!region) { return; }
  const el = document.createElement('div');
  el.className = 'notice notice-err';
  const head = document.createElement('div');
  head.className = 'notice-summary';
  head.textContent = String(summary || 'Error');
  el.appendChild(head);
  const detailText = (detail == null) ? '' : (typeof detail === 'string' ? detail : JSON.stringify(detail, null, 2));
  if (detailText) {
    const det = document.createElement('details');
    const sum = document.createElement('summary');
    sum.textContent = 'Show details';
    det.appendChild(sum);
    const pre = document.createElement('pre');
    pre.className = 'notice-json';
    pre.textContent = detailText;
    det.appendChild(pre);
    el.appendChild(det);
  }
  const actions = document.createElement('div');
  actions.className = 'notice-actions';
  if (detailText) {
    const copyBtn = document.createElement('button');
    copyBtn.className = 'notice-copy';
    copyBtn.type = 'button';
    copyBtn.textContent = 'Copy';
    copyBtn.addEventListener('click', () => {
      try {
        if (navigator.clipboard && navigator.clipboard.writeText) {
          navigator.clipboard.writeText(detailText);
          copyBtn.textContent = 'Copied';
          setTimeout(() => { copyBtn.textContent = 'Copy'; }, 1500);
        }
      } catch (_) { /* clipboard may be unavailable; silent */ }
    });
    actions.appendChild(copyBtn);
  }
  const dismiss = document.createElement('button');
  dismiss.className = 'notice-dismiss';
  dismiss.type = 'button';
  dismiss.textContent = 'Dismiss';
  dismiss.addEventListener('click', () => {
    el.remove();
    if (typeof onDismiss === 'function') { try { onDismiss(); } catch (_) { /* swallow */ } }
  });
  actions.appendChild(dismiss);
  el.appendChild(actions);
  region.appendChild(el);
  return el;
}

// --- Kill switch ---
// State machine. The button label is a pure function of `state`; it is
// NEVER derived from server response text (issue #161). Errors land in
// the persistent #notification-region via showError().
//   idle       -> "Kill Federation",     enabled
//   armed      -> "Confirm Kill",        enabled (5s auto-revert)
//   pending    -> "Killing\u2026",        disabled
//   succeeded  -> "Federation Stopped",  disabled (terminal)
//   failed     -> resets to idle so operator can retry
let killArmed = false;
let killArmTimer = null;
function setKillState(state) {
  const btn = document.getElementById('kill-btn');
  if (!btn) { return; }
  if (killArmTimer) { clearTimeout(killArmTimer); killArmTimer = null; }
  switch (state) {
    case 'idle':
      killArmed = false;
      btn.textContent = 'Kill Federation';
      btn.className = 'kill-btn';
      btn.disabled = false;
      break;
    case 'armed':
      killArmed = true;
      btn.textContent = 'Confirm Kill';
      btn.className = 'kill-btn confirm';
      btn.disabled = false;
      killArmTimer = setTimeout(() => {
        if (killArmed) { setKillState('idle'); }
      }, 5000);
      break;
    case 'pending':
      killArmed = false;
      btn.textContent = 'Killing\u2026';
      btn.className = 'kill-btn killed';
      btn.disabled = true;
      break;
    case 'succeeded': {
      killArmed = false;
      btn.textContent = 'Federation Stopped';
      btn.className = 'kill-btn killed';
      btn.disabled = true;
      // Stop the meta auto-refresh — federation is gone, polling is moot.
      const m = document.querySelector('meta[http-equiv="refresh"]');
      if (m) { m.remove(); }
      break;
    }
    case 'failed': {
      // Operator can retry; error rendering is the caller's job (showError).
      // Pause meta auto-refresh until the operator dismisses the error so the
      // failure notice in #notification-region is not wiped after 60s.
      const m = document.querySelector('meta[http-equiv="refresh"]');
      if (m) { m.remove(); }
      setKillState('idle');
      break;
    }
    default:
      setKillState('idle');
  }
}

function killSwitch() {
  if (!killArmed) { setKillState('armed'); return; }
  setKillState('pending');
  const noBackup = !!(document.getElementById('kill-no-backup') || {}).checked;
  fetch('/kill', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ no_backup: noBackup }),
  })
    .then(r => r.text().then(text => {
      let parsed = null;
      try { parsed = JSON.parse(text); } catch (_) { parsed = null; }
      return { status: r.status, text: text, parsed: parsed };
    }))
    .then(({ status, text, parsed }) => {
      if (!parsed) {
        setKillState('failed');
        showError('Kill failed (HTTP ' + status + ', non-JSON response)', text || '(empty body)', () => location.reload());
        return;
      }
      if (parsed.ok) {
        setKillState('succeeded');
        return;
      }
      setKillState('failed');
      const summary = parsed.summary || ('Kill failed (exit ' + (parsed.exit != null ? parsed.exit : '?') + ')');
      const detail = {
        exit: parsed.exit,
        json: parsed.json || null,
        stderr_tail: parsed.stderr_tail || '',
      };
      showError(summary, detail, () => location.reload());
    })
    .catch(e => {
      setKillState('failed');
      showError('Kill request failed (network error)', String((e && e.message) || e), () => location.reload());
    });
}
</script>
</body>
</html>
JSEOF
    } > "$HTML_TMP"
    mv "$HTML_TMP" "$HTML_FILE"
}

# --- Regen-only mode ---
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

# Serve with all endpoints. SCRIPT_PATH and FED_DIR are passed through so
# POST /refresh can re-exec this script in regen-only mode. ALL_AGENTS_CSV
# is the allowlist for POST /confidence — operator-supplied agent names must
# match exactly or the endpoint rejects with 400.
ALL_AGENTS_CSV="$(IFS=,; echo "${ALL_AGENTS[*]}")"
python3 - "$DASH_DIR" "$PORT" "$SCRIPT_PATH" "$FED_DIR" "$ALL_AGENTS_CSV" "$AGENT_COLONY_MAP" <<'PYSERVER'
import sys, os, subprocess, json, time, signal, shutil, shlex, threading, re, urllib.parse
from http.server import HTTPServer, SimpleHTTPRequestHandler

serve_dir, port = sys.argv[1], int(sys.argv[2])
script_path, fed_dir_arg = sys.argv[3], sys.argv[4]
allowed_agents = set(a for a in sys.argv[5].split(',') if a)
try:
    _map = json.loads(sys.argv[6])
except (json.JSONDecodeError, ValueError, IndexError):
    _map = []
agent_to_colony = {e.get('agent',''): e.get('colony','') for e in _map if e.get('agent')}
os.chdir(serve_dir)
fed_dir = os.path.dirname(serve_dir)
confidence_log = os.path.join(serve_dir, 'confidence-log.jsonl')
# Path to the tick-interval resolver (#155). script_path is the absolute
# path to this federation-dashboard.sh; the resolver lives next to it.
_tools_dir = os.path.dirname(os.path.realpath(script_path))
_resolver_script = os.path.join(_tools_dir, 'resolve-tick-interval.py')

# Path to kill-federation.sh (#161). Resolved once at server start so the
# /kill endpoint never has to re-discover it. Fail fast with a clear error
# if the sibling script is missing — there is no graceful fallback.
kill_script = os.path.join(_tools_dir, 'kill-federation.sh')
assert os.path.isfile(kill_script), (
    f'kill-federation.sh not found next to dashboard script: {kill_script}. '
    'The dashboard /kill endpoint requires it. See #161 / #162.'
)


def resolve_tick_interval(agent, colony_dir):
    """Return tick interval (str, ms) for *agent* using resolve-tick-interval.py.

    Falls back to '60000' if the resolver is missing or fails.
    """
    try:
        r = subprocess.run(
            [sys.executable, _resolver_script, agent, colony_dir],
            capture_output=True, text=True, timeout=5,
        )
        val = r.stdout.strip()
        return val if r.returncode == 0 and val.isdigit() else '60000'
    except (OSError, subprocess.SubprocessError):
        return '60000'


def parse_toml_section(toml_path, section):
    """Extract key=value pairs under [section] from a colony TOML file."""
    out = {}
    try:
        with open(toml_path, 'r', encoding='utf-8') as f:
            in_section = False
            for raw in f:
                line = raw.rstrip('\n')
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
    """Return the running daemon record whose source basename matches
    <agent>.ag, or None."""
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
    """Remove stale per-daemon files under $FED_DIR/.agentis/daemon/."""
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
    """Single-line respawn command the operator can paste if auto-restart fails."""
    agent_name = os.path.basename(agent_file)
    if agent_name.endswith('.ag'):
        agent_name = agent_name[:-3]
    tick = resolve_tick_interval(agent_name, colony_dir)
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
        f' --enable-exec --enable-messaging --tick-interval {tick} &'
    )


def restart_daemon(agent):
    """Stop+cleanup+respawn sequence for one agent (#137 Option 2)."""
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

    config_path = os.path.join(colony_dir, 'config', 'colony.toml')
    gitlab = parse_toml_section(config_path, 'gitlab')
    gl_url = gitlab.get('url', '')
    gl_token = gitlab.get('token', '')
    gl_project_raw = gitlab.get('project', '')
    if not gl_url or not gl_token or not gl_project_raw:
        rec('config', 'error',
            message=f'incomplete [gitlab] in {config_path}: '
                    f'url={bool(gl_url)} token={bool(gl_token)} project={bool(gl_project_raw)}')
        return {
            'attempted': False, 'succeeded': False,
            'error': f'incomplete [gitlab] section in {config_path}',
            'events': events,
        }
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

    old = find_agent_daemon(agent)
    old_agent_id = (old or {}).get('agent_id') or ''
    old_pid = (old or {}).get('pid') or 0
    old_started_at = (old or {}).get('started_at') or 0
    rec('resolve', 'ok', agent_id=old_agent_id, pid=old_pid,
        running=(old is not None and old.get('state') == 'running'))

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

    if old_agent_id:
        removed = cleanup_sidecars(old_agent_id)
        rec('cleanup', 'ok', removed=removed)

    # Respawn detached so the dashboard process can die without taking
    # the fresh daemon with it.
    tick = resolve_tick_interval(agent, colony_dir)
    rec('spawn', 'start', tick_interval=tick)
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
                '--tick-interval', tick,
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
        threading.Thread(target=proc.wait, daemon=True).start()
        rec('verify', 'error',
            message=f'new daemon not registered within 15s (launcher exit={code})')
        return {
            'attempted': True, 'succeeded': False,
            'error': 'new daemon not registered within 15s',
            'manual_command': manual_cmd,
            'events': events,
        }

    threading.Thread(target=proc.wait, daemon=True).start()

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
            env = dict(os.environ)
            env['DASHBOARD_REGEN_ONLY'] = '1'
            try:
                result = subprocess.run(
                    ['bash', script_path, fed_dir_arg],
                    capture_output=True, text=True,
                    env=env, timeout=30,
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
            try:
                result = subprocess.run(
                    ['agentis', 'memo', 'set', f'{agent}:confidence', f'{value:.3f}'],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=10,
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
                pass
            restart = restart_daemon(agent)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'value': f'{value:.3f}',
                'memo_written': True,
                'audit_logged': audit_ok,
                'restart_required': not restart.get('succeeded', False),
                'restart': restart,
            }).encode())
            return

        if self.path == '/restart':
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
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            result = restart_daemon(agent)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result).encode())
            return

        if self.path == '/quarantine':
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
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            daemon = find_agent_daemon(agent)
            if not daemon:
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'no daemon found for {agent}'.encode())
                return
            agent_id = daemon.get('agent_id', '')
            try:
                result = subprocess.run(
                    ['agentis', 'daemon', 'quarantine', agent_id],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=10,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'agent_id': agent_id,
                'message': (result.stdout or result.stderr or 'quarantine signal sent').strip(),
            }).encode())
            return

        if self.path == '/evolve':
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
            if agent not in allowed_agents:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'unknown agent: {agent!r}'.encode())
                return
            colony = agent_to_colony.get(agent, '')
            agent_file = os.path.join(fed_dir, colony, 'agents', f'{agent}.ag') if colony else ''
            if not agent_file or not os.path.isfile(agent_file):
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'agent file not found: {agent}'.encode())
                return
            try:
                result = subprocess.run(
                    ['agentis', 'evolve', agent_file],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=30,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent': agent,
                'message': (result.stdout or result.stderr or 'evolve triggered').strip(),
            }).encode())
            return

        if self.path == '/cleanup':
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
            agent_id = (params.get('agent_id') or [''])[0]
            if not agent_id or len(agent_id) > 128:
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'invalid agent_id')
                return
            # Validate agent_id is hex-like (prevent path traversal)
            if not all(c in '0123456789abcdefABCDEF-_' for c in agent_id):
                self.send_response(400)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'agent_id must be hex')
                return
            removed = cleanup_sidecars(agent_id)
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'agent_id': agent_id,
                'removed': removed,
            }).encode())
            return

        if self.path == '/start':
            # Start federation: look for start-federation.sh in fed_dir
            start_script = os.path.join(fed_dir, 'start-federation.sh')
            if not os.path.isfile(start_script):
                self.send_response(404)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(b'start-federation.sh not found')
                return
            try:
                result = subprocess.run(
                    ['bash', start_script],
                    capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                self.wfile.write(f'exec failed: {e}'.encode())
                return
            out = (result.stdout or '').strip()
            err = (result.stderr or '').strip()
            if result.returncode != 0:
                self.send_response(500)
                self.send_header('Content-Type', 'text/plain')
                self.end_headers()
                msg = (err or out or 'start-federation.sh failed').strip()
                self.wfile.write(msg.encode() or b'start-federation.sh failed')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write((out + ('\n' + err if err else '') or 'Federation started').encode())
            return

        if self.path == '/kill':
            # Issue #161: shell out to tools/kill-federation.sh (shipped in
            # #162) instead of the spuriously-failing `agentis daemon stop
            # --all`. Always reply with structured JSON so the dashboard
            # button label never has to be derived from server text.
            length = int(self.headers.get('Content-Length', '0') or '0')
            no_backup = False
            if 0 < length <= 4096:
                try:
                    raw = self.rfile.read(length).decode('utf-8', errors='replace')
                    body = json.loads(raw) if raw.strip() else {}
                    no_backup = bool(body.get('no_backup', False))
                except (ValueError, UnicodeDecodeError, json.JSONDecodeError):
                    no_backup = False
            cmd = [kill_script, '--json', '--fed-dir', fed_dir]
            if no_backup:
                cmd.append('--no-backup')
            try:
                result = subprocess.run(
                    cmd, capture_output=True, text=True,
                    cwd=fed_dir, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as e:
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(json.dumps({
                    'ok': False,
                    'exit': -1,
                    'summary': f'kill-federation.sh exec failed: {e}',
                    'json': None,
                    'stderr_tail': '',
                }).encode())
                return
            stdout = result.stdout or ''
            stderr = result.stderr or ''
            # kill-federation.sh emits a single trailing JSON line on stdout.
            parsed_json = None
            for line in reversed(stdout.splitlines()):
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed_json = json.loads(line)
                    break
                except (ValueError, json.JSONDecodeError):
                    continue
            exit_code = result.returncode
            if exit_code == 0:
                summary = 'Federation stopped cleanly'
            elif exit_code == 1:
                remaining = (parsed_json or {}).get('registry_remaining', '?') if parsed_json else '?'
                summary = f'Federation not fully clean (exit 1, registry_remaining={remaining})'
            elif exit_code == 2:
                summary = 'kill-federation.sh: bad invocation (exit 2)'
            else:
                summary = f'kill-federation.sh failed (exit {exit_code})'
            stderr_tail = stderr[-2048:] if len(stderr) > 2048 else stderr
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({
                'ok': exit_code == 0,
                'exit': exit_code,
                'summary': summary,
                'json': parsed_json,
                'stderr_tail': stderr_tail,
            }).encode())
            return

        self.send_error(404)

    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
PYSERVER
