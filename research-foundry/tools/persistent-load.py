#!/usr/bin/env python3
"""persistent-load.py - Host-side reader for cross-run persistent state.

Phase 5 PR-B of #626 (cross-run learning). Companion to
`persistent-snapshot.py` (PR-A) which writes `memo-snapshot.json` at
run end. This helper reads PR-A's snapshot plus PR-C's
`fittest_specialties.json` (NOT yet written by anything in-tree at
PR-B; the test suite seeds a synthetic fixture) so the `run-research.sh`
bootstrap can hot-start a federation with the previous run's confidence
floor and bias new explorer replicas toward fit specialties.

Subcommands:

  load-confidence <persistent-dir> <colony>
      Print the value of `<colony>:confidence` from
      `<persistent-dir>/memo-snapshot.json` to stdout. Print empty
      string (and exit 0) if the dir, file, or key is missing -- the
      shell caller falls back to the legacy 0.7 seed in that case.

  weighted-specialty-slots <persistent-dir> <colony-variants-json> <N>
      Print N specialty names (one per line) for the explorer spawn
      loop. If `<persistent-dir>/fittest_specialties.json` exists and
      lists ranked specialties, the top 60% (by avg_fitness) get
      floor(N * 0.8) slots round-robin and the remaining ceil(N * 0.2)
      slots are forced mutation drawn from the non-top specialties.
      If the file is missing or empty -> byte-identical round-robin
      over the colony's `explorer` variants from `colony-variants.json`.

Schemas:

    memo-snapshot.json -- written by persistent-snapshot.py:
        {
          "schema": 1,
          "snapshot_ts": "...",
          "container": "...",
          "keys": { "<memo key>": "<value>", ... }
        }

    fittest_specialties.json -- PR-C will populate this; PR-B reads it:
        {
          "schema": 1,
          "ranked": [
            {"specialty": "group_theory", "avg_fitness": 4.2, "runs_seen": 3},
            ...
          ]
        }

Pattern: heredoc-free Python helper following the precedent of
`persistent-snapshot.py` / `auto-promote-decisions.py` (extracted to
dodge the macOS bash 3.2 parser bug).

Usage:
    persistent-load.py load-confidence <persistent-dir> <colony>
    persistent-load.py weighted-specialty-slots <persistent-dir> <variants-json> <N>
    persistent-load.py --help
"""
import json
import math
import os
import sys


SCHEMA_VERSION = 1
TOP_FRACTION = 0.6
TOP_SLOT_RATIO = 0.8


def _print_help_and_exit():
    sys.stdout.write(__doc__ or "")
    sys.stdout.write("\n")
    sys.exit(0)


def _load_json(path):
    """Read and parse a JSON file. Returns None on any IO/parse error."""
    try:
        with open(path, "r") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _load_explorer_variants(variants_path, colony):
    """Read `colony-variants.json` and return the `variants` list for
    the given colony, or an empty list if the file/colony is missing.
    """
    data = _load_json(variants_path)
    if not isinstance(data, dict):
        return []
    colonies = data.get("colonies") or {}
    entry = colonies.get(colony) or {}
    variants = entry.get("variants") or []
    if isinstance(variants, list):
        return [str(v) for v in variants]
    return []


def cmd_load_confidence(argv):
    if len(argv) != 2:
        sys.stderr.write(
            "persistent-load: load-confidence requires <persistent-dir> <colony>\n"
        )
        return 2
    persistent_dir, colony = argv[0], argv[1]
    snapshot_path = os.path.join(persistent_dir, "memo-snapshot.json")
    data = _load_json(snapshot_path)
    if not isinstance(data, dict):
        return 0
    keys = data.get("keys") or {}
    if not isinstance(keys, dict):
        return 0
    key = colony + ":confidence"
    value = keys.get(key)
    if value is None or value == "":
        return 0
    sys.stdout.write(str(value))
    sys.stdout.write("\n")
    return 0


def _round_robin_slots(variants, n):
    """Round-robin over `variants` for N output slots. Falls back to
    `unassigned` if the list is empty.
    """
    if not variants:
        return ["unassigned"] * n
    out = []
    for i in range(n):
        out.append(variants[i % len(variants)])
    return out


def _bias_slots(variants, ranked_specialties, n):
    """Implements the 80/20 weighting algorithm:

    - Top 60% of `ranked_specialties` (sort-desc by avg_fitness, already
      sorted by caller) get floor(N * 0.8) round-robin slots.
    - Remaining ceil(N * 0.2) slots are forced mutation drawn from
      variants NOT in the top set.

    `variants` is the colony's full variant list (e.g. 5 specialties).
    `ranked_specialties` is the deduped sorted list of specialty names
    (top-of-list = highest fitness).

    Falls through to round-robin if the top set is empty after intersect.
    Forced-mutation slots round-robin over the bottom set; if no
    non-top variants exist, fall back to round-robin over the top set
    (defensive -- shouldn't happen when both lists have 5 entries).
    """
    if not variants or not ranked_specialties:
        return _round_robin_slots(variants, n)

    top_count = max(1, int(math.ceil(len(ranked_specialties) * TOP_FRACTION)))
    top_set_ordered = []
    seen = set()
    for sp in ranked_specialties[:top_count]:
        if sp in variants and sp not in seen:
            top_set_ordered.append(sp)
            seen.add(sp)
    if not top_set_ordered:
        return _round_robin_slots(variants, n)

    bottom_set_ordered = [v for v in variants if v not in seen]

    top_slot_count = int(math.floor(n * TOP_SLOT_RATIO))
    bottom_slot_count = n - top_slot_count

    out = []
    for i in range(top_slot_count):
        out.append(top_set_ordered[i % len(top_set_ordered)])
    for i in range(bottom_slot_count):
        if bottom_set_ordered:
            out.append(bottom_set_ordered[i % len(bottom_set_ordered)])
        else:
            out.append(top_set_ordered[i % len(top_set_ordered)])
    return out


def cmd_weighted_specialty_slots(argv):
    if len(argv) != 3:
        sys.stderr.write(
            "persistent-load: weighted-specialty-slots requires "
            "<persistent-dir> <colony-variants-json> <N>\n"
        )
        return 2
    persistent_dir, variants_path, n_str = argv[0], argv[1], argv[2]
    try:
        n = int(n_str)
    except ValueError:
        sys.stderr.write("persistent-load: N must be an integer, got '" + n_str + "'\n")
        return 2
    if n <= 0:
        return 0

    variants = _load_explorer_variants(variants_path, "explorer")

    fittest_path = os.path.join(persistent_dir, "fittest_specialties.json")
    fittest = _load_json(fittest_path)
    ranked = []
    if isinstance(fittest, dict):
        rows = fittest.get("ranked") or []
        if isinstance(rows, list):
            sortable = []
            for row in rows:
                if not isinstance(row, dict):
                    continue
                sp = row.get("specialty")
                if not isinstance(sp, str) or not sp:
                    continue
                try:
                    af = float(row.get("avg_fitness", 0))
                except (TypeError, ValueError):
                    af = 0.0
                sortable.append((sp, af))
            sortable.sort(key=lambda r: r[1], reverse=True)
            seen = set()
            for sp, _ in sortable:
                if sp in seen:
                    continue
                seen.add(sp)
                ranked.append(sp)

    if ranked:
        slots = _bias_slots(variants, ranked, n)
    else:
        slots = _round_robin_slots(variants, n)

    for s in slots:
        sys.stdout.write(s + "\n")
    return 0


def main(argv):
    if not argv:
        _print_help_and_exit()
    cmd = argv[0]
    if cmd in ("-h", "--help"):
        _print_help_and_exit()
    rest = argv[1:]
    if cmd == "load-confidence":
        return cmd_load_confidence(rest)
    if cmd == "weighted-specialty-slots":
        return cmd_weighted_specialty_slots(rest)
    sys.stderr.write("persistent-load: unknown subcommand: " + cmd + "\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
