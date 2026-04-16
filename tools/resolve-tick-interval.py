#!/usr/bin/env python3
"""Resolve the tick interval for an agent from its colony's start-colony.sh.

Usage: resolve-tick-interval.py <agent> <colony-dir>
Output: interval in milliseconds (default 60000)

Reads tick_interval_for() case statement (or legacy declare -A) from
<colony-dir>/scripts/start-colony.sh. This keeps start-colony.sh as
the single source of truth — the dashboard and auto-promote script
both call this helper instead of hardcoding 60000.

See #146 for why intervals differ per colony, #155 for why this
helper exists, and #157 for the bash 3.2 migration.
"""
import os
import re
import sys

DEFAULT_INTERVAL = 60000


def resolve(agent, colony_dir):
    """Return the tick interval (int, ms) for *agent* in *colony_dir*."""
    script = os.path.join(colony_dir, 'scripts', 'start-colony.sh')
    try:
        with open(script, encoding='utf-8') as f:
            content = f.read()
    except OSError:
        return DEFAULT_INTERVAL

    # New format (#157): case statement with pipe-separated agent names
    #   agent_name|other_agent) echo 300000 ;;
    escaped = re.escape(agent)
    case_pattern = rf'\b{escaped}\b.*?\)\s+echo\s+(\d+)\s*;;'
    m = re.search(case_pattern, content)
    if m:
        return int(m.group(1))

    # Legacy format: declare -A  ["agent_name"]=12345
    legacy_pattern = rf'\["{escaped}"\]\s*=\s*(\d+)'
    m = re.search(legacy_pattern, content)
    return int(m.group(1)) if m else DEFAULT_INTERVAL


if __name__ == '__main__':
    if len(sys.argv) != 3:
        print(DEFAULT_INTERVAL)
        sys.exit(0)
    print(resolve(sys.argv[1], sys.argv[2]))
