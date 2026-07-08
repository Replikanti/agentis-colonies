#!/usr/bin/env python3
"""Retire priority-contaminated crystallized rules by de-registering them (#1478).

Reads the JSONL that `priority-rule-audit.py --json` emits (one contaminated
rule per line + a trailing `_summary` object) on stdin, and RETIRES each
flagged rule from the live pool by removing its entry from the on-disk
crystallizer state:

  - drop the rule's line from `_crystallizer_index/<action_type>.jsonl`
    (the topic index agentis-core walks on load), which de-registers the
    rule from every lookup / BM25 recall path, and
  - remove its `_crystallizer_telemetry/<rule_id>.jsonl` fitness sidecar.

The content-addressed object under `.agentis/objects/` is immutable and left
in place; once un-indexed it is unreferenced and inert (no lookup, no recall,
no re-distill reads its raw action), and the clean decision re-crystallizes
from post-#1474 verdicts on the daemons' next pass. This is the "retire so it
re-crystallizes cleanly" mechanism from #1478 — chosen over an in-place
action rewrite because content-addressed rule objects cannot be edited
without changing their id.

Dry-run by default: prints exactly what WOULD be removed and touches nothing.
`--apply` performs the removals, writing a timestamp-free `.bak` of each
mutated index file first (overwritten on a re-run; the pool itself is the
source of truth).

Exit codes: 0 ok (including nothing-to-do), 1 bad knowledge dir.
"""

import argparse
import json
import os
import shutil
import sys


def _read_flagged(stream):
    """Parse the audit --json stream into {action_type: set(rule_id)}."""
    by_class = {}
    ids = set()
    for line in stream:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(obj, dict) or obj.get("_summary"):
            continue
        rid = obj.get("rule_id")
        cls = obj.get("action_type")
        if not rid or not cls:
            continue
        by_class.setdefault(cls, set()).add(rid)
        ids.add(rid)
    return by_class, ids


def _rewrite_index(index_path, drop_ids, apply):
    """Drop rows whose rule_id is in drop_ids. Returns removed line count."""
    if not os.path.isfile(index_path):
        return 0
    kept = []
    removed = 0
    try:
        with open(index_path) as f:
            for raw in f:
                stripped = raw.strip()
                if not stripped:
                    kept.append(raw)
                    continue
                try:
                    row = json.loads(stripped)
                except json.JSONDecodeError:
                    kept.append(raw)
                    continue
                if isinstance(row, dict) and row.get("rule_id") in drop_ids:
                    removed += 1
                    continue
                kept.append(raw)
    except OSError:
        return 0
    if removed and apply:
        shutil.copyfile(index_path, index_path + ".bak")
        tmp = index_path + ".tmp"
        with open(tmp, "w") as f:
            for line in kept:
                if not line.endswith("\n"):
                    line += "\n"
                f.write(line)
        os.replace(tmp, index_path)
    return removed


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Retire priority-contaminated crystallized rules (#1478).")
    ap.add_argument("--knowledge-dir", required=True,
                    help="<fed>/.agentis/knowledge directory")
    ap.add_argument("--apply", action="store_true",
                    help="perform the removals (default: dry-run)")
    args = ap.parse_args(argv)

    index_dir = os.path.join(args.knowledge_dir, "_crystallizer_index")
    tel_dir = os.path.join(args.knowledge_dir, "_crystallizer_telemetry")
    if not os.path.isdir(index_dir):
        sys.stderr.write("priority-rule-purge: no _crystallizer_index under %s\n"
                         % args.knowledge_dir)
        return 1

    by_class, all_ids = _read_flagged(sys.stdin)
    mode = "APPLY" if args.apply else "DRY-RUN"
    if not all_ids:
        print("priority-rule-purge [%s]: nothing to retire (0 contaminated rules)." % mode)
        return 0

    total_index_removed = 0
    total_tel_removed = 0
    for cls, ids in sorted(by_class.items()):
        index_path = os.path.join(index_dir, cls + ".jsonl")
        removed = _rewrite_index(index_path, ids, args.apply)
        total_index_removed += removed
        verb = "de-registered" if args.apply else "would de-register"
        print("priority-rule-purge [%s]: class '%s' — %s %d rule(s) from %s.jsonl:"
              % (mode, cls, verb, len(ids), cls))
        for rid in sorted(ids):
            print("    - " + rid)
            tel_path = os.path.join(tel_dir, rid + ".jsonl")
            if os.path.isfile(tel_path):
                total_tel_removed += 1
                if args.apply:
                    try:
                        os.remove(tel_path)
                    except OSError:
                        pass

    print("")
    if args.apply:
        print("priority-rule-purge [APPLY]: retired %d index entr(ies), removed %d telemetry sidecar(s)."
              % (total_index_removed, total_tel_removed))
        print("  Restart the triage daemons so the pool reloads without the retired rules.")
        print("  Clean decisions re-crystallize from post-#1474 verdicts on the next pass.")
    else:
        print("priority-rule-purge [DRY-RUN]: would retire %d index entr(ies) and %d telemetry sidecar(s)."
              % (total_index_removed, total_tel_removed))
        print("  Re-run with --apply to perform the retirement (stop the federation first).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
