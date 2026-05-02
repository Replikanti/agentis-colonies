#!/usr/bin/env python3
"""tribes-bench Stage 2 M3 (#394) template renderer.

Substitutes ``{{KEY}}`` placeholders in a template file with values
provided as ``KEY=value`` argv pairs and writes the result to a
destination path. Pure stdlib.

Usage:
    run-baseline-render.py <src> <dst> KEY1=VALUE1 [KEY2=VALUE2 ...]

Why a separate file: CLAUDE.md "no heredocs in tools/*.sh" invariant
(macOS bash 3.2 parser bug, see #172 / #245 / #271). Sourcing this
helper from tools/run-baseline.sh keeps the shell free of inline python.
"""

from __future__ import annotations

import os
import sys


def parse_args(argv: list[str]) -> tuple[str, str, dict[str, str]]:
    if len(argv) < 4:
        print(
            "Usage: run-baseline-render.py <src> <dst> KEY=VAL [KEY=VAL ...]",
            file=sys.stderr,
        )
        sys.exit(2)
    src = argv[1]
    dst = argv[2]
    subs: dict[str, str] = {}
    for raw in argv[3:]:
        if "=" not in raw:
            print(f"run-baseline-render: bad pair (no =): {raw!r}", file=sys.stderr)
            sys.exit(2)
        k, _, v = raw.partition("=")
        subs[k.strip()] = v
    return src, dst, subs


def render(src: str, dst: str, subs: dict[str, str]) -> None:
    with open(src, encoding="utf-8") as f:
        content = f.read()
    for key, val in subs.items():
        content = content.replace("{{" + key + "}}", val)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write(content)


def main() -> None:
    src, dst, subs = parse_args(sys.argv)
    if not os.path.isfile(src):
        print(f"run-baseline-render: source missing: {src}", file=sys.stderr)
        sys.exit(2)
    render(src, dst, subs)


if __name__ == "__main__":
    main()
