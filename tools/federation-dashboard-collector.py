#!/usr/bin/env python3
# federation-dashboard-collector.py: collects per-agent enriched data
# (experience stats, .ag descriptions, log lines, PID liveness, event
# timeline, confidence change history) and prints a single JSON blob to
# stdout for federation-dashboard.sh to embed in the served HTML.
#
# Extracted from federation-dashboard.sh in #170 to fix a macOS bash
# heredoc-in-$() parser bug. DO NOT inline this back into the shell
# script — bash 3.2 (macOS default) does not fully honor single-quoted
# heredoc delimiters when the heredoc is nested inside $(), causing
# backticks in Python comments to be evaluated as command substitutions
# and re-parsing the heredoc body as bash code at runtime.
#
# Args (positional):
#   1: daemons_json        — JSON array from `agentis daemon list --json`
#   2: agent_map_json      — JSON array of {agent, colony} pairs
#   3: fed_dir             — federation root directory
#   4: epoch               — current epoch seconds
#   5: exp_dir             — .agentis/experience/ path
#   6: log_dir             — .agentis/logs/ path
#   7: dash_dir            — federation-dashboard cache dir
#   8: colony_list_json    — JSON array of colony names
#   9..: all_agents        — agent names (one per positional arg)

import sys, os, json, time, re, datetime, subprocess

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

# Build role -> daemon mapping from daemon list source field
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
        'agent_last_ok_ts': 0,
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

        # #160 + #176: extract confidence gates. After M4 (#176) agents branch on
        # tier("<name>") == "<tier>" instead of raw confidence literals. Map
        # each tier-branch back to its numeric lower bound so downstream tooling
        # (dashboard promote/demote buttons, auto-promote.sh) keeps working.
        # Fall back to the pre-M4 `if confidence >= X` form if the agent has
        # not been migrated yet. clamp_auto cap idiom is unchanged.
        TIER_LEVELS = {
            'dormant': 0.0,
            'shadow': 0.4,
            'propose': 0.6,
            'review-gated': 0.8,
            'autonomous': 0.95,
        }
        gates = []
        for lineno, line in enumerate(ag_lines, 1):
            m_tier = re.search(r'my_tier\s*==\s*"(dormant|shadow|propose|review-gated|autonomous)"', line)
            if m_tier:
                gates.append({'level': TIER_LEVELS[m_tier.group(1)], 'line': lineno, 'tier': m_tier.group(1)})
                continue
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
# #167: per-role epoch-ms of the most recent log line that classified as
# anything other than `error`. Drives the dashboard's "stale errors"
# auto-hide (errors from agents whose last_ok_ts > 1h ago are filtered
# out of the timeline so they don't drown out actively failing agents).
last_ok_ts_by_role = {}
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
                # #167: widen from 30 to 100 lines so `last_ok_ts_by_role`
                # has enough history to detect "agent has ticked cleanly
                # in the last hour" — at 60s tick interval that's ~100
                # ticks of headroom, comfortably beyond the 1h window.
                for line in lines[-100:]:
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
                    # false positives like "react"->action, "referred"->error)
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
                    # #167: track the most recent non-error timestamp per
                    # role. Includes `log` (plain tick lines) — a clean
                    # tick is exactly what "ticking cleanly" means.
                    if etype != 'error' and ts > 0:
                        prev = last_ok_ts_by_role.get(role, 0)
                        if ts > prev:
                            last_ok_ts_by_role[role] = ts
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

# #167: stamp `agent_last_ok_ts` on each agent record from the per-role
# tracking above. Defaults to 0 when no parseable non-error line was
# seen — the client-side "stale errors" filter treats 0 as "unknown,
# do not auto-hide" so silent agents stay visible.
for rec in result:
    name = rec['name']
    # Lookup mirrors the role-resolution fallback above: when no daemon
    # is registered (orphan log) the role becomes aid[:8], so we try the
    # truncated form too.
    rec['agent_last_ok_ts'] = (
        last_ok_ts_by_role.get(name) or
        last_ok_ts_by_role.get(name[:8], 0)
    )

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

# --- Promote decisions (#248) ---
# Invoke auto-promote-decisions.py in --preview mode so the dashboard's
# Promote Candidates list uses the same math the scheduler uses (acting
# vs observe classification per #186, per-step bootstrap override, runtime
# hours gate). Previously the template computed its own fitness from
# success/total across all rows, which silently diverged from the
# scheduler; operators saw "N skipped" for reasons the sidecar did not
# enforce. See issue #248.
decisions = []
script_dir = os.path.dirname(os.path.abspath(__file__))
decider = os.path.join(script_dir, 'auto-promote-decisions.py')
config = os.path.join(script_dir, 'auto-promote-config.yaml')
if os.path.isfile(decider) and os.path.isfile(config):
    try:
        dec_out = subprocess.run(
            ['python3', decider, '--preview', '--config', config,
             daemons_json, fed_dir],
            capture_output=True, text=True, timeout=15,
        )
        if dec_out.returncode == 0:
            try:
                decisions = json.loads(dec_out.stdout or '[]')
            except json.JSONDecodeError:
                decisions = []
    except (subprocess.SubprocessError, OSError):
        decisions = []

# --- Sidecar liveness (#248 PR B) ---
# Surface auto-promote scheduler state so the dashboard can render a
# HEALTHY / DEGRADED banner. Source of truth:
#   .auto-promote-install.toml  — whether the sidecar was ever installed
#                                 (install.sh §7) and the configured cadence
#   .agentis/logs/auto-promote.log — mtime is the last tick (sidecar appends
#                                 '=== {iso}: sidecar tick ===' + auto-promote.sh
#                                 stdout every interval_s; see
#                                 start-federation.sh §auto-promote scheduler).
# When no install file exists we emit installed=false and the banner falls
# back to daemon-liveness only. No sidecar running is not itself DEGRADED.
sidecar = {'installed': False, 'enabled': False, 'interval_s': None,
           'last_tick_ts': None, 'log_path': None}
install_file = os.path.join(fed_dir, '.auto-promote-install.toml')
if os.path.isfile(install_file):
    sidecar['installed'] = True
    try:
        in_section = False
        with open(install_file) as f:
            for raw in f:
                line = raw.strip()
                if not line or line.startswith('#'):
                    continue
                if line.startswith('[') and line.endswith(']'):
                    in_section = (line[1:-1].strip() == 'auto_promote')
                    continue
                if not in_section or '=' not in line:
                    continue
                k, _, v = line.partition('=')
                k = k.strip()
                v = v.strip().strip('"').strip("'")
                if k == 'enabled':
                    sidecar['enabled'] = (v.lower() == 'true')
                elif k == 'interval_s':
                    try:
                        sidecar['interval_s'] = int(v)
                    except ValueError:
                        pass
    except OSError:
        pass
log_file = os.path.join(fed_dir, '.agentis', 'logs', 'auto-promote.log')
if os.path.isfile(log_file):
    sidecar['log_path'] = log_file
    try:
        sidecar['last_tick_ts'] = int(os.path.getmtime(log_file))
    except OSError:
        pass

output = {
    'agents': result,
    'experience_counts': colony_exp,
    'events': events,
    'confidence_changes': conf_changes,
    'decisions': decisions,
    'sidecar': sidecar,
}
print(json.dumps(output))
