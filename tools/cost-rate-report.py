#!/usr/bin/env python3
"""cost-rate-report.py - Per-agent / per-role cost + rate instrumentation
reducer for tools/cost-rate-report.sh (#1114).

Reads the per-prompt spend rows the agentis daemon publishes (one row ~= one
prompt) under <fed>/<colony>/.agentis/spend/<agent>.jsonl (#311) and folds
them into per-agent and per-role (per-colony) instrumentation records.

Reuses the spend-row reader / timestamp parser shape from
tools/cost-cap-sum.py (_row_ts, _read_rows) so the two reducers agree on how
a malformed row, a null cost_usd, or a missing timestamp is handled.

Per agent (and aggregated per role/colony) it computes:
  prompts          — spend row count
  prompts_per_hour — rolling rate over the trailing window from row ts
  chars_in         — proxy: avg_input_size (from `agentis stats`) x prompts
  chars_out        — proxy: sum of output_tokens over the rows
  cost_usd         — sum of cost_usd (null / missing -> 0, like cost-cap-sum)
  throttle_events  — forge-429 / "[llm.cancelled]" rows (SEPARATE from errors)
  task_errors      — agent failure markers (SEPARATE from throttle)
  retries          — colony-side retry markers (0 with a documented note when
                     not derivable from the spend rows)

The throttle-vs-task-error split is a hard DoD line: throttle and task_errors
are kept as distinct fields and never collapsed.

Input contract (positional args):
    1: spend_glob   — glob for spend files, e.g.
                      "<fed>/*/.agentis/spend/*.jsonl"
    2: window_min   — int, trailing window (minutes) for prompts_per_hour
    3: stats_json   — JSON string from `agentis stats --json --per-identity`
                      (or a per-colony map keyed by colony name); "{}" when
                      unavailable. Used only for the avg_input_size proxy.

Output: a single JSON object on stdout:
  {
    "window_min": <int>,
    "now_iso": "...",
    "agents": [ {<record>}, ... ],   # one per (colony, agent)
    "roles":  [ {<record>}, ... ]    # one per colony (role)
  }

Each <record> carries:
  colony, agent (omitted on role records), prompts, prompts_per_hour,
  chars_in, chars_out, cost_usd, throttle_events, task_errors, retries.

Exits non-zero only on bad CLI usage; emits an empty (zeroed) structure on
no-data so the sidecar can distinguish "no rows" from "broken helper".
"""
import datetime
import glob
import json
import os
import sys


# Markers a spend row may carry to indicate a throttle (rate-limit) event vs a
# task-level error. The runtime publishes a `cost_source` of "cancelled" /
# "llm.cancelled" when an LLM call is cancelled (e.g. the LLM backend HTTP-429
# backoff handled upstream by the agentis runtime / LLM backend); forge-429s
# surface via an explicit `throttle`/`http_status` field on a row. Task-level
# failures surface via an `outcome`/`error` field. Detection is intentionally
# tolerant — any of these fields may be absent on a normal success row.
_THROTTLE_SOURCES = ('cancelled', 'llm.cancelled')
_TASK_ERROR_OUTCOMES = ('fail', 'error', 'failed')


def _utc_now():
    return datetime.datetime.now(datetime.timezone.utc)


def _row_ts(row):
    """Parse a spend-row timestamp. Mirrors cost-cap-sum.py._row_ts so the two
    reducers agree on malformed / missing timestamps."""
    ts = row.get('ts')
    if isinstance(ts, (int, float)) and ts > 0:
        try:
            return datetime.datetime.fromtimestamp(float(ts), tz=datetime.timezone.utc)
        except (OSError, OverflowError, ValueError):
            return None
    iso = row.get('ts_iso') or row.get('iso_ts')
    if isinstance(iso, str) and iso:
        try:
            s = iso.replace('Z', '+00:00')
            dt = datetime.datetime.fromisoformat(s)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=datetime.timezone.utc)
            return dt
        except ValueError:
            return None
    return None


def _read_rows(path):
    """Read one spend file into a list of row dicts. Mirrors
    cost-cap-sum.py._read_rows but per-file (we need per-agent grouping)."""
    rows = []
    try:
        with open(path, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rows.append(json.loads(line))
                except (json.JSONDecodeError, ValueError):
                    continue
    except OSError:
        return []
    return rows


def _to_float(v):
    try:
        return float(v) if v is not None else 0.0
    except (TypeError, ValueError):
        return 0.0


def _to_int(v):
    try:
        return int(v) if v is not None else 0
    except (TypeError, ValueError):
        return 0


def _colony_agent_from_path(path):
    """Resolve (colony, agent) from a spend file path of the shape
    <fed>/<colony>/.agentis/spend/<agent>.jsonl.

    The colony is the directory two levels above the `.agentis` symlink; the
    agent is the file stem. Falls back to ('', stem) when the layout does not
    match so an unusual path never crashes the reducer."""
    agent = os.path.basename(path)
    if agent.endswith('.jsonl'):
        agent = agent[:-6]
    colony = ''
    norm = os.path.normpath(path)
    parts = norm.split(os.sep)
    try:
        idx = len(parts) - 1 - parts[::-1].index('.agentis')
        if idx >= 1:
            colony = parts[idx - 1]
    except ValueError:
        colony = ''
    return colony, agent


def _row_is_throttle(row):
    """A throttle event = forge-429 / [llm.cancelled]. Kept distinct from a
    task-level error (see _row_is_task_error)."""
    src = str(row.get('cost_source') or '').lower()
    if src in _THROTTLE_SOURCES:
        return True
    if row.get('throttle') is True or row.get('rate_limited') is True:
        return True
    status = _to_int(row.get('http_status') or row.get('status_code'))
    if status == 429:
        return True
    return False


def _row_is_task_error(row):
    """A task-level error = an agent failure marker. Kept distinct from a
    throttle/rate-limit event."""
    if _row_is_throttle(row):
        return False
    outcome = str(row.get('outcome') or '').lower()
    if outcome in _TASK_ERROR_OUTCOMES:
        return True
    if row.get('error'):
        return True
    return False


def _avg_input_size(stats_obj, colony, agent):
    """Look up the avg_input_size proxy. Accepts either a flat
    `agentis stats --json` object or a {colony: stats_obj} map; an inner
    per-identity / per-agent map is consulted first when present."""
    if not isinstance(stats_obj, dict):
        return 0.0
    scope = stats_obj
    # Per-colony map shape: {"triage": {...}, "planning": {...}}.
    if colony and colony in stats_obj and isinstance(stats_obj[colony], dict):
        scope = stats_obj[colony]
    # Optional per-identity / per-agent breakdown.
    for key in ('identities', 'per_identity', 'by_identity', 'agents'):
        inner = scope.get(key)
        if isinstance(inner, dict) and agent in inner and isinstance(inner[agent], dict):
            return _to_float(inner[agent].get('avg_input_size'))
        if isinstance(inner, list):
            for ent in inner:
                if isinstance(ent, dict) and ent.get('agent_id') == agent:
                    return _to_float(ent.get('avg_input_size'))
    return _to_float(scope.get('avg_input_size'))


def _fold(rows, now, window_min):
    """Fold a list of rows into an aggregate record (no colony/agent keys)."""
    window_min = max(1, int(window_min))
    window_start = now - datetime.timedelta(minutes=window_min)
    prompts = 0
    in_window = 0
    chars_out = 0
    cost_usd = 0.0
    throttle_events = 0
    task_errors = 0
    retries = 0
    for r in rows:
        prompts += 1
        cost_usd += _to_float(r.get('cost_usd'))
        chars_out += _to_int(r.get('output_tokens'))
        if _row_is_throttle(r):
            throttle_events += 1
        elif _row_is_task_error(r):
            task_errors += 1
        # Colony-side retry markers. Spend rows do not carry a retry count
        # today, so this stays 0 unless a row explicitly stamps `retries`
        # (documented note in cost-rate-report.sh + README). Counted here so
        # the field is wired end-to-end the moment the runtime emits it.
        retries += _to_int(r.get('retries'))
        dt = _row_ts(r)
        if dt is not None and dt >= window_start:
            in_window += 1
    prompts_per_hour = (in_window / float(window_min)) * 60.0
    return {
        'prompts': prompts,
        'prompts_per_hour': round(prompts_per_hour, 4),
        'chars_out': chars_out,
        'cost_usd': round(cost_usd, 6),
        'throttle_events': throttle_events,
        'task_errors': task_errors,
        'retries': retries,
    }


def main():
    if len(sys.argv) < 3:
        sys.stderr.write('Usage: %s <spend_glob> <window_min> [stats_json]\n' % sys.argv[0])
        return 2
    spend_glob = sys.argv[1]
    try:
        window_min = int(sys.argv[2])
    except ValueError:
        window_min = 60
    if window_min <= 0:
        window_min = 60
    stats_raw = sys.argv[3] if len(sys.argv) > 3 else '{}'
    try:
        stats_obj = json.loads(stats_raw or '{}')
    except (json.JSONDecodeError, ValueError):
        stats_obj = {}

    now = _utc_now()

    agent_records = []
    role_rows = {}
    for path in sorted(glob.glob(spend_glob)):
        colony, agent = _colony_agent_from_path(path)
        rows = _read_rows(path)
        rec = _fold(rows, now, window_min)
        avg_in = _avg_input_size(stats_obj, colony, agent)
        rec['chars_in'] = int(round(avg_in * rec['prompts']))
        rec['colony'] = colony
        rec['agent'] = agent
        agent_records.append(rec)
        role_rows.setdefault(colony, []).extend(rows)

    role_records = []
    for colony in sorted(role_rows.keys()):
        rows = role_rows[colony]
        rec = _fold(rows, now, window_min)
        avg_in = _avg_input_size(stats_obj, colony, '')
        rec['chars_in'] = int(round(avg_in * rec['prompts']))
        rec['colony'] = colony
        role_records.append(rec)

    out = {
        'window_min': window_min,
        'now_iso': now.strftime('%Y-%m-%dT%H:%M:%SZ'),
        'agents': agent_records,
        'roles': role_records,
    }
    print(json.dumps(out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
