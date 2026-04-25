#!/usr/bin/env bash
# cost-cap.sh - Hard daily/monthly LLM cost cap sidecar (#318)
#
# Reads <fed>/<colony>/.agentis/spend/*.jsonl (#311 publishes), evaluates
# usage against caps in <fed>/.cost-cap.toml, and on breach either
# downgrades agents to llm.backend = mock OR stops the federation.
#
# Mirrors tools/auto-promote.sh shape: lock file, structured journal,
# `<fed-dir>` arg, no-op when the federation is stopped.
#
# Usage:
#     ./tools/cost-cap.sh <federation-dir>
#     ./tools/cost-cap.sh <federation-dir> --override <reason>   # manual reset
#     ./tools/cost-cap.sh <federation-dir> --status              # JSON to stdout
#
# Modes (set in <fed>/.cost-cap.toml [cost].mode):
#     metered — sum cost_usd vs daily/monthly $ caps (per-token billing)
#     flat    — count requests + slope detection (subscription / Ollama)
#     off     — sidecar block self-skips at start-federation.sh time
#
# State machine in <fed>/.agentis/cost-cap-state.json:
#     active   < warn_at_pct% of any cap
#     warning  [warn_at_pct, 100%) — emits cost.warning + banner
#     breach   >= 100% — branches on on_breach (downgrade | stop)
#
# On breach + on_breach=downgrade: writes <fed>/.agentis/cost-cap-active +
# <fed>/.agentis/llm-backend-override (= "mock"); restarts every running
# daemon via <colony>/scripts/start-colony.sh --restart-agent <name>.
# start-colony.sh consults the override file and splices
# `--config-override llm.backend=mock` onto the daemon CLI.
#
# At UTC midnight / month boundary: clears flag/override, restarts agents
# back to the real backend, writes a `cost.cap_reset` row to the journal.
#
# All Python logic lives in tools/cost-cap-sum.py (JSONL reducer / slope
# calculator) and tools/cost-cap-lock.py (fcntl-based lock). Per the
# CLAUDE.md no-heredoc invariant, this script never uses heredocs.

set -eu

# --- Path resolution ---

SCRIPT_PATH="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <federation-dir> [--override <reason> | --status]"
    exit 1
fi

FED_DIR="$REPO_ROOT/$1"
if [ ! -d "$FED_DIR" ]; then
    FED_DIR="$1"
fi
if [ ! -d "$FED_DIR" ]; then
    echo "Federation directory not found: $1"
    exit 1
fi
shift

OVERRIDE_REASON=""
STATUS_ONLY=0
while [ $# -gt 0 ]; do
    case "$1" in
        --override)
            if [ -z "${2:-}" ]; then
                echo "cost-cap.sh: --override requires a reason string" >&2
                exit 2
            fi
            OVERRIDE_REASON="$2"
            shift 2
            ;;
        --status)
            STATUS_ONLY=1
            shift
            ;;
        *)
            echo "cost-cap.sh: unknown flag: $1" >&2
            exit 2
            ;;
    esac
done

CONFIG_FILE="$FED_DIR/.cost-cap.toml"
LOCK_FILE="$SCRIPT_DIR/.cost-cap.lock"
STATE_FILE="$FED_DIR/.agentis/cost-cap-state.json"
BANNER_FILE="$FED_DIR/.agentis/cost-cap-banner.json"
ACTIVE_FLAG="$FED_DIR/.agentis/cost-cap-active"
OVERRIDE_FILE="$FED_DIR/.agentis/llm-backend-override"
JOURNAL_FILE="$FED_DIR/.agentis/logs/cost-cap.jsonl"
OVERRIDE_AUDIT="$FED_DIR/.agentis/logs/cost-cap-override.jsonl"

mkdir -p "$FED_DIR/.agentis/logs" 2>/dev/null || true

# --- Lock (advisory, atomic) ---

exec 200>"$LOCK_FILE"
if ! python3 "$SCRIPT_DIR/cost-cap-lock.py" 200 2>/dev/null; then
    echo "Another cost-cap instance is running. Exiting."
    exit 0
fi

# --- Logging + journal helpers ---

log() {
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] cost-cap: $*"
}

journal_append() {
    local kind="$1" payload="$2"
    python3 -c "import json,sys,time; print(json.dumps({'ts': int(time.time()), 'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'kind': sys.argv[1], 'payload': json.loads(sys.argv[2])}))" "$kind" "$payload" >> "$JOURNAL_FILE"
}

# --- Parse config ---

if [ ! -f "$CONFIG_FILE" ]; then
    log "Config not found: $CONFIG_FILE"
    exit 0
fi

# Extract config keys via a small inline python helper (no heredoc).
# Emits shell-eval-able CC_* exports on stdout.
CC_EXPORTS="$(python3 -c "
import sys
path = sys.argv[1]
def parse_value(v):
    v = v.strip()
    if v.startswith('#'):
        return ''
    if '#' in v:
        in_q = None
        out = []
        for ch in v:
            if in_q:
                out.append(ch)
                if ch == in_q:
                    in_q = None
                continue
            if ch in ('\"', \"'\"):
                in_q = ch
                out.append(ch)
                continue
            if ch == '#':
                break
            out.append(ch)
        v = ''.join(out).strip()
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ('\"', \"'\"):
        return v[1:-1]
    return v
section = None
keys = {}
try:
    with open(path) as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith('#'):
                continue
            if line.startswith('[') and line.endswith(']'):
                section = line[1:-1].strip()
                continue
            if section is None or '=' not in line:
                continue
            k, _, v = line.partition('=')
            k = k.strip()
            v = parse_value(v)
            keys[(section, k)] = v
except OSError:
    pass

def get(sec, key, default=''):
    return keys.get((sec, key), default)

print('CC_ENABLED=%s'      % (get('cost', 'enabled') or 'false'))
print('CC_MODE=%s'         % (get('cost', 'mode') or 'metered'))
print('CC_WARN_PCT=%s'     % (get('cost', 'warn_at_pct') or '80'))
print('CC_INTERVAL=%s'     % (get('cost', 'interval_s') or '60'))
print('CC_DAILY_USD=%s'    % (get('cost.metered', 'daily_usd_limit') or '5.00'))
print('CC_MONTHLY_USD=%s'  % (get('cost.metered', 'monthly_usd_limit') or '100.00'))
print('CC_METER_BREACH=%s' % (get('cost.metered', 'on_breach') or 'downgrade'))
print('CC_DAILY_REQ=%s'    % (get('cost.flat', 'daily_request_limit') or '1000'))
print('CC_MONTHLY_REQ=%s'  % (get('cost.flat', 'monthly_request_limit') or '20000'))
print('CC_HOURLY_REQ=%s'   % (get('cost.flat', 'hourly_request_limit') or '200'))
print('CC_SLOPE_WIN=%s'    % (get('cost.flat', 'slope_window_min') or '60'))
print('CC_SLOPE_WARN=%s'   % (get('cost.flat', 'slope_warn_multiplier') or '3.0'))
print('CC_SLOPE_BREACH=%s' % (get('cost.flat', 'slope_breach_multiplier') or '5.0'))
print('CC_FLAT_BREACH=%s'  % (get('cost.flat', 'on_breach') or 'downgrade'))
" "$CONFIG_FILE")"

eval "$CC_EXPORTS"

# --- Find spend log glob ---

SPEND_GLOB="$FED_DIR/*/.agentis/spend/*.jsonl"

# --- restart_agent_to: helper to flip every running daemon to a backend ---
# Args: $1 = "mock" or "real"

restart_agents() {
    local target="$1"
    local daemons_json
    daemons_json="$(cd "$FED_DIR" && agentis daemon list --json 2>/dev/null || echo "[]")"
    local agent_list
    agent_list="$(python3 -c "
import json, os, sys
try:
    daemons = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
out = []
for d in daemons:
    if d.get('state') != 'running':
        continue
    src = d.get('source') or ''
    if not src:
        continue
    base = os.path.basename(src)
    if base.endswith('.ag'):
        base = base[:-3]
    colony = d.get('colony') or ''
    if base and colony:
        out.append('%s|%s' % (colony, base))
print('\n'.join(out))
" "$daemons_json")"
    if [ -z "$agent_list" ]; then
        return 0
    fi
    while IFS='|' read -r colony agent; do
        [ -z "$colony" ] && continue
        [ -z "$agent" ] && continue
        local script="$FED_DIR/$colony/scripts/start-colony.sh"
        if [ ! -x "$script" ]; then
            log "  WARN: $script not executable, skipping $agent"
            continue
        fi
        log "  restart $agent ($colony) -> backend=$target"
        if ! "$script" --restart-agent "$agent" >/dev/null 2>&1; then
            log "  WARN: restart-agent failed for $agent in $colony"
        fi
    done <<<"$agent_list"
}

# --- --override: clear flag + restart agents to real backend ---

if [ -n "$OVERRIDE_REASON" ]; then
    log "Manual override: $OVERRIDE_REASON"
    rm -f "$ACTIVE_FLAG" "$OVERRIDE_FILE" "$BANNER_FILE" 2>/dev/null || true
    AUDIT_PAYLOAD="$(python3 -c "import json,sys; print(json.dumps({'reason': sys.argv[1]}))" "$OVERRIDE_REASON")"
    {
        python3 -c "import json,sys,time; print(json.dumps({'ts': int(time.time()), 'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'kind': 'cost.override', 'payload': json.loads(sys.argv[1])}))" "$AUDIT_PAYLOAD"
    } >> "$OVERRIDE_AUDIT"
    journal_append "cost.override" "$AUDIT_PAYLOAD"
    restart_agents "real"
    log "  Override complete. Agents restored to real backend."
    exit 0
fi

# --- enabled = false: no-op ---

if [ "$CC_ENABLED" != "true" ]; then
    if [ "$STATUS_ONLY" = "1" ]; then
        python3 -c "import json,sys; print(json.dumps({'enabled': False, 'mode': sys.argv[1]}))" "$CC_MODE"
    else
        log "Disabled (cost.enabled=false), no-op"
    fi
    exit 0
fi

if [ "$CC_MODE" = "off" ]; then
    log "Mode=off, no-op"
    exit 0
fi

# --- Federation running check ---

DAEMONS_JSON="$(cd "$FED_DIR" && agentis daemon list --json 2>/dev/null || echo "[]")"
DAEMON_COUNT="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d))" "$DAEMONS_JSON")"

# --- Reduce spend log via cost-cap-sum.py ---

REDUCED_JSON="$(python3 "$SCRIPT_DIR/cost-cap-sum.py" "$CC_MODE" "$SPEND_GLOB" "$CC_SLOPE_WIN" 2>/dev/null || echo '{}')"

# --- Compute breach percentages + status ---
# DAILY_PCT, MONTHLY_PCT, HOURLY_PCT (flat-only) are per-cap percentages.
# STATUS = "active" | "warning" | "breach"
# REASON = short English string for the journal/banner.

EVAL_OUT="$(python3 -c "
import json, sys
mode = sys.argv[1]
warn_pct = float(sys.argv[2])
slope_warn = float(sys.argv[3])
slope_breach = float(sys.argv[4])
daily_usd_cap = float(sys.argv[5])
monthly_usd_cap = float(sys.argv[6])
daily_req_cap = float(sys.argv[7])
monthly_req_cap = float(sys.argv[8])
hourly_req_cap = float(sys.argv[9])
data = json.loads(sys.argv[10] or '{}')

def pct(v, cap):
    if cap <= 0:
        return 0.0
    return (v / cap) * 100.0

status = 'active'
reasons = []
metrics = {}
if mode == 'metered':
    m = data.get('metered') or {}
    daily = float(m.get('daily_usd') or 0)
    monthly = float(m.get('monthly_usd') or 0)
    daily_pct = pct(daily, daily_usd_cap)
    monthly_pct = pct(monthly, monthly_usd_cap)
    metrics['daily_pct'] = daily_pct
    metrics['monthly_pct'] = monthly_pct
    metrics['daily_spent'] = daily
    metrics['monthly_spent'] = monthly
    metrics['daily_cap'] = daily_usd_cap
    metrics['monthly_cap'] = monthly_usd_cap
    metrics['unknown_cost_pct'] = float(m.get('unknown_cost_pct') or 0)
    metrics['row_count'] = int(m.get('row_count') or 0)
    if daily_pct >= 100.0:
        status = 'breach'
        reasons.append('daily_usd %.4f >= cap %.4f' % (daily, daily_usd_cap))
    if monthly_pct >= 100.0:
        status = 'breach'
        reasons.append('monthly_usd %.4f >= cap %.4f' % (monthly, monthly_usd_cap))
    if status != 'breach':
        if daily_pct >= warn_pct or monthly_pct >= warn_pct:
            status = 'warning'
            if daily_pct >= warn_pct:
                reasons.append('daily_usd %.2f%% (>= %.0f%%)' % (daily_pct, warn_pct))
            if monthly_pct >= warn_pct:
                reasons.append('monthly_usd %.2f%% (>= %.0f%%)' % (monthly_pct, warn_pct))
else:
    f = data.get('flat') or {}
    daily = int(f.get('daily_requests') or 0)
    monthly = int(f.get('monthly_requests') or 0)
    hourly = int(f.get('hourly_requests') or 0)
    cur = float(f.get('current_rate') or 0)
    base = float(f.get('baseline_rate') or 0)
    sm = f.get('slope_multiplier')
    daily_pct = pct(daily, daily_req_cap)
    monthly_pct = pct(monthly, monthly_req_cap)
    hourly_pct = pct(hourly, hourly_req_cap)
    metrics['daily_pct'] = daily_pct
    metrics['monthly_pct'] = monthly_pct
    metrics['hourly_pct'] = hourly_pct
    metrics['daily_spent'] = daily
    metrics['monthly_spent'] = monthly
    metrics['hourly_spent'] = hourly
    metrics['daily_cap'] = daily_req_cap
    metrics['monthly_cap'] = monthly_req_cap
    metrics['hourly_cap'] = hourly_req_cap
    metrics['current_rate'] = cur
    metrics['baseline_rate'] = base
    metrics['slope_multiplier'] = sm
    if daily_pct >= 100.0 or monthly_pct >= 100.0 or hourly_pct >= 100.0:
        status = 'breach'
        if daily_pct >= 100.0:
            reasons.append('daily_requests %d >= cap %d' % (daily, int(daily_req_cap)))
        if monthly_pct >= 100.0:
            reasons.append('monthly_requests %d >= cap %d' % (monthly, int(monthly_req_cap)))
        if hourly_pct >= 100.0:
            reasons.append('hourly_requests %d >= cap %d' % (hourly, int(hourly_req_cap)))
    if sm is not None:
        sm_f = float(sm)
        if sm_f >= slope_breach:
            status = 'breach'
            reasons.append('slope_multiplier %.2fx >= breach %.2fx' % (sm_f, slope_breach))
        elif status != 'breach' and sm_f >= slope_warn:
            status = 'warning' if status == 'active' else status
            reasons.append('slope_multiplier %.2fx >= warn %.2fx' % (sm_f, slope_warn))
    if status != 'breach':
        if daily_pct >= warn_pct or monthly_pct >= warn_pct or hourly_pct >= warn_pct:
            status = 'warning'
            if daily_pct >= warn_pct:
                reasons.append('daily_requests %.2f%% (>= %.0f%%)' % (daily_pct, warn_pct))
            if monthly_pct >= warn_pct:
                reasons.append('monthly_requests %.2f%% (>= %.0f%%)' % (monthly_pct, warn_pct))
            if hourly_pct >= warn_pct:
                reasons.append('hourly_requests %.2f%% (>= %.0f%%)' % (hourly_pct, warn_pct))

out = {
    'status': status,
    'reasons': reasons,
    'metrics': metrics,
    'period_day': data.get('period_day') or '',
    'period_month': data.get('period_month') or '',
}
print(json.dumps(out))
" "$CC_MODE" "$CC_WARN_PCT" "$CC_SLOPE_WARN" "$CC_SLOPE_BREACH" "$CC_DAILY_USD" "$CC_MONTHLY_USD" "$CC_DAILY_REQ" "$CC_MONTHLY_REQ" "$CC_HOURLY_REQ" "$REDUCED_JSON")"

# --- --status mode: print evaluator output and exit ---

if [ "$STATUS_ONLY" = "1" ]; then
    python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
ev['enabled'] = True
ev['mode'] = sys.argv[2]
ev['daemon_count'] = int(sys.argv[3])
print(json.dumps(ev))
" "$EVAL_OUT" "$CC_MODE" "$DAEMON_COUNT"
    exit 0
fi

if [ "$DAEMON_COUNT" -eq 0 ]; then
    log "Federation not running, no-op"
    exit 0
fi

# --- Period rollover: clear flag + restore real backend at UTC day/month boundary ---

NEW_DAY="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('period_day',''))" "$EVAL_OUT")"
NEW_MONTH="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('period_month',''))" "$EVAL_OUT")"

OLD_DAY=""
OLD_MONTH=""
OLD_STATUS=""
if [ -f "$STATE_FILE" ]; then
    OLD_DAY="$(python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get('period_day') or '')
except Exception:
    print('')
" "$STATE_FILE")"
    OLD_MONTH="$(python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get('period_month') or '')
except Exception:
    print('')
" "$STATE_FILE")"
    OLD_STATUS="$(python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get('status') or '')
except Exception:
    print('')
" "$STATE_FILE")"
fi

PERIOD_RESET=0
if [ -n "$OLD_DAY" ] && [ "$OLD_DAY" != "$NEW_DAY" ]; then
    PERIOD_RESET=1
fi
if [ -n "$OLD_MONTH" ] && [ "$OLD_MONTH" != "$NEW_MONTH" ]; then
    PERIOD_RESET=1
fi

if [ "$PERIOD_RESET" = "1" ] && [ -f "$ACTIVE_FLAG" ]; then
    log "Period rollover (day=$OLD_DAY -> $NEW_DAY, month=$OLD_MONTH -> $NEW_MONTH); clearing flag + restoring real backend"
    rm -f "$ACTIVE_FLAG" "$OVERRIDE_FILE" "$BANNER_FILE" 2>/dev/null || true
    PR_PAYLOAD="$(python3 -c "import json,sys; print(json.dumps({'old_day': sys.argv[1], 'new_day': sys.argv[2], 'old_month': sys.argv[3], 'new_month': sys.argv[4]}))" "$OLD_DAY" "$NEW_DAY" "$OLD_MONTH" "$NEW_MONTH")"
    journal_append "cost.cap_reset" "$PR_PAYLOAD"
    restart_agents "real"
fi

# --- Auto-detection: cost_source unknown rate above 50% → suggest flat mode ---

if [ "$CC_MODE" = "metered" ]; then
    UNKNOWN_PCT="$(python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
m = ev.get('metrics') or {}
print(m.get('unknown_cost_pct', 0))
" "$EVAL_OUT")"
    HIGH_UNKNOWN="$(python3 -c "
import sys
v = float(sys.argv[1] or 0)
print('1' if v > 0.5 else '0')
" "$UNKNOWN_PCT")"
    if [ "$HIGH_UNKNOWN" = "1" ]; then
        MM_PAYLOAD="$(python3 -c "import json,sys; print(json.dumps({'unknown_cost_pct': float(sys.argv[1])}))" "$UNKNOWN_PCT")"
        journal_append "cost.mode_mismatch" "$MM_PAYLOAD"
        log "WARN: cost_source != real on >50% of rows — consider switching to flat mode"
    fi
fi

# --- State machine + actions ---

NEW_STATUS="$(python3 -c "import json,sys; print(json.loads(sys.argv[1]).get('status',''))" "$EVAL_OUT")"
REASONS_STR="$(python3 -c "import json,sys; print(' / '.join(json.loads(sys.argv[1]).get('reasons') or []))" "$EVAL_OUT")"

log "status=$NEW_STATUS reasons='$REASONS_STR'"

# Persist state (incl. since_ts: epoch when current status was first observed).
SINCE_TS="$(date +%s)"
if [ "$OLD_STATUS" = "$NEW_STATUS" ] && [ -f "$STATE_FILE" ]; then
    SINCE_TS="$(python3 -c "
import json, sys
try:
    s = json.load(open(sys.argv[1]))
    print(s.get('since_ts') or sys.argv[2])
except Exception:
    print(sys.argv[2])
" "$STATE_FILE" "$SINCE_TS")"
fi

python3 -c "
import json, sys
state = {
    'status': sys.argv[1],
    'period_day': sys.argv[2],
    'period_month': sys.argv[3],
    'since_ts': int(sys.argv[4]),
    'reasons': sys.argv[5].split(' / ') if sys.argv[5] else [],
    'metrics': json.loads(sys.argv[6]).get('metrics') or {},
    'mode': sys.argv[7],
}
with open(sys.argv[8], 'w') as f:
    json.dump(state, f)
" "$NEW_STATUS" "$NEW_DAY" "$NEW_MONTH" "$SINCE_TS" "$REASONS_STR" "$EVAL_OUT" "$CC_MODE" "$STATE_FILE"

case "$NEW_STATUS" in
    active)
        # Clear stale banner if status transitioned out of warning/breach
        if [ "$OLD_STATUS" = "warning" ] || [ "$OLD_STATUS" = "breach" ]; then
            rm -f "$BANNER_FILE" 2>/dev/null || true
        fi
        ;;
    warning)
        WARN_PAYLOAD="$(python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
print(json.dumps({'mode': sys.argv[2], 'reasons': ev.get('reasons') or [], 'metrics': ev.get('metrics') or {}}))
" "$EVAL_OUT" "$CC_MODE")"
        journal_append "cost.warning" "$WARN_PAYLOAD"
        python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
banner = {
    'state': 'warning',
    'mode': sys.argv[2],
    'reasons': ev.get('reasons') or [],
    'metrics': ev.get('metrics') or {},
    'since_ts': int(sys.argv[3]),
    'period_day': ev.get('period_day') or '',
    'period_month': ev.get('period_month') or '',
}
with open(sys.argv[4], 'w') as f:
    json.dump(banner, f)
" "$EVAL_OUT" "$CC_MODE" "$SINCE_TS" "$BANNER_FILE"
        ;;
    breach)
        if [ "$CC_MODE" = "metered" ]; then
            ON_BREACH="$CC_METER_BREACH"
        else
            ON_BREACH="$CC_FLAT_BREACH"
        fi
        BREACH_PAYLOAD="$(python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
print(json.dumps({'mode': sys.argv[2], 'on_breach': sys.argv[3], 'reasons': ev.get('reasons') or [], 'metrics': ev.get('metrics') or {}}))
" "$EVAL_OUT" "$CC_MODE" "$ON_BREACH")"
        journal_append "cost.breach" "$BREACH_PAYLOAD"
        case "$ON_BREACH" in
            downgrade)
                if [ ! -f "$ACTIVE_FLAG" ]; then
                    date +%s > "$ACTIVE_FLAG"
                    echo "mock" > "$OVERRIDE_FILE"
                    log "BREACH: writing override (backend=mock) + restarting agents"
                    restart_agents "mock"
                else
                    log "BREACH: override already active, no restart"
                fi
                ;;
            stop)
                log "BREACH: on_breach=stop — calling agentis daemon stop --all"
                (cd "$FED_DIR" && agentis daemon stop --all >/dev/null 2>&1) || true
                ;;
            *)
                log "BREACH: unknown on_breach='$ON_BREACH', no action"
                ;;
        esac
        python3 -c "
import json, sys
ev = json.loads(sys.argv[1])
banner = {
    'state': 'breach',
    'mode': sys.argv[2],
    'on_breach': sys.argv[3],
    'reasons': ev.get('reasons') or [],
    'metrics': ev.get('metrics') or {},
    'since_ts': int(sys.argv[4]),
    'period_day': ev.get('period_day') or '',
    'period_month': ev.get('period_month') or '',
}
with open(sys.argv[5], 'w') as f:
    json.dump(banner, f)
" "$EVAL_OUT" "$CC_MODE" "$ON_BREACH" "$SINCE_TS" "$BANNER_FILE"
        ;;
esac

log "Done."
