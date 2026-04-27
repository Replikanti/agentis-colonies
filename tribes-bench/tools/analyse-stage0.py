#!/usr/bin/env python3
"""Stage 0 telemetry analyser for tribes-bench (#363).

Reads the per-agent JSONL state under `runs/<ts>/.agentis/` and joins by
tribe (= colony name) and minute bucket. Emits
`runs/<ts>/telemetry.csv` with columns:

    minute, tribe, agents_alive, cb_balance, findings_emitted,
    true_positives, false_positives

Inputs (each optional — every column degrades to 0 when its source file
is missing, so the CSV always has a header + at least one data row):

  .agentis/daemon/<agent_id>.colony     plain text, tribe name
  .agentis/experience/<agent_id>.jsonl  learn() rows with tags
  .agentis/spend/<agent_id>.jsonl       prompt() spend rows with cb
  .agentis/lifecycle/events.jsonl       optional, used to widen the
                                         per-minute window when present

Stage 0 deliberately reads the structured per-agent state instead of
lifecycle/events.jsonl alone — `telemetry.enabled` does not synthesise
events.jsonl on a freshly-initialised root, but spend/experience write
unconditionally, so the analyser stays robust on a hermetic per-run
.agentis tree.

Usage:
    analyse-stage0.py <runs/<ts> path>

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
        print("Usage: analyse-stage0.py <run-dir>", file=sys.stderr)
        sys.exit(2)
    run_dir = argv[1]
    if not os.path.isdir(run_dir):
        print(f"analyse-stage0: run dir not found: {run_dir}", file=sys.stderr)
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


def main() -> None:
    run_dir = parse_args(sys.argv)
    agentis_root = os.path.join(run_dir, ".agentis")
    daemon_dir = os.path.join(agentis_root, "daemon")
    experience_dir = os.path.join(agentis_root, "experience")
    spend_dir = os.path.join(agentis_root, "spend")

    agent_to_tribe = load_agent_to_tribe(daemon_dir)

    # Per-minute aggregations, keyed by (minute, tribe).
    findings_by: dict[tuple[int, str], int] = defaultdict(int)
    tp_by: dict[tuple[int, str], int] = defaultdict(int)
    fp_by: dict[tuple[int, str], int] = defaultdict(int)
    cb_by: dict[tuple[int, str], int] = defaultdict(int)
    alive_minutes: dict[str, set[int]] = defaultdict(set)
    tribe_to_agents: dict[str, set[str]] = defaultdict(set)
    for agent_id, tribe in agent_to_tribe.items():
        tribe_to_agents[tribe].add(agent_id)

    # --- Experience rows: findings + verdict tags ---
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
                if "false-positive" in tags:
                    fp_by[key] += 1

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
        ])

        # Always emit at least one row per known tribe so consumers
        # don't choke on a header-only CSV.
        known_tribes = sorted(set(agent_to_tribe.values()) | {"tribe-alpha", "tribe-beta"})
        if not all_minutes:
            for tribe in known_tribes:
                w.writerow([0, tribe, 0, 0, 0, 0, 0])
            print(out_path)
            return

        min_minute = min(all_minutes)
        max_minute = max(all_minutes)

        tribes = sorted(set(agent_to_tribe.values()) | set(tribe_to_agents.keys()) | {"tribe-alpha", "tribe-beta"})

        for minute in range(min_minute, max_minute + 1):
            for tribe in tribes:
                agents = tribe_to_agents.get(tribe, set())
                alive = sum(1 for a in agents if minute in alive_minutes.get(a, set()))
                key = (minute, tribe)
                w.writerow([
                    minute,
                    tribe,
                    alive,
                    cb_by.get(key, 0),
                    findings_by.get(key, 0),
                    tp_by.get(key, 0),
                    fp_by.get(key, 0),
                ])

    print(out_path)


if __name__ == "__main__":
    main()
