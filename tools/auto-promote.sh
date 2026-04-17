#!/bin/bash
# auto-promote.sh — Layer 1 auto-promote / auto-evolve cron script
#
# Reads experience + memo + daemon state, evaluates per-agent fitness
# rules from auto-promote-config.yaml, and promotes or evolves agents
# whose metrics meet the thresholds.
#
# Intended to be invoked by cron (e.g. */30 * * * *). Safe to run when
# the federation is stopped — exits 0 with a no-op log line.
#
# All actions default to --dry-run (config: dry_run: true). Flip to
# false in auto-promote-config.yaml only after reviewing the journal.
#
# Promote ladder (four-tier, ADR-0001 / #177): the steps list in
# auto-promote-config.yaml drives progression shadow(0.4) -> propose(0.6)
# -> review-gated(0.8) -> autonomous(0.95). This script is fully
# YAML-driven — no numeric thresholds are hardcoded here.
#
# Usage: ./tools/auto-promote.sh <federation-dir>
#        ./tools/auto-promote.sh dev-apprenticeship
#        ./tools/auto-promote.sh dev-apprenticeship --live   # override dry_run
#
# Prerequisites: agentis, python3 (with PyYAML or a fallback parser)
#
# Layer 1 of the auto-governance roadmap (#148). See README for layers 2+3.

set -euo pipefail

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <federation-dir> [--live]"
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

LIVE_OVERRIDE=false
if [ "${2:-}" = "--live" ]; then
    LIVE_OVERRIDE=true
fi

CONFIG_FILE="$SCRIPT_DIR/auto-promote-config.yaml"
JOURNAL_FILE="$SCRIPT_DIR/auto-promote-journal.jsonl"
LOCK_FILE="$SCRIPT_DIR/.auto-promote.lock"

# --- Safety guard 2: Lock file (flock, atomic) ---

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "Another auto-promote instance is running. Exiting."
    exit 0
fi
# fd 200 is held until the process exits — no cleanup trap needed.

# --- Logging + journal helpers ---

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] auto-promote: $*"
}

# Append a structured JSON line to the journal.
# Args: agent, decision, evidence_json [, from, to]
# Matches the spec format from #148: top-level from/to + evidence object.
journal_append() {
    local agent="$1" decision="$2" evidence_json="$3"
    local step_from="${4:-}" step_to="${5:-}"
    python3 -c "
import json, sys, time
entry = {
    'ts': int(time.time()),
    'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'agent': sys.argv[1],
    'decision': sys.argv[2],
    'dry_run': sys.argv[3] == 'true',
    'evidence': json.loads(sys.argv[4]),
}
if sys.argv[5]:
    try: entry['from'] = float(sys.argv[5])
    except ValueError: pass
if sys.argv[6]:
    try: entry['to'] = float(sys.argv[6])
    except ValueError: pass
print(json.dumps(entry))
" "$agent" "$decision" "$DRY_RUN" "$evidence_json" "$step_from" "$step_to" >> "$JOURNAL_FILE"
}

# --- Parse config ---

if [ ! -f "$CONFIG_FILE" ]; then
    log "Config not found: $CONFIG_FILE"
    exit 1
fi

# Parse YAML config into shell variables via python3. We try PyYAML first,
# fall back to a minimal regex parser for the flat structure we need.
eval "$(python3 - "$CONFIG_FILE" <<'PYCONFIG'
import sys, json

config_path = sys.argv[1]

def _strip_inline_comment(s):
    """Strip YAML inline comments (# ...) respecting quoted strings."""
    quote = None
    for i, ch in enumerate(s):
        if quote:
            if ch == '\\' and i + 1 < len(s):
                continue  # skip escaped char
            if ch == quote:
                quote = None
            continue
        if ch in ('"', "'"):
            quote = ch
            continue
        if ch == '#':
            return s[:i].rstrip()
    return s

def _parse_value(v):
    v = _strip_inline_comment(v)
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
        return v[1:-1]
    if v == 'true':
        return True
    if v == 'false':
        return False
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v

def parse_yaml_simple(path):
    """Minimal YAML parser for our flat config structure.
    Handles scalar values and simple lists (- from/to pairs)."""
    cfg = {}
    with open(path) as f:
        lines = f.readlines()

    indent_stack = [(-1, cfg)]
    # Track the last dict appended to a list so continuation keys
    # (e.g. "to: 0.6" indented under "- from: 0.4") can be added.
    last_list_dict = None

    for idx, raw in enumerate(lines):
        line = raw.rstrip('\n')
        stripped = line.lstrip()

        if not stripped or stripped.startswith('#'):
            continue

        indent = len(line) - len(stripped)

        # Pop indent stack to current level
        while len(indent_stack) > 1 and indent_stack[-1][0] >= indent:
            indent_stack.pop()

        parent = indent_stack[-1][1]

        # List item
        if stripped.startswith('- '):
            item_content = stripped[2:].strip()
            if ':' in item_content:
                k, _, v = item_content.partition(':')
                k = k.strip()
                v = v.strip()
                if not isinstance(parent, list):
                    continue
                new_dict = {k: _parse_value(v)}
                parent.append(new_dict)
                last_list_dict = new_dict
            else:
                if isinstance(parent, list):
                    parent.append(_parse_value(item_content))
                    last_list_dict = None
            continue

        if ':' not in stripped:
            continue

        k, _, v = stripped.partition(':')
        k = k.strip()
        v = v.strip()

        if not v:
            # Section header
            is_list = False
            for upcoming in lines[idx+1:]:
                us = upcoming.lstrip()
                if not us or us.startswith('#'):
                    continue
                if us.startswith('- '):
                    is_list = True
                break

            child = [] if is_list else {}
            if isinstance(parent, dict):
                parent[k] = child
            indent_stack.append((indent, child))
            last_list_dict = None
        else:
            if isinstance(parent, dict):
                parent[k] = _parse_value(v)
            elif isinstance(parent, list) and last_list_dict is not None:
                # Continuation key for the last list-item dict
                # e.g. "to: 0.6" after "- from: 0.4"
                last_list_dict[k] = _parse_value(v)

    return cfg

try:
    import yaml
    with open(config_path) as f:
        cfg = yaml.safe_load(f)
except ImportError:
    cfg = parse_yaml_simple(config_path)

p = cfg.get('promote', {}).get('prerequisites', {})
print(f"CFG_MIN_ENTRIES={p.get('min_entries', 200)}")
print(f"CFG_MIN_RUNTIME_HOURS={p.get('min_runtime_hours', 48)}")
print(f"CFG_REJECT_RATE_THRESHOLD={p.get('reject_rate_threshold', 0.05)}")
print(f"CFG_DELTA_SLOPE_WINDOW={p.get('delta_slope_window', 100)}")
print(f"CFG_DELTA_SLOPE_MIN={p.get('delta_slope_min', 0)}")

steps = cfg.get('promote', {}).get('steps', [])
step_pairs = ' '.join(f"{s['from']}:{s['to']}" for s in steps if 'from' in s and 'to' in s)
print(f"CFG_PROMOTE_STEPS='{step_pairs}'")

e = cfg.get('evolve', {}).get('trigger', {})
print(f"CFG_EVOLVE_SLOPE_NEG_FOR={e.get('delta_slope_negative_for', 1000)}")
print(f"CFG_EVOLVE_REJECT_ABOVE={e.get('reject_rate_above', 0.20)}")

ec = cfg.get('evolve', {}).get('config', {})
print(f"CFG_EVOLVE_GENERATIONS={ec.get('generations', 3)}")
print(f"CFG_EVOLVE_POPULATION={ec.get('population', 4)}")
print(f"CFG_EVOLVE_WEIGHTS='{ec.get('weights', 'cb,val,exp')}'")

dr = cfg.get('dry_run', True)
dr_str = 'true' if dr else 'false'
print(f"CFG_DRY_RUN={dr_str}")
PYCONFIG
)"

# --live flag overrides config dry_run
if [ "$LIVE_OVERRIDE" = "true" ]; then
    DRY_RUN="false"
else
    DRY_RUN="$CFG_DRY_RUN"
fi

log "Starting (dry_run=$DRY_RUN, fed=$FED_DIR)"

# --- Safety guard 1: Federation running check ---

# All agentis CLI commands must run from $FED_DIR so the CLI finds
# .agentis/ (daemon registry, memo store, experience). Matches the
# cwd=fed_dir pattern in federation-dashboard.sh.
DAEMONS_JSON=$(cd "$FED_DIR" && agentis daemon list --json 2>/dev/null || echo "[]")
DAEMON_COUNT=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d))" "$DAEMONS_JSON")

if [ "$DAEMON_COUNT" -eq 0 ]; then
    log "Federation not running, no-op"
    journal_append "_system" "no-op" '{"reason": "federation not running"}'
    exit 0
fi

log "Found $DAEMON_COUNT daemon(s) running"

# --- Build per-agent state ---
# For each running daemon, collect: agent name, colony, pid, confidence,
# experience entry count, reject rate, delta slope.

DECISIONS_JSON=$(python3 - "$DAEMONS_JSON" "$FED_DIR" \
    "$CFG_MIN_ENTRIES" "$CFG_MIN_RUNTIME_HOURS" "$CFG_REJECT_RATE_THRESHOLD" \
    "$CFG_DELTA_SLOPE_WINDOW" "$CFG_DELTA_SLOPE_MIN" "$CFG_PROMOTE_STEPS" \
    "$CFG_EVOLVE_SLOPE_NEG_FOR" "$CFG_EVOLVE_REJECT_ABOVE" <<'PYEVAL'
import json, sys, os, time

daemons = json.loads(sys.argv[1])
fed_dir = sys.argv[2]
min_entries = int(sys.argv[3])
min_runtime_hours = float(sys.argv[4])
reject_rate_threshold = float(sys.argv[5])
delta_slope_window = int(sys.argv[6])
delta_slope_min = float(sys.argv[7])
promote_steps_raw = sys.argv[8]
evolve_slope_neg_for = int(sys.argv[9])
evolve_reject_above = float(sys.argv[10])

# Parse promote steps
promote_steps = []
for pair in promote_steps_raw.split():
    parts = pair.split(':')
    if len(parts) == 2:
        promote_steps.append((float(parts[0]), float(parts[1])))

now = time.time()
decisions = []

for d in daemons:
    source = d.get('source', '')
    if not source:
        continue
    agent_name = os.path.basename(source)
    if agent_name.endswith('.ag'):
        agent_name = agent_name[:-3]

    pid = d.get('pid', 0)
    state = d.get('state', '')
    agent_id = d.get('agent_id', '')
    colony = d.get('colony', '')
    started_at = d.get('started_at', 0)
    confidence = d.get('confidence')

    # Safety guard 3: Per-agent confidence existence check
    # If confidence is None, agent has never been seeded — skip
    if confidence is None:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'skip',
            'reason': 'confidence not seeded (recall_latest returned null)',
            'pid': pid,
        })
        continue

    # Safety guard 4: PID liveness check
    # If pid is missing (0) or dead, skip — we can't verify the daemon
    # is actually running, so acting on it is unsafe.
    if not pid or pid <= 0:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'skip',
            'reason': 'no pid reported by daemon list',
            'confidence': confidence,
        })
        continue
    try:
        os.kill(pid, 0)
    except OSError:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'skip',
            'reason': f'pid {pid} not alive',
            'pid': pid,
            'confidence': confidence,
        })
        continue

    # Compute runtime hours
    runtime_hours = (now - started_at) / 3600 if started_at else 0

    # Find experience file: .agentis/experience/<agent_id>.jsonl
    # Try both agent_id-based and agent_name-based paths
    exp_file = None
    exp_entries = []
    for pattern in [
        os.path.join(fed_dir, '.agentis', 'experience', f'{agent_id}.jsonl'),
        os.path.join(fed_dir, '.agentis', 'experience', f'{agent_name}.jsonl'),
    ]:
        if os.path.isfile(pattern):
            exp_file = pattern
            break

    if exp_file:
        try:
            with open(exp_file) as f:
                for line in f:
                    line = line.strip()
                    if line:
                        try:
                            exp_entries.append(json.loads(line))
                        except json.JSONDecodeError:
                            pass
        except OSError:
            pass

    entry_count = len(exp_entries)

    # Compute reject_rate from experience entries
    reject_count = sum(1 for e in exp_entries if e.get('verdict') == 'reject'
                       or e.get('outcome') == 'reject'
                       or e.get('rejected', False))
    reject_rate = reject_count / entry_count if entry_count > 0 else 0.0

    # Compute delta slope over the last N entries (linear regression on delta field)
    window = exp_entries[-delta_slope_window:] if len(exp_entries) >= delta_slope_window else exp_entries
    deltas = []
    for e in window:
        delta = e.get('delta')
        if delta is not None:
            try:
                deltas.append(float(delta))
            except (ValueError, TypeError):
                pass

    delta_slope = 0.0
    if len(deltas) >= 2:
        n = len(deltas)
        sx = sum(range(n))
        sy = sum(deltas)
        sxy = sum(i * d for i, d in enumerate(deltas))
        sx2 = sum(i * i for i in range(n))
        denom = n * sx2 - sx * sx
        if denom != 0:
            delta_slope = (n * sxy - sx * sy) / denom

    # Compute delta slope over the evolve window (longer)
    evolve_window = exp_entries[-evolve_slope_neg_for:] if len(exp_entries) >= evolve_slope_neg_for else exp_entries
    evolve_deltas = []
    for e in evolve_window:
        delta = e.get('delta')
        if delta is not None:
            try:
                evolve_deltas.append(float(delta))
            except (ValueError, TypeError):
                pass

    evolve_slope = 0.0
    if len(evolve_deltas) >= 2:
        n = len(evolve_deltas)
        sx = sum(range(n))
        sy = sum(evolve_deltas)
        sxy = sum(i * d for i, d in enumerate(evolve_deltas))
        sx2 = sum(i * i for i in range(n))
        denom = n * sx2 - sx * sx
        if denom != 0:
            evolve_slope = (n * sxy - sx * sy) / denom

    evidence = {
        'entries': entry_count,
        'runtime_hours': round(runtime_hours, 1),
        'reject_rate': round(reject_rate, 4),
        'delta_slope': round(delta_slope, 6),
        'evolve_slope': round(evolve_slope, 6),
        'confidence': confidence,
        'pid': pid,
    }

    # --- Evolve check (takes priority if agent is degrading) ---
    evolve_triggered = False
    if len(exp_entries) >= evolve_slope_neg_for and evolve_slope < 0:
        evolve_triggered = True
    if entry_count > 0 and reject_rate > evolve_reject_above:
        evolve_triggered = True

    if evolve_triggered:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'evolve',
            'reason': f'evolve triggered (slope={evolve_slope:.6f}, reject_rate={reject_rate:.4f})',
            'evidence': evidence,
        })
        continue

    # --- Promote check ---
    # Find applicable step for current confidence
    target_step = None
    for step_from, step_to in promote_steps:
        if abs(confidence - step_from) < 0.001:
            target_step = (step_from, step_to)
            break

    if target_step is None:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'skip',
            'reason': f'no applicable promote step for confidence={confidence}',
            'evidence': evidence,
        })
        continue

    # Check all prerequisites
    fails = []
    if entry_count < min_entries:
        fails.append(f'entries={entry_count} < {min_entries}')
    if runtime_hours < min_runtime_hours:
        fails.append(f'runtime={runtime_hours:.1f}h < {min_runtime_hours}h')
    if reject_rate >= reject_rate_threshold:
        fails.append(f'reject_rate={reject_rate:.4f} >= {reject_rate_threshold}')
    if delta_slope < delta_slope_min:
        fails.append(f'delta_slope={delta_slope:.6f} < {delta_slope_min}')

    if fails:
        decisions.append({
            'agent': agent_name,
            'colony': colony,
            'decision': 'skip',
            'reason': 'prerequisites not met: ' + '; '.join(fails),
            'evidence': evidence,
        })
        continue

    # All prerequisites passed — promote
    decisions.append({
        'agent': agent_name,
        'colony': colony,
        'decision': 'promote',
        'from': target_step[0],
        'to': target_step[1],
        'evidence': evidence,
    })

print(json.dumps(decisions))
PYEVAL
)

# --- Execute decisions ---

PROMOTE_COUNT=0
EVOLVE_COUNT=0
SKIP_COUNT=0

# Parse decisions and act on each.
# Process substitution (< <(...)) instead of pipe so the while loop runs
# in the current shell — counter variables survive after the loop.
while IFS='|' read -r decision agent colony step_from step_to reason evidence_json; do

    case "$decision" in
        skip)
            log "SKIP $agent ($colony): $reason"
            journal_append "$agent" "skip" "$evidence_json"
            SKIP_COUNT=$((SKIP_COUNT + 1))
            ;;

        promote)
            log "PROMOTE $agent ($colony): $step_from -> $step_to"
            if [ "$DRY_RUN" = "true" ]; then
                log "  [dry-run] Would run: agentis memo set ${agent}:confidence $step_to"
                log "  [dry-run] Would restart daemon for $agent"
                journal_append "$agent" "promote" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='dry-run'; print(json.dumps(e))" "$evidence_json")" \
                    "$step_from" "$step_to"
            else
                # Write new confidence to memo (cwd=FED_DIR for .agentis/ resolution)
                log "  Writing confidence: agentis memo set ${agent}:confidence $step_to"
                if (cd "$FED_DIR" && agentis memo set "${agent}:confidence" "$step_to") 2>&1; then
                    log "  Memo written successfully"
                else
                    log "  WARNING: memo set failed for $agent"
                    journal_append "$agent" "promote-failed" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['error']='memo_set_failed'; print(json.dumps(e))" "$evidence_json")" \
                        "$step_from" "$step_to"
                    continue
                fi

                # Restart the daemon so it picks up the new confidence.
                # Use the same stop+respawn pattern as the dashboard (#137).
                # The respawn must export GITLAB_* env vars from colony.toml
                # (the cron environment won't have them).
                log "  Restarting daemon for $agent..."
                AGENT_AG_FILE=""
                AGENT_COLONY_DIR=""
                for cdir in "$FED_DIR"/*/; do
                    candidate="${cdir}agents/${agent}.ag"
                    if [ -f "$candidate" ]; then
                        AGENT_AG_FILE="$candidate"
                        AGENT_COLONY_DIR="$cdir"
                        break
                    fi
                done

                if [ -z "$AGENT_AG_FILE" ]; then
                    log "  WARNING: could not find .ag file for $agent, skipping restart"
                    journal_append "$agent" "promote-partial" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='memo-only'; e['warning']='ag_file_not_found'; print(json.dumps(e))" "$evidence_json")" \
                        "$step_from" "$step_to"
                    continue
                fi

                # Read gitlab config from colony.toml (mirrors dashboard restart_daemon)
                COLONY_TOML="${AGENT_COLONY_DIR}config/colony.toml"
                SPAWN_ENV=$(python3 -c "
import sys, os
toml_path = sys.argv[1]
colony_dir = sys.argv[2]
# Minimal TOML [gitlab] section reader (same approach as federation-dashboard.sh)
vals = {}
in_section = False
try:
    with open(toml_path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('[') and line.endswith(']'):
                in_section = (line[1:-1].strip() == 'gitlab')
                continue
            if not in_section or '=' not in line:
                continue
            k, _, v = line.partition('=')
            k = k.strip()
            v = v.strip().strip('\"').strip(\"'\")
            vals[k] = v
except OSError:
    pass
url = vals.get('url', '')
token = vals.get('token', '')
project_raw = vals.get('project', '')
me = vals.get('me', '')
if not url or not token or not project_raw:
    print('__INCOMPLETE__')
else:
    project = project_raw.replace('/', '%2F')
    # Shell-safe export statements
    import shlex
    print(f'export GITLAB_URL={shlex.quote(url)}')
    print(f'export GITLAB_TOKEN={shlex.quote(token)}')
    print(f'export GITLAB_PROJECT={shlex.quote(project)}')
    print(f'export GITLAB_ME={shlex.quote(me)}')
    print(f'export COLONY_DIR={shlex.quote(colony_dir)}')
" "$COLONY_TOML" "$AGENT_COLONY_DIR" 2>/dev/null)

                if [ "$SPAWN_ENV" = "__INCOMPLETE__" ] || [ -z "$SPAWN_ENV" ]; then
                    log "  WARNING: incomplete [gitlab] in $COLONY_TOML, skipping restart"
                    journal_append "$agent" "promote-partial" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='memo-only'; e['warning']='incomplete_colony_toml'; print(json.dumps(e))" "$evidence_json")" \
                        "$step_from" "$step_to"
                    continue
                fi

                # Find agent_id from daemon list
                AGENT_ID=$(python3 -c "
import json, sys, os
daemons = json.loads(sys.argv[1])
agent = sys.argv[2]
for d in daemons:
    src = d.get('source', '')
    if os.path.basename(src) == agent + '.ag':
        print(d.get('agent_id', ''))
        break
" "$DAEMONS_JSON" "$agent")

                # Stop the daemon (cwd=FED_DIR for .agentis/ resolution)
                if [ -n "$AGENT_ID" ]; then
                    (cd "$FED_DIR" && agentis daemon stop "$AGENT_ID") 2>&1 || true
                    sleep 3
                fi

                # Resolve per-agent tick interval from start-colony.sh (#155)
                TICK_INTERVAL=$(python3 "$SCRIPT_DIR/resolve-tick-interval.py" "$agent" "$AGENT_COLONY_DIR" 2>/dev/null) || true
                TICK_INTERVAL="${TICK_INTERVAL:-60000}"

                # Respawn with GITLAB_* env vars from colony.toml
                (
                    eval "$SPAWN_ENV"
                    cd "$AGENT_COLONY_DIR"
                    agentis daemon "$AGENT_AG_FILE" \
                        --colony "$colony" \
                        --enable-exec \
                        --enable-messaging \
                        --tick-interval "$TICK_INTERVAL" &
                )
                log "  Daemon respawned for $agent"

                journal_append "$agent" "promote" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='executed'; print(json.dumps(e))" "$evidence_json")" \
                    "$step_from" "$step_to"
            fi
            PROMOTE_COUNT=$((PROMOTE_COUNT + 1))
            ;;

        evolve)
            log "EVOLVE $agent ($colony): $reason"
            if [ "$DRY_RUN" = "true" ]; then
                log "  [dry-run] Would run: agentis evolve $agent.ag (generations=$CFG_EVOLVE_GENERATIONS, population=$CFG_EVOLVE_POPULATION)"
                journal_append "$agent" "evolve" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='dry-run'; print(json.dumps(e))" "$evidence_json")"
            else
                # Find the .ag file for the agent
                AGENT_AG_FILE=""
                for cdir in "$FED_DIR"/*/; do
                    candidate="${cdir}agents/${agent}.ag"
                    if [ -f "$candidate" ]; then
                        AGENT_AG_FILE="$candidate"
                        break
                    fi
                done

                if [ -z "$AGENT_AG_FILE" ]; then
                    log "  WARNING: could not find .ag file for $agent, skipping evolve"
                    journal_append "$agent" "evolve-failed" \
                        "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['error']='ag_file_not_found'; print(json.dumps(e))" "$evidence_json")"
                    continue
                fi

                log "  Running: agentis evolve $AGENT_AG_FILE"
                EVOLVE_OUTPUT=$(cd "$FED_DIR" && agentis evolve "$AGENT_AG_FILE" \
                    --generations "$CFG_EVOLVE_GENERATIONS" \
                    --population "$CFG_EVOLVE_POPULATION" \
                    --weights "$CFG_EVOLVE_WEIGHTS" 2>&1) || true
                log "  Evolve output: $EVOLVE_OUTPUT"

                journal_append "$agent" "evolve" \
                    "$(python3 -c "import json,sys; e=json.loads(sys.argv[1]); e['action']='executed'; e['evolve_output']=sys.argv[2][:500]; print(json.dumps(e))" "$evidence_json" "$EVOLVE_OUTPUT")"
            fi
            EVOLVE_COUNT=$((EVOLVE_COUNT + 1))
            ;;
    esac
done < <(python3 -c "
import json, sys
decisions = json.loads(sys.argv[1])
for d in decisions:
    decision = d.get('decision', 'skip')
    agent = d.get('agent', '')
    colony = d.get('colony', '')
    step_from = d.get('from', '')
    step_to = d.get('to', '')
    reason = d.get('reason', '')
    evidence = json.dumps(d.get('evidence', d))
    print(f'{decision}|{agent}|{colony}|{step_from}|{step_to}|{reason}|{evidence}')
" "$DECISIONS_JSON")

log "Done. Promotes=$PROMOTE_COUNT, Evolves=$EVOLVE_COUNT, Skips=$SKIP_COUNT"
