#!/usr/bin/env python3
"""Stage 2 telemetry analyser for tribes-bench (#392, M1).

Sibling of `analyse-stage1.py` — does NOT replace it. The Stage 0/1
analysers are byte-identical to their tagged versions; Stage 2 adds
this distinct script so the federation can grow to 5 tribes (alpha,
beta, gamma, delta, epsilon) without touching the Stage 0/1 surface.

Same 12-column schema as Stage 1 — the wire format is stable across
stages. The two behavioural differences vs `analyse-stage1.py` are:
(1) the bug-class lookup reads `targets/stage2/bugs.json`; (2) the
always-emit fallback derives the known-tribe set from the per-run
experience/spend data union with the federation directory layout, not
a hard-coded 3-tribe list (so a 5-, 6-, or 7-tribe run all work
without code change).

Schema:

    minute, tribe, agents_alive, cb_balance,
    findings_emitted, true_positives, false_positives,
    bug_class, is_first_finder, tribe_size,
    replication_event_count, tribe_death_ts

Sources:

    .agentis/daemon/<agent_id>.colony     plain text, tribe name
    .agentis/experience/<agent_id>.jsonl  learn() rows with tags
    .agentis/spend/<agent_id>.jsonl       prompt() spend rows with cb
    <fed>/targets/stage2/bugs.json        manifest for bug_id -> class lookup
    <run-dir>/bug-ledger.jsonl            shared ledger; first-finder
                                         determined post-hoc by min(ts)
                                         per bug_id, sidestepping the
                                         in-band race documented in
                                         the #364 M3 plan §7.

`is_first_finder` is populated from bug-ledger.jsonl: per-bug-id we
sort the rows by ts and the lowest-ts tribe gets is_first_finder=1 in
the row's minute bucket. `tribe_size` is the count of distinct alive
agent_ids per (minute, tribe) (bumped by replicate()-driven daemon
spawns). `replication_event_count` counts experience rows tagged
`replicated`. `tribe_death_ts` is sticky from the minute the
`died`-tagged row appears onward.

Usage:
    analyse-stage2.py <runs/<ts> path>

Pure stdlib. No extra deps.
"""

from __future__ import annotations

import csv
import json
import os
import sys
from collections import defaultdict
from typing import Any


def parse_args(argv: list[str]) -> str:
    if len(argv) != 2:
        print("Usage: analyse-stage2.py <run-dir>", file=sys.stderr)
        sys.exit(2)
    run_dir = argv[1]
    if not os.path.isdir(run_dir):
        print(f"analyse-stage2: run dir not found: {run_dir}", file=sys.stderr)
        sys.exit(2)
    return run_dir


def load_agent_to_tribe(daemon_dir: str) -> dict[str, str]:
    """Map every agent_id under .agentis/daemon/ to the tribe name in
    the matching `<id>.colony` file.
    """
    out: dict[str, str] = {}
    if not os.path.isdir(daemon_dir):
        return out
    for fname in os.listdir(daemon_dir):
        if not fname.endswith(".colony"):
            continue
        agent_id = fname[: -len(".colony")]
        path = os.path.join(daemon_dir, fname)
        try:
            with open(path, encoding="utf-8") as f:
                tribe = f.read().strip()
        except OSError:
            continue
        if tribe:
            out[agent_id] = tribe
    return out


def read_jsonl(path: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return out


def minute_of(ts_s: int) -> int:
    return ts_s // 60


def load_bug_class_map(fed_dir: str) -> dict[str, str]:
    """Build {bug_id -> class} from targets/stage2/bugs.json. Returns an
    empty map if the manifest is missing or unparseable so the analyser
    degrades cleanly to bug_class = "" everywhere.
    """
    manifest_path = os.path.join(fed_dir, "targets", "stage2", "bugs.json")
    if not os.path.isfile(manifest_path):
        return {}
    try:
        with open(manifest_path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    bugs = data.get("bugs", []) if isinstance(data, dict) else []
    out: dict[str, str] = {}
    for b in bugs:
        if not isinstance(b, dict):
            continue
        bug_id = b.get("id")
        cls = b.get("class")
        if isinstance(bug_id, str) and isinstance(cls, str):
            out[bug_id] = cls
    return out


def load_first_finder_map(run_dir: str) -> dict[str, tuple[str, int]]:
    """Read bug-ledger.jsonl, group by bug_id, return {bug_id -> (tribe,
    minute)} where (tribe, minute) is the first-finder tribe + the minute
    of the lowest-ts row for that bug_id. Empty map when the ledger is
    missing.
    """
    path = os.path.join(run_dir, "bug-ledger.jsonl")
    if not os.path.isfile(path):
        return {}
    by_bug: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for rec in read_jsonl(path):
        bug_id = rec.get("bug_id")
        ts_ms = rec.get("ts")
        tribe = rec.get("tribe")
        if not isinstance(bug_id, str) or not isinstance(ts_ms, int):
            continue
        if not isinstance(tribe, str):
            continue
        by_bug[bug_id].append((ts_ms, tribe))
    out: dict[str, tuple[str, int]] = {}
    for bug_id, rows in by_bug.items():
        rows.sort(key=lambda r: r[0])
        ts_ms, tribe = rows[0]
        out[bug_id] = (tribe, minute_of(ts_ms // 1000))
    return out


def discover_known_tribes(fed_dir: str) -> set[str]:
    """Return the set of tribe-* directories under fed_dir. Used as the
    always-emit fallback so an N-tribe run produces an N-row CSV even
    when no telemetry was recorded. Avoids hardcoding the per-stage
    tribe count.
    """
    out: set[str] = set()
    if not os.path.isdir(fed_dir):
        return out
    for name in os.listdir(fed_dir):
        if name.startswith("tribe-") and os.path.isdir(os.path.join(fed_dir, name)):
            out.add(name)
    return out


def main() -> None:
    run_dir = parse_args(sys.argv)
    agentis_root = os.path.join(run_dir, ".agentis")
    daemon_dir = os.path.join(agentis_root, "daemon")
    experience_dir = os.path.join(agentis_root, "experience")
    spend_dir = os.path.join(agentis_root, "spend")

    # Resolve federation dir for the bug-class lookup. The run-dir
    # convention places runs/<ts>/ under <fed>/runs/, so two os.path.dirname
    # calls reach <fed>. Fall back to empty map if the structure is
    # different (the analyser still works, bug_class just stays "").
    fed_dir = os.path.dirname(os.path.dirname(os.path.abspath(run_dir)))
    bug_class_map = load_bug_class_map(fed_dir)
    first_finder_map = load_first_finder_map(run_dir)
    known_tribes_fs = discover_known_tribes(fed_dir)

    agent_to_tribe = load_agent_to_tribe(daemon_dir)

    # Per-minute aggregations, keyed by (minute, tribe).
    findings_by: dict[tuple[int, str], int] = defaultdict(int)
    tp_by: dict[tuple[int, str], int] = defaultdict(int)
    fp_by: dict[tuple[int, str], int] = defaultdict(int)
    cb_by: dict[tuple[int, str], int] = defaultdict(int)
    classes_by: dict[tuple[int, str], set[str]] = defaultdict(set)
    first_finder_by: dict[tuple[int, str], int] = defaultdict(int)
    replication_by: dict[tuple[int, str], int] = defaultdict(int)
    death_minute_by: dict[str, int] = {}
    death_ts_ms_by: dict[str, int] = {}
    alive_minutes: dict[str, set[int]] = defaultdict(set)
    tribe_to_agents: dict[str, set[str]] = defaultdict(set)
    for agent_id, tribe in agent_to_tribe.items():
        tribe_to_agents[tribe].add(agent_id)

    # --- Experience rows: findings + verdict tags + bug_class lookup ---
    if os.path.isdir(experience_dir):
        for fname in sorted(os.listdir(experience_dir)):
            if not fname.endswith(".jsonl"):
                continue
            agent_id = fname[: -len(".jsonl")]
            tribe = agent_to_tribe.get(agent_id)
            for rec in read_jsonl(os.path.join(experience_dir, fname)):
                tags = rec.get("tags") or []
                if not isinstance(tags, list):
                    tags = []
                if "tribes-bench" not in tags:
                    continue
                ts_ms = rec.get("ts")
                if not isinstance(ts_ms, int):
                    continue
                ts_s = ts_ms // 1000
                minute = minute_of(ts_s)
                if tribe is None:
                    # Unknown agent — fall back to a synthetic "unknown"
                    # bucket so we never drop a row, but record the
                    # agent in the tribe-list at the end too.
                    tribe = "unknown"
                tribe_to_agents[tribe].add(agent_id)
                alive_minutes[agent_id].add(minute)
                key = (minute, tribe)
                if any(t in tags for t in ("acted", "false-positive", "observed", "review-gated")):
                    findings_by[key] += 1
                if "acted" in tags:
                    tp_by[key] += 1
                    # The hunter records the verifier's bug_id in the
                    # `outcome` field for verified findings; map it to a
                    # class via the manifest. Misses are silent.
                    outcome = rec.get("outcome")
                    if isinstance(outcome, str):
                        cls = bug_class_map.get(outcome)
                        if cls:
                            classes_by[key].add(cls)
                        # First-finder check: if this tribe was the
                        # bug-ledger first-finder for this bug_id and
                        # this is the matching minute, bump the column.
                        ff = first_finder_map.get(outcome)
                        if ff is not None:
                            ff_tribe, ff_minute = ff
                            if ff_tribe == tribe and minute == ff_minute:
                                first_finder_by[key] += 1
                if "false-positive" in tags:
                    fp_by[key] += 1
                if "replicated" in tags:
                    replication_by[key] += 1
                if "died" in tags:
                    if tribe not in death_ts_ms_by or ts_ms < death_ts_ms_by[tribe]:
                        death_ts_ms_by[tribe] = ts_ms
                        death_minute_by[tribe] = minute

    # --- Spend rows: cb per row, by colony field ---
    if os.path.isdir(spend_dir):
        for fname in sorted(os.listdir(spend_dir)):
            if not fname.endswith(".jsonl"):
                continue
            agent_id = fname[: -len(".jsonl")]
            for rec in read_jsonl(os.path.join(spend_dir, fname)):
                ts_ms = rec.get("ts")
                cb = rec.get("cb")
                tribe = rec.get("colony") or agent_to_tribe.get(agent_id)
                if not isinstance(ts_ms, int) or not isinstance(cb, int):
                    continue
                if not isinstance(tribe, str) or not tribe:
                    continue
                minute = minute_of(ts_ms // 1000)
                tribe_to_agents[tribe].add(agent_id)
                alive_minutes[agent_id].add(minute)
                cb_by[(minute, tribe)] += cb

    # --- Determine the time window ---
    all_minutes: set[int] = set()
    for k in findings_by:
        all_minutes.add(k[0])
    for k in cb_by:
        all_minutes.add(k[0])
    for s in alive_minutes.values():
        all_minutes.update(s)

    out_path = os.path.join(run_dir, "telemetry.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "minute", "tribe", "agents_alive", "cb_balance",
            "findings_emitted", "true_positives", "false_positives",
            "bug_class", "is_first_finder", "tribe_size",
            "replication_event_count", "tribe_death_ts",
        ])

        # Always emit at least one row per known tribe so consumers
        # don't choke on a header-only CSV. The known-tribe set is the
        # union of (a) tribes actually observed in the run's telemetry
        # and (b) tribe-* directories on disk under the federation dir.
        # Falls back to the Stage 1 trio when neither is available so
        # the analyser stays useful when invoked outside the federation
        # tree.
        fs_or_default = known_tribes_fs or {
            "tribe-alpha", "tribe-beta", "tribe-gamma",
        }
        known_tribes = sorted(set(agent_to_tribe.values()) | fs_or_default)
        if not all_minutes:
            for tribe in known_tribes:
                w.writerow([0, tribe, 0, 0, 0, 0, 0, "", 0, 0, 0, ""])
            print(out_path)
            return

        min_minute = min(all_minutes)
        max_minute = max(all_minutes)

        tribes = sorted(
            set(agent_to_tribe.values())
            | set(tribe_to_agents.keys())
            | fs_or_default
        )

        for minute in range(min_minute, max_minute + 1):
            for tribe in tribes:
                agents = tribe_to_agents.get(tribe, set())
                alive = sum(1 for a in agents if minute in alive_minutes.get(a, set()))
                key = (minute, tribe)
                bug_class = ",".join(sorted(classes_by.get(key, set())))
                # Sticky death timestamp: when a `died`-tagged row is
                # observed in some minute m for `tribe`, every minute >= m
                # carries that timestamp.
                death_ts_str = ""
                d_minute = death_minute_by.get(tribe)
                if d_minute is not None and minute >= d_minute:
                    death_ts_str = str(death_ts_ms_by.get(tribe, ""))
                w.writerow([
                    minute,
                    tribe,
                    alive,
                    cb_by.get(key, 0),
                    findings_by.get(key, 0),
                    tp_by.get(key, 0),
                    fp_by.get(key, 0),
                    bug_class,
                    first_finder_by.get(key, 0),
                    alive,
                    replication_by.get(key, 0),
                    death_ts_str,
                ])

    print(out_path)


if __name__ == "__main__":
    main()
