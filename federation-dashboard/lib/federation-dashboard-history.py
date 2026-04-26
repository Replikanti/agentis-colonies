#!/usr/bin/env python3
"""federation-dashboard-history.py - Append a snapshot to the dashboard history.

Extracted from federation-dashboard.sh in #172 to eliminate the last bash
heredoc (the PYHISTORY block at line 137 of the legacy script). See #170
and federation-dashboard-renderer.py for the broader rationale.

Computes per-colony average confidence (skipping null agents per #143),
appends a single history entry, prunes entries older than 7 days, and
atomically rewrites the history file.

Args (positional):
    1: history_path     path to history.json
    2: epoch            int as string (current time)
    3: collector_json   JSON blob produced by federation-dashboard-collector.py
    4: colony_list_py   JSON list literal of colony names
"""
import json
import os
import sys


def _read(arg):
    """Resolve `@<path>` argv prefix to file contents; otherwise pass through.
    Mirrors the collector / renderer pattern so callers can spool large
    JSON blobs (e.g. COLLECTOR_JSON post-#315 PR 2) past Linux's 128 KB
    MAX_ARG_STRLEN per-argv cap. Same class of failure as #279/#293."""
    if arg.startswith('@'):
        with open(arg[1:], 'r', encoding='utf-8') as f:
            return f.read()
    return arg


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(
            'Usage: %s history_path epoch collector_json colony_list_py\n'
            % sys.argv[0]
        )
        sys.exit(2)

    path = sys.argv[1]
    epoch = int(sys.argv[2])

    try:
        collector = json.loads(_read(sys.argv[3]))
    except (json.JSONDecodeError, TypeError, ValueError, OSError):
        collector = {'agents': [], 'experience_counts': {'total': 0}}

    try:
        # colony_list parsed for forward compatibility; not consumed here.
        json.loads(_read(sys.argv[4]))
    except (json.JSONDecodeError, TypeError, ValueError, OSError):
        pass

    try:
        with open(path, 'r', encoding='utf-8') as f:
            history = json.load(f)
    except (json.JSONDecodeError, FileNotFoundError):
        history = []

    # Per-colony average confidence, skipping null agents (#140, #143)
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
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(history, f)
    os.replace(tmp, path)


if __name__ == '__main__':
    main()
