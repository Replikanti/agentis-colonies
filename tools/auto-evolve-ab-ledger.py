#!/usr/bin/env python3
# tools/auto-evolve-ab-ledger.py — Ledger row writer for
# tools/auto-evolve-ab.sh (#628 PR-A).
#
# Emits one JSON object on stdout per invocation. Same extraction
# pattern as the auto-promote-config-parser.py / auto-promote-decisions.py
# pair: each Python block lives in its own helper file so the calling
# shell never opens a heredoc — see CLAUDE.md no-heredoc invariant +
# test-auto-promote.sh test 10.
#
# Usage:
#   auto-evolve-ab-ledger.py <event> <agent> <colony>
#       <generation> <parent_sha> <ab_ticks> <dry_run> <extras_json>
#
# All positional args are strings (the calling shell already has them
# in that form). `extras_json` is a JSON object literal whose top-level
# keys are merged into the row; pass `{}` for "no extras".
#
# Output: a single JSON line on stdout. The caller redirects it into
# the ledger file with `>>`. We deliberately do NOT take the ledger
# path as an argument so shellcheck SC2094 ("read and write same file
# in same pipeline") doesn't fire on the caller — the shell is the
# sole owner of file open + redirect semantics.

import json
import os
import sys
import time


def main():
    if len(sys.argv) != 9:
        sys.stderr.write(
            'Usage: %s <event> <agent> <colony> '
            '<generation> <parent_sha> <ab_ticks> <dry_run> <extras_json>\n'
            % os.path.basename(sys.argv[0])
        )
        return 2

    event = sys.argv[1]
    agent = sys.argv[2]
    colony = sys.argv[3]
    try:
        generation = int(sys.argv[4])
    except (ValueError, TypeError):
        generation = 0
    parent_sha = sys.argv[5]
    try:
        ab_ticks = int(sys.argv[6])
    except (ValueError, TypeError):
        ab_ticks = 0
    dry_run = sys.argv[7].lower() == 'true'
    extras_raw = sys.argv[8]

    try:
        extras = json.loads(extras_raw) if extras_raw else {}
    except (json.JSONDecodeError, ValueError):
        extras = {'_extras_parse_error': extras_raw[:200]}

    row = {
        'ts': int(time.time()),
        'ts_iso': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
        'event': event,
        'agent': agent,
        'colony': colony,
        'generation': generation,
        'parent_sha': parent_sha,
        'parent_sha8': parent_sha[:8] if parent_sha else '',
        'ab_ticks': ab_ticks,
        'dry_run': dry_run,
    }
    if isinstance(extras, dict):
        for k, v in extras.items():
            # Keep the base fields immutable so a malformed extras dict
            # can't corrupt downstream parsers' assumptions.
            if k not in row:
                row[k] = v

    print(json.dumps(row))
    return 0


if __name__ == '__main__':
    sys.exit(main() or 0)
