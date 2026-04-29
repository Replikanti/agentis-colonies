#!/usr/bin/env python3
"""tribes-bench Stage 1 M3 calibration parser (#364).

Tiny stdlib-only helper that reads a key from `tribes-bench/calibration.toml`
and prints its value on stdout. Falls back to a documented default when
the key is missing so `tools/run-stage1.sh` stays robust against
operator edits that drop a key by mistake.

Usage:
    run-stage1-calibration.py <toml-path> <section> <key> <default>

Example:
    run-stage1-calibration.py calibration.toml tribe.economy initial_cb 1000

Why a separate file: CLAUDE.md's "no heredocs in tools/*.sh" invariant
(macOS bash 3.2 parser bug, see #172 / #245 / #271). Sourcing this
helper from `run-stage1.sh` keeps the shell free of inline python.

Implementation notes:
- Python 3.11+ ships `tomllib`; older Pythons use a tiny ad-hoc parser
  (the calibration file is small + flat, no inline tables, no arrays).
- All output is plain string. Caller treats values as positional args
  to be passed verbatim into env vars; numeric coercion happens in the
  `.ag` agents via parse_int().
"""

from __future__ import annotations

import sys


def parse_args(argv: list[str]) -> tuple[str, str, str, str]:
    if len(argv) != 5:
        print(
            "Usage: run-stage1-calibration.py <toml> <section> <key> <default>",
            file=sys.stderr,
        )
        sys.exit(2)
    return argv[1], argv[2], argv[3], argv[4]


def lookup_with_tomllib(path: str, section: str, key: str) -> str | None:
    try:
        import tomllib
    except ImportError:
        return None
    try:
        with open(path, "rb") as f:
            data = tomllib.load(f)
    except (OSError, Exception):  # pylint: disable=broad-except
        return None
    cur = data
    for part in section.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    if not isinstance(cur, dict) or key not in cur:
        return None
    val = cur[key]
    return str(val)


def lookup_with_fallback(path: str, section: str, key: str) -> str | None:
    """Tiny ad-hoc TOML parser. Handles only the flat key=value lines under
    a [section] header that calibration.toml uses. No inline tables, no
    arrays, no nested tables (beyond the dotted [tribe.economy] form which
    we treat as a literal section name).
    """
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError:
        return None
    cur_section: str | None = None
    target = section.strip()
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            cur_section = line[1:-1].strip()
            continue
        if cur_section != target:
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() != key:
            continue
        v = v.strip()
        # Strip a trailing comment.
        if "#" in v:
            v = v.split("#", 1)[0].rstrip()
        # Strip matching quotes.
        if len(v) >= 2 and v[0] == v[-1] and v[0] in ('"', "'"):
            v = v[1:-1]
        return v
    return None


def main() -> None:
    path, section, key, default = parse_args(sys.argv)
    val = lookup_with_tomllib(path, section, key)
    if val is None:
        val = lookup_with_fallback(path, section, key)
    if val is None:
        val = default
    print(val)


if __name__ == "__main__":
    main()
