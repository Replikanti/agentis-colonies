#!/usr/bin/env python3
"""tribes-bench Stage 2 M3 (#394) snapshot max-elapsed reader.

Reads a `<run>/snapshots/` directory and emits the largest numeric stem
(`<elapsed>.txt`) on stdout. Returns 0 when the directory is empty or
missing. Pure stdlib.

Used by tools/run-stage2.sh on resume to continue snapshot numbering
without overwriting existing files.

Usage:
    run-stage2-snapshot-max.py <snapshots-dir>
"""

from __future__ import annotations

import os
import sys


def main() -> None:
    if len(sys.argv) != 2:
        print(0)
        return
    snapdir = sys.argv[1]
    if not os.path.isdir(snapdir):
        print(0)
        return
    best = 0
    for name in os.listdir(snapdir):
        if not name.endswith(".txt"):
            continue
        stem = name[: -len(".txt")]
        try:
            v = int(stem)
        except ValueError:
            continue
        if v > best:
            best = v
    print(best)


if __name__ == "__main__":
    main()
