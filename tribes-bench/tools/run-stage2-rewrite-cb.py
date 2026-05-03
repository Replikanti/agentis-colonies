#!/usr/bin/env python3
"""tribes-bench Stage 2 cb_budget rewriter (#404).

Rewrites every ``cb_budget`` value across all ``[[agents]]`` tables in a
per-tribe ``colony.toml`` to a new value taken from the harness env
(``INITIAL_CB``, sourced from ``tribes-bench/calibration.toml``). Used
by ``tools/run-stage2.sh`` and ``tools/run-baseline.sh`` to keep
calibration as the single source of truth for the per-tick CB budget.

Usage:
    run-stage2-rewrite-cb.py <toml-path> <new-cb-budget>

The new value must be a non-negative integer. The TOML file is parsed
with stdlib ``tomllib`` (Python 3.11+). When the parse fails, exit 1
with a stderr message — the harness aborts the run rather than launch
with a stale budget.

Why a separate file: CLAUDE.md "no heredocs in tools/*.sh" invariant
(macOS bash 3.2 parser bug, see #172 / #245 / #271). Sourcing this
helper from tools/run-stage2.sh and tools/run-baseline.sh keeps the
shell free of inline python.

Implementation notes:
- Parse via ``tomllib`` to validate; rewrite via line-oriented regex on
  the original file content so we do NOT need ``tomli_w`` (not
  vendored). Comments + key ordering are preserved.
- Every ``cb_budget = <int>`` line at the start of a (possibly
  whitespace-indented) line is rewritten. The TOML grammar guarantees
  this token never appears inside a multi-line string under our
  scaffolded colony.toml shape.
"""

from __future__ import annotations

import re
import sys


def parse_args(argv: list[str]) -> tuple[str, int]:
    if len(argv) != 3:
        print(
            "Usage: run-stage2-rewrite-cb.py <toml-path> <new-cb-budget>",
            file=sys.stderr,
        )
        sys.exit(2)
    path = argv[1]
    raw = argv[2]
    try:
        new_cb = int(raw)
    except ValueError:
        print(
            f"run-stage2-rewrite-cb: cb_budget must be an integer (got: {raw!r})",
            file=sys.stderr,
        )
        sys.exit(2)
    if new_cb < 0:
        print(
            f"run-stage2-rewrite-cb: cb_budget must be non-negative (got: {new_cb})",
            file=sys.stderr,
        )
        sys.exit(2)
    return path, new_cb


def validate_toml(path: str) -> None:
    try:
        import tomllib
    except ImportError:
        # Python < 3.11. Skip validation; the line rewrite below is
        # still safe because we only touch `cb_budget = <int>` lines.
        return
    try:
        with open(path, "rb") as f:
            tomllib.load(f)
    except OSError as exc:
        print(f"run-stage2-rewrite-cb: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    except tomllib.TOMLDecodeError as exc:
        print(
            f"run-stage2-rewrite-cb: malformed TOML at {path}: {exc}",
            file=sys.stderr,
        )
        sys.exit(1)


CB_LINE = re.compile(r"^(\s*)cb_budget(\s*)=(\s*)([0-9]+)(\s*)(#.*)?$")


def rewrite(path: str, new_cb: int) -> int:
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except OSError as exc:
        print(f"run-stage2-rewrite-cb: cannot read {path}: {exc}", file=sys.stderr)
        sys.exit(1)

    changed = 0
    out: list[str] = []
    for line in lines:
        # Preserve trailing newline (or its absence) untouched.
        if line.endswith("\n"):
            body = line[:-1]
            tail = "\n"
        else:
            body = line
            tail = ""
        m = CB_LINE.match(body)
        if m is None:
            out.append(line)
            continue
        lead, eq_pre, eq_post, _old, val_post, comment = m.groups()
        comment_part = comment if comment else ""
        if comment_part and not val_post:
            val_post = " "
        rebuilt = f"{lead}cb_budget{eq_pre}={eq_post}{new_cb}{val_post}{comment_part}{tail}"
        out.append(rebuilt)
        changed += 1

    try:
        with open(path, "w", encoding="utf-8") as f:
            f.writelines(out)
    except OSError as exc:
        print(f"run-stage2-rewrite-cb: cannot write {path}: {exc}", file=sys.stderr)
        sys.exit(1)
    return changed


def main() -> None:
    path, new_cb = parse_args(sys.argv)
    validate_toml(path)
    n = rewrite(path, new_cb)
    if n == 0:
        print(
            f"run-stage2-rewrite-cb: no cb_budget lines found in {path}",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
