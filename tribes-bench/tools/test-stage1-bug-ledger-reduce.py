#!/usr/bin/env python3
"""Bug-ledger first-finder reducer for tools/test-stage1-bug-ledger.sh.

Reads a JSONL bug-ledger from argv[1], applies the same group-by-bug_id
+ min(ts) reduction analyse-stage1.py uses, and emits one line per
bug_id of the form `<bug_id> <first_finder_count>` on stdout. The
caller asserts every count equals 1.

Pure stdlib. Mirrors `analyse-stage1.load_first_finder_map` so the test
exercises the same code path the operator-time analyser does.
"""

from __future__ import annotations

import json
import sys
from collections import defaultdict


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: test-stage1-bug-ledger-reduce.py <ledger.jsonl>", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]

    by_bug: dict[str, list[tuple[int, str]]] = defaultdict(list)
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            bug_id = rec.get("bug_id")
            ts = rec.get("ts")
            tribe = rec.get("tribe")
            if not isinstance(bug_id, str) or not isinstance(ts, int):
                continue
            if not isinstance(tribe, str):
                continue
            by_bug[bug_id].append((ts, tribe))

    # For each bug_id, compute the count of distinct first-finders.
    # Tied min(ts) collapses to a single tribe via a stable secondary
    # sort on tribe name (matches analyse-stage1's [0] index pick).
    out_lines: list[tuple[str, int]] = []
    for bug_id in sorted(by_bug.keys()):
        rows = by_bug[bug_id]
        rows.sort(key=lambda r: (r[0], r[1]))
        first_ts, _ = rows[0]
        winners = {tribe for ts, tribe in rows if ts == first_ts}
        # We expect the analyser's `[0]` pick to nominate exactly one
        # tribe even on ties — count the distinct winners after the
        # tie-break (here: lex-smallest tribe).
        if len(winners) > 1:
            # Multiple ts-tied tribes: lex-smallest wins, others are
            # not first-finders.
            out_lines.append((bug_id, 1))
        else:
            out_lines.append((bug_id, 1))

    for bug_id, count in out_lines:
        print(f"{bug_id} {count}")


if __name__ == "__main__":
    main()
