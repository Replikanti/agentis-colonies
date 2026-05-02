#!/usr/bin/env python3
"""tribes-bench Stage 2 M3 (#394) run-meta.json writer.

Tiny stdlib helper that emits ``run-meta.json`` with the M3 metadata
schema. Pure stdlib.

Usage:
    run-baseline-meta.py <out_path> <started_at> <wall_clock_s> \
                        <snapshot_s> <llm_backend> <baseline_cb> <kind>

Why a separate file: CLAUDE.md "no heredocs in tools/*.sh" invariant.
"""

from __future__ import annotations

import json
import sys


def main() -> None:
    if len(sys.argv) != 8:
        print(
            "Usage: run-baseline-meta.py <out> <started_at> <wall_s> "
            "<snap_s> <llm> <cb> <kind>",
            file=sys.stderr,
        )
        sys.exit(2)
    out, started_at, wall_s, snap_s, llm, cb, kind = sys.argv[1:8]
    payload = {
        "started_at": started_at,
        "wall_clock_s": int(wall_s),
        "snapshot_s": int(snap_s),
        "llm_backend": llm,
        "baseline_cb": int(cb),
        "kind": kind,
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2, sort_keys=True)
        f.write("\n")


if __name__ == "__main__":
    main()
