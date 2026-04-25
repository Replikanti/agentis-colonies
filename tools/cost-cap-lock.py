#!/usr/bin/env python3
"""cost-cap-lock.py - Acquire an exclusive advisory lock on an inherited FD.

Mirrors tools/auto-promote-lock.py (#245). The parent shell opens the lock
file with `exec 200>"$LOCK_FILE"` and invokes this helper with the FD
number. We call fcntl.flock(LOCK_EX | LOCK_NB) on that FD. POSIX flock
locks are associated with the open file description, so the lock persists
as long as any FD pointing to that OFD stays open. This helper exits after
acquiring the lock; the parent shell keeps its FD open until the cost-cap
run completes, which keeps the lock held without a supervisor process.

Works on Linux (OFD-based flock) and macOS (BSD flock — same OFD semantics
per flock(2): "This lock is removed on close(2) of the last file
descriptor that references the open file").

Exit 0 on successful acquire, 1 on contention, 2 on bad usage.

Args (positional):
    1: fd — integer FD number inherited from the parent shell
"""
import fcntl
import sys


def main():
    if len(sys.argv) != 2:
        sys.stderr.write('Usage: %s <fd>\n' % sys.argv[0])
        return 2
    try:
        fd = int(sys.argv[1])
    except ValueError:
        sys.stderr.write('Not an integer FD: %s\n' % sys.argv[1])
        return 2
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
