#!/usr/bin/env python3
"""tribes-bench Stage 2 M3 (#394) defensive prune helper.

On resume, removes orphan ``*.colony`` files under
``<run>/.agentis/daemon/`` whose mtime is older than the highest-elapsed
snapshot file in ``<run>/snapshots/``. A daemon that crashed mid-run can
leave behind a stale colony record that masquerades as alive when
``agentis daemon list`` reads the registry; pruning guarantees the
analyser sees only post-relaunch records.

Pure stdlib. Conservative: keeps every record newer than the snapshot
mtime, prunes only strictly older records.

Usage:
    run-stage2-prune.py <run-dir>
"""

from __future__ import annotations

import os
import sys


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(2)
    run_dir = sys.argv[1]
    if not os.path.isdir(run_dir):
        return
    snapdir = os.path.join(run_dir, "snapshots")
    daemon_dir = os.path.join(run_dir, ".agentis", "daemon")
    if not os.path.isdir(daemon_dir):
        return
    cutoff_mtime = 0.0
    if os.path.isdir(snapdir):
        best = 0
        best_mtime = 0.0
        for name in os.listdir(snapdir):
            if not name.endswith(".txt"):
                continue
            stem = name[: -len(".txt")]
            try:
                v = int(stem)
            except ValueError:
                continue
            try:
                mt = os.path.getmtime(os.path.join(snapdir, name))
            except OSError:
                continue
            if v > best:
                best = v
                best_mtime = mt
        cutoff_mtime = best_mtime
    if cutoff_mtime <= 0:
        return
    for name in os.listdir(daemon_dir):
        if not name.endswith(".colony"):
            continue
        path = os.path.join(daemon_dir, name)
        try:
            if os.path.getmtime(path) < cutoff_mtime:
                os.remove(path)
        except OSError:
            continue


if __name__ == "__main__":
    main()
