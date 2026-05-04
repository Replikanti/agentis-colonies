#!/usr/bin/env python3
"""Rewrite the `cb <N>;` per-tick budget declaration in a hunter.ag file
from the calibration-driven INITIAL_CB. Mirror of run-stage2-rewrite-cb.py
for the in-source declaration that #404 / #406 couldn't reach.

Idempotent: when the target value matches the existing literal, output is
byte-identical to input.

Issue: #407.
"""
import os
import re
import sys


def main():
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <hunter_ag_path> <new_cb>", file=sys.stderr)
        return 2
    path, new_cb_s = sys.argv[1], sys.argv[2]
    if not os.path.isfile(path):
        print(f"run-stage2-rewrite-cb-decl: not a file: {path}", file=sys.stderr)
        return 1
    try:
        new_cb = int(new_cb_s)
        if new_cb < 1:
            raise ValueError("must be positive")
    except ValueError as e:
        print(
            f"run-stage2-rewrite-cb-decl: bad new_cb {new_cb_s!r}: {e}",
            file=sys.stderr,
        )
        return 2
    try:
        with open(path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as e:
        print(
            f"run-stage2-rewrite-cb-decl: cannot read {path}: {e}", file=sys.stderr
        )
        return 1
    pattern = re.compile(r"^cb\s+\d+\s*;\s*$")
    new_line = f"cb {new_cb};\n"
    found = False
    for i, line in enumerate(lines):
        if pattern.match(line):
            lines[i] = new_line
            found = True
            break
    if not found:
        print(
            f"run-stage2-rewrite-cb-decl: no `cb <N>;` declaration found in {path}",
            file=sys.stderr,
        )
        return 2
    try:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(lines)
    except OSError as e:
        print(
            f"run-stage2-rewrite-cb-decl: cannot write {path}: {e}", file=sys.stderr
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
