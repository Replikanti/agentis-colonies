#!/usr/bin/env python3
"""federation-dashboard-timeline.py - Write the full federation-wide
timeline as JSONL for the /timeline HTTP endpoint to read (#315 PR 2).

The wrapper invokes this helper after each generate() cycle. We read the
four canonical source streams once (experience, spend, lifecycle,
confidence-log), merge them into the unified envelope, augment with
agent_name + colony, sort ts-desc, cap at 7 days OR 5000 rows (whichever
is smaller), and write the result atomically (temp + rename).

The embedded `output['timeline']` in the collector caps at 200 rows for
the in-page tile; this helper writes a wider window for paginated
queries. Schema per row matches the per-agent timeline envelope:
    {ts: <int, ms>, agent_id: "<sha8>", kind: "<enum>",
     payload: <object>, severity: "info"|"warning"|"error",
     agent_name: "<role>", colony: "<colony>"}

DO NOT inline this back into the wrapper — federation-dashboard.sh has a
zero-heredoc invariant (test 19 of test-timeline-rendering.sh enforces).

Args (positional):
    1: exp_dir          path to .agentis/experience/
    2: spend_dir        path to .agentis/spend/
    3: lifecycle_dir    path to .agentis/lifecycle/
    4: dash_dir         dashboard cache dir (for confidence-log.jsonl)
    5: agent_map_json   JSON array of {agent, colony} pairs
    6: daemons_json     JSON array from `agentis daemon list --json`,
                        or "@<path>" to read from file (#293)
    7: out_path         where to write timeline-full.jsonl
    8: now              injected "now" (epoch seconds or ms) — the single
                        epoch the caller already sampled for the collector
                        (#1043 / #1145); never re-sample the wall clock here

The file is written newline-delimited JSON, one row per line, in
reverse-chronological order (newest first). Every row that is not a
valid JSON object on parse is silently dropped (mirrors the collector's
tolerance pattern).
"""

import os
import sys
import json

TIMELINE_FULL_CAP = 5000
SEVEN_DAYS_MS = 7 * 24 * 3600 * 1000


def _read_arg(arg):
    if arg.startswith('@'):
        try:
            with open(arg[1:], 'r', encoding='utf-8') as f:
                return f.read()
        except OSError:
            return ''
    return arg


def _coerce_ms(ts):
    """Coerce a timestamp to epoch-ms. Accepts seconds (10-digit), ms
    (13-digit), or None/garbage. Returns 0 on failure."""
    if not isinstance(ts, (int, float)):
        return 0
    n = int(ts)
    if n <= 0:
        return 0
    return n if n >= 10 ** 11 else n * 1000


def _read_jsonl(path):
    """Yield dict rows from a JSONL file; tolerate missing file +
    malformed lines silently."""
    if not path or not os.path.isfile(path):
        return []
    out = []
    try:
        with open(path, encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if isinstance(row, dict):
                    out.append(row)
    except OSError:
        pass
    return out


def _severity(kind, payload):
    """Same classifier as the collector's _summary_severity."""
    if kind == 'learn':
        outcome = (payload.get('outcome') or '').lower()
        return 'error' if outcome == 'failure' else 'info'
    if kind == 'prompt':
        return 'info' if payload.get('ok', True) else 'error'
    if kind == 'confidence_change':
        return 'info'
    if kind == 'lifecycle':
        ev = (payload.get('event') or '').lower()
        if 'critical' in (payload.get('new_status') or '').lower():
            return 'warning'
        if 'quarantine' in ev or 'restart' in ev or 'health_changed' in ev:
            return 'warning'
        if 'failed' in ev or 'crashed' in ev:
            return 'error'
    return 'info'


def main():
    if len(sys.argv) != 9:
        sys.stderr.write(
            'Usage: %s exp_dir spend_dir lifecycle_dir dash_dir '
            'agent_map_json daemons_json out_path now\n' % sys.argv[0]
        )
        sys.exit(2)

    exp_dir       = sys.argv[1]
    spend_dir     = sys.argv[2]
    lifecycle_dir = sys.argv[3]
    dash_dir      = sys.argv[4]
    agent_map_raw = sys.argv[5]
    daemons_raw   = _read_arg(sys.argv[6])
    out_path      = sys.argv[7]
    now_arg       = sys.argv[8]

    try:
        agent_map = json.loads(agent_map_raw or '[]')
    except (ValueError, json.JSONDecodeError):
        agent_map = []
    try:
        daemons = json.loads(daemons_raw or '[]')
    except (ValueError, json.JSONDecodeError):
        daemons = []

    # role -> {agent_name (== role), colony}
    role_to_colony = {e.get('agent', ''): e.get('colony', '')
                      for e in agent_map if isinstance(e, dict)}
    # agent_id -> {agent_name, colony}. Source field on each daemon row
    # carries the .ag basename which is the role / agent_name.
    aid_to_meta = {}
    for d in daemons:
        if not isinstance(d, dict):
            continue
        aid = d.get('agent_id') or ''
        src = d.get('source') or ''
        if not aid or not src:
            continue
        role = os.path.basename(src)
        if role.endswith('.ag'):
            role = role[:-3]
        aid_to_meta[aid] = {
            'agent_name': role,
            'colony': role_to_colony.get(role, ''),
        }

    # `now` MUST be injected — the caller passes the single epoch it already
    # sampled for the collector (argv[8]). Re-sampling the wall clock here
    # would take a SECOND sample that can disagree with that one across the
    # 00:00 UTC date boundary, flaking the timeline test (#1043 / #1145).
    try:
        now_n = int(now_arg)
    except (TypeError, ValueError):
        now_n = 0
    now_ms = _coerce_ms(now_n)
    cutoff = now_ms - SEVEN_DAYS_MS

    # Bucket lifecycle + confidence-log by agent_id ONCE — both files are
    # federation-wide and would otherwise be re-read per agent.
    lifecycle_by_aid = {}
    lifecycle_path = os.path.join(lifecycle_dir, 'events.jsonl') if lifecycle_dir else ''
    for ev in _read_jsonl(lifecycle_path):
        aid = ev.get('agent_id') or ''
        if aid:
            lifecycle_by_aid.setdefault(aid, []).append(ev)

    conf_by_aid = {}
    conf_path = os.path.join(dash_dir, 'confidence-log.jsonl') if dash_dir else ''
    for c in _read_jsonl(conf_path):
        aid = c.get('agent_id') or ''
        if aid:
            conf_by_aid.setdefault(aid, []).append(c)

    rows = []
    for aid, meta in aid_to_meta.items():
        # Experience (epoch-seconds → ms)
        ep = os.path.join(exp_dir, aid + '.jsonl') if exp_dir else ''
        for e in _read_jsonl(ep):
            t = _coerce_ms(e.get('ts'))
            if t == 0 or t < cutoff:
                continue
            payload = {
                'outcome': e.get('outcome'),
                'delta':   e.get('delta'),
                'action':  e.get('action'),
                'in':      e.get('in'),
            }
            rows.append({
                'ts': t, 'agent_id': aid, 'kind': 'learn',
                'payload': payload,
                'severity': _severity('learn', payload),
                'agent_name': meta['agent_name'],
                'colony': meta['colony'],
            })

        # Spend (already ms)
        sp = os.path.join(spend_dir, aid + '.jsonl') if spend_dir else ''
        for s in _read_jsonl(sp):
            t = _coerce_ms(s.get('ts'))
            if t == 0 or t < cutoff:
                continue
            payload = {
                'cost_usd':      s.get('cost_usd'),
                'input_tokens':  s.get('input_tokens'),
                'output_tokens': s.get('output_tokens'),
                'model':         s.get('model'),
                'backend':       s.get('backend'),
                'ok':            s.get('ok', True),
            }
            rows.append({
                'ts': t, 'agent_id': aid, 'kind': 'prompt',
                'payload': payload,
                'severity': _severity('prompt', payload),
                'agent_name': meta['agent_name'],
                'colony': meta['colony'],
            })

        for c in conf_by_aid.get(aid, []):
            t = _coerce_ms(c.get('ts'))
            if t == 0 or t < cutoff:
                continue
            payload = {
                'from':  c.get('from') if c.get('from') is not None else c.get('prev'),
                'to':    c.get('to')   if c.get('to')   is not None else c.get('new'),
                'delta': c.get('delta'),
                'reason': c.get('reason') or c.get('source'),
            }
            rows.append({
                'ts': t, 'agent_id': aid, 'kind': 'confidence_change',
                'payload': payload,
                'severity': _severity('confidence_change', payload),
                'agent_name': meta['agent_name'],
                'colony': meta['colony'],
            })

        for ev in lifecycle_by_aid.get(aid, []):
            t = _coerce_ms(ev.get('ts'))
            if t == 0 or t < cutoff:
                continue
            payload = {k: v for k, v in ev.items() if k != 'agent_id'}
            rows.append({
                'ts': t, 'agent_id': aid, 'kind': 'lifecycle',
                'payload': payload,
                'severity': _severity('lifecycle', payload),
                'agent_name': meta['agent_name'],
                'colony': meta['colony'],
            })

    rows.sort(key=lambda r: r.get('ts', 0), reverse=True)
    rows = rows[:TIMELINE_FULL_CAP]

    tmp = out_path + '.tmp.' + str(os.getpid())
    try:
        with open(tmp, 'w', encoding='utf-8') as f:
            for r in rows:
                f.write(json.dumps(r, separators=(',', ':')))
                f.write('\n')
        os.replace(tmp, out_path)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        sys.exit(1)


if __name__ == '__main__':
    main()
