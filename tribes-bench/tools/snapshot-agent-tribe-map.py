#!/usr/bin/env python3
"""Snapshot the agent_id -> tribe mapping from a daemon registry directory.

Stage 2 harness (#416) helper. `tools/kill-federation.sh` removes the
`<agentis-root>/daemon/*.colony` files as part of shutdown, which races
the analyse-stage2.py pass that uses those files to attribute findings
to tribes. Calling this helper BEFORE kill-federation captures the map
into a JSON sidecar that analyse-stage2.py reads in preference to the
(by then empty) registry directory.

Usage:
    snapshot-agent-tribe-map.py <daemon-dir>

Emits a JSON dict {agent_id: tribe_name, ...} to stdout. Robust against
a missing or unreadable directory (emits `{}`). Pure stdlib.
"""

from __future__ import annotations

import json
import os
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(
            "Usage: snapshot-agent-tribe-map.py <daemon-dir>",
            file=sys.stderr,
        )
        return 2
    daemon_dir = sys.argv[1]
    result: dict[str, str] = {}
    if os.path.isdir(daemon_dir):
        for fname in os.listdir(daemon_dir):
            if not fname.endswith(".colony"):
                continue
            agent_id = fname[: -len(".colony")]
            path = os.path.join(daemon_dir, fname)
            try:
                with open(path, encoding="utf-8") as f:
                    colony = f.read().strip()
            except (OSError, UnicodeDecodeError):
                continue
            if colony:
                result[agent_id] = colony
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
