#!/usr/bin/env python3
# tools/explorer-fitness.py: back-compat shim for colony-fitness.py.
#
# Phase 9 PR-B of #663 renamed the Phase 3 explorer-specific tool to
# `tools/colony-fitness.py` and added a `--colony <name>` flag. This
# shim forwards all args to colony-fitness.py with `--colony explorer`
# so existing call sites (notably the dashboard's preview-mode
# explorer enrichment + test 12 in test-auto-promote.sh) keep working
# byte-identically.

import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
TARGET = os.path.join(SCRIPT_DIR, 'colony-fitness.py')


def main():
    argv = sys.argv[1:]
    # Splice `--colony explorer` after the positional args (the target
    # parses positionals first, then flags). If `--colony` is already
    # present in argv (someone calling the shim with an override), keep
    # their value verbatim.
    has_colony = False
    i = 0
    while i < len(argv):
        if argv[i] == '--colony':
            has_colony = True
            break
        i += 1

    new_argv = list(argv)
    if not has_colony:
        new_argv.extend(['--colony', 'explorer'])

    os.execvp('python3', ['python3', TARGET] + new_argv)


if __name__ == '__main__':
    sys.exit(main() or 0)
