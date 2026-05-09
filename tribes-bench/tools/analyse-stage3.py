#!/usr/bin/env python3
"""Stage 3 multinode telemetry + lineage analyser for tribes-bench (#439).

Aggregates the artefacts left by `run-stage3-multinode.sh` into a single
operator-readable bundle:

    telemetry-combined.csv   Stage 2 telemetry schema + a `node` column
                             (laptop or server). Rows from every node
                             are stitched into one time-ordered table.
    lineage.json             Parent -> child agent tree built from the
                             `replicate()`-driven `learn(..., success,
                             [..., "replicated", ...])` rows in each
                             agent's `.agentis/experience/<id>.jsonl`.
                             Single-node runs with no replicates emit a
                             tree with 5 root entries (one per seed
                             tribe) and empty children arrays.
    survivor-analysis.csv    One row per root lineage. Surfaces the
                             `unauthored_specialist` flag (true when any
                             descendant has `prompt_variant != root` AND
                             its tps > root tps) per Stage 3 success
                             criterion in #439.
    mutation-diff.csv        One row per replicate event. Records the
                             `parent_variant -> child_variant` pair plus
                             a `mutation_kind` derived from the
                             `pick_variant(tribe, n)` cycle in hunter.ag.
    comparison-stage3.md     Operator-readable summary mirroring the
                             Stage 2 comparison.md shape but with the
                             6 sections from this PR's plan: run shape,
                             findings volume, cost per verified bug,
                             replication dynamics, mutation outcomes,
                             knowledge-market activity.

Sources read by this analyser:

    <run-dir>/.agentis/                         laptop hermetic root
    <run-dir>/.agentis/experience/<id>.jsonl    laptop learn() rows
    <run-dir>/.agentis/daemon/<id>.colony       laptop tribe map
    <run-dir>/bug-ledger.jsonl                  laptop ledger
    <run-dir>/server-runs/<server-ts>/.agentis/ server hermetic root
    <run-dir>/server-runs/<server-ts>/bug-ledger.jsonl
    <run-dir>/rotations.csv                     target rotation events
    <run-dir>/run-meta.json                     run metadata
    <run-dir>/knowledge-market.csv              laptop market trades
    <run-dir>/server-runs/<server-ts>/knowledge-market.csv
                                                server market trades

Pure stdlib + a subprocess call to `analyse-stage2.py` per node so the
12-column Stage 2 telemetry schema stays the single source of truth.

Usage:
    analyse-stage3.py <run-dir> [--server-runs <subdir>] [--out <out-dir>]

Exit codes:
    0   ok
    1   bad args
    2   source files missing / unreadable
    3   schema violation in input data
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import subprocess
import sys
from collections import defaultdict
from typing import Any


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

# Reuse the Stage 2 schema lookups so the combined CSV column order
# matches Stage 2's telemetry.csv byte-for-byte (just with a `node`
# prefix column). Importing keeps this analyser pinned to the Stage 2
# schema without duplicating it.
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "analyse_stage2", os.path.join(SCRIPT_DIR, "analyse-stage2.py")
)
if _spec is None or _spec.loader is None:
    print("analyse-stage3: cannot locate analyse-stage2.py", file=sys.stderr)
    sys.exit(2)
analyse_stage2 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(analyse_stage2)  # type: ignore[union-attr]

read_jsonl = analyse_stage2.read_jsonl
load_agent_to_tribe = analyse_stage2.load_agent_to_tribe
load_agent_to_tribe_snapshot = analyse_stage2.load_agent_to_tribe_snapshot
load_market_log = analyse_stage2.load_market_log
MARKET_COLUMNS = analyse_stage2.MARKET_COLUMNS

TELEMETRY_COLUMNS = [
    "minute", "tribe", "agents_alive", "cb_balance",
    "findings_emitted", "true_positives", "false_positives",
    "bug_class", "is_first_finder", "tribe_size",
    "replication_event_count", "tribe_death_ts",
]

# pick_variant() in hunter.ag rotates over a 3-element cycle keyed by
# the tribe's current size. We re-implement it in Python so the
# analyser can compute parent/child variant-deltas without depending on
# the .ag scenario being available at analysis time.
VARIANT_CYCLE = (
    "format-pattern-default",
    "format-pattern-strict-literal",
    "format-pattern-broad-shellbuilder",
)


def pick_variant(tribe: str, n: int) -> str:
    """Mirror of hunter.ag::pick_variant. `tribe` is unused (the .ag
    helper takes the tribe name purely for symmetry with future
    per-tribe overrides). `n` is the tribe's size at replicate time."""
    _ = tribe
    return VARIANT_CYCLE[n % 3]


def parse_args(argv: list[str]) -> tuple[str, str, str, str]:
    """Parse argv into (run_dir, laptop_dir, server_runs_dir, out_dir).

    Defaults:
        --laptop-dir   <run-dir>                 (SSH multinode shape)
        --server-runs  <run-dir>/server-runs/    (SSH multinode shape)
        --out          <run-dir>/

    Docker (#478) shape: pass --laptop-dir <run-dir>/laptop-node and
    --server-runs <run-dir>/server-node. discover_server_node_dirs
    falls through to flat mode when the dir itself has .agentis/.

    Relative --server-runs / --laptop-dir paths are resolved relative
    to run_dir (not cwd) so the orchestrator can pass short names.
    """
    p = argparse.ArgumentParser(
        prog="analyse-stage3.py",
        description=(
            "Stitch Stage 3 multinode telemetry into a combined CSV "
            "plus lineage tree analysis (#439)."
        ),
    )
    p.add_argument("run_dir", help="Stage 3 run directory")
    p.add_argument(
        "--laptop-dir",
        default=None,
        help="laptop hermetic root (default: <run-dir>)",
    )
    p.add_argument(
        "--server-runs",
        default=None,
        help="server-runs/ subdir or flat server hermetic root "
             "(default: <run-dir>/server-runs)",
    )
    p.add_argument(
        "--out",
        default=None,
        help="output dir for stitched artefacts (default: <run-dir>)",
    )
    try:
        ns = p.parse_args(argv[1:])
    except SystemExit as e:
        # argparse exits 2 on usage errors; remap to 1 per the plan.
        if e.code == 2:
            sys.exit(1)
        raise
    run_dir = ns.run_dir
    if not os.path.isdir(run_dir):
        print(f"analyse-stage3: run dir not found: {run_dir}", file=sys.stderr)
        sys.exit(2)

    def _resolve(path: str | None, default_subdir: str) -> str:
        if path is None:
            return os.path.join(run_dir, default_subdir)
        return path if os.path.isabs(path) else os.path.join(run_dir, path)

    laptop_dir = ns.laptop_dir
    if laptop_dir is None:
        laptop_dir = run_dir
    elif not os.path.isabs(laptop_dir):
        laptop_dir = os.path.join(run_dir, laptop_dir)
    server_runs = _resolve(ns.server_runs, "server-runs")
    out_dir = ns.out or run_dir
    if not os.path.isdir(out_dir):
        try:
            os.makedirs(out_dir, exist_ok=True)
        except OSError as exc:
            print(f"analyse-stage3: cannot create out dir {out_dir}: {exc}", file=sys.stderr)
            sys.exit(2)
    return run_dir, laptop_dir, server_runs, out_dir


# --- Per-node telemetry -----------------------------------------------------

def discover_server_node_dirs(server_runs: str) -> list[str]:
    """Each server-runs subdir maps to one server node's hermetic
    .agentis/ tree. Returns a sorted list of full paths. Missing or
    empty server-runs/ -> empty list (single-node mode).

    Two shapes are supported:
      - SSH multinode: <server-runs>/<timestamp>/.agentis/
      - Docker (#478): <server-runs>/.agentis/ directly. Detected by
        the presence of .agentis/ inside server_runs itself; returns
        [server_runs] in that case.
    """
    if not os.path.isdir(server_runs):
        return []
    if os.path.isdir(os.path.join(server_runs, ".agentis")):
        return [server_runs]
    out: list[str] = []
    for name in sorted(os.listdir(server_runs)):
        sub = os.path.join(server_runs, name)
        if not os.path.isdir(sub):
            continue
        if os.path.isdir(os.path.join(sub, ".agentis")):
            out.append(sub)
    return out


def run_stage2_analyser(node_dir: str) -> list[list[str]]:
    """Invoke analyse-stage2.py on a node dir and return the
    telemetry.csv rows (header excluded). Subprocess so the Stage 2
    analyser owns the schema -- this analyser only stitches.

    Returns an empty list when the Stage 2 run fails or the CSV is
    missing; we do not abort the Stage 3 run on a single node's
    telemetry hiccup, the operator can re-run analyse-stage2.py
    standalone for diagnosis.
    """
    stage2 = os.path.join(SCRIPT_DIR, "analyse-stage2.py")
    if not os.path.isfile(stage2):
        return []
    try:
        subprocess.run(
            [sys.executable, stage2, node_dir],
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return []
    csv_path = os.path.join(node_dir, "telemetry.csv")
    if not os.path.isfile(csv_path):
        return []
    rows: list[list[str]] = []
    with open(csv_path, encoding="utf-8") as f:
        reader = csv.reader(f)
        header_seen = False
        for row in reader:
            if not row:
                continue
            if not header_seen and row and row[0] == "minute":
                header_seen = True
                continue
            rows.append(row)
    return rows


def write_combined_telemetry(
    out_dir: str,
    laptop_rows: list[list[str]],
    server_rows_by_node: list[list[list[str]]],
) -> str:
    """Stitch laptop + per-server-node telemetry into a single CSV with
    a leading `node` column. Time-order is by `minute` ascending; ties
    keep laptop rows ahead of server rows, then in original (tribe-
    sorted) order from each Stage 2 invocation.
    """
    out_path = os.path.join(out_dir, "telemetry-combined.csv")
    tagged: list[tuple[int, int, str, list[str]]] = []
    for i, row in enumerate(laptop_rows):
        try:
            m = int(row[0])
        except (ValueError, IndexError):
            m = 0
        tagged.append((m, 0, "laptop", row))
    for node_idx, node_rows in enumerate(server_rows_by_node, start=1):
        for j, row in enumerate(node_rows):
            try:
                m = int(row[0])
            except (ValueError, IndexError):
                m = 0
            tagged.append((m, node_idx, "server", row))
    tagged.sort(key=lambda t: (t[0], t[1]))
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["node"] + TELEMETRY_COLUMNS)
        for _m, _ni, node, row in tagged:
            # Pad / truncate defensively to the documented schema width.
            padded = row + [""] * max(0, len(TELEMETRY_COLUMNS) - len(row))
            padded = padded[: len(TELEMETRY_COLUMNS)]
            w.writerow([node] + padded)
    return out_path


# --- Lineage tree -----------------------------------------------------------

def _agent_birth_ts(experience_dir: str, agent_id: str) -> int:
    """Earliest ts (ms) on any tribes-bench-tagged learn row for the
    agent. Falls back to 0 when the agent has no rows (a freshly
    spawned daemon that died before its first prompt)."""
    path = os.path.join(experience_dir, f"{agent_id}.jsonl")
    earliest: int | None = None
    for rec in read_jsonl(path):
        ts = rec.get("ts")
        if not isinstance(ts, int):
            continue
        if earliest is None or ts < earliest:
            earliest = ts
    return earliest if earliest is not None else 0


def _agent_death_ts(experience_dir: str, agent_id: str) -> int | None:
    """Earliest ts (ms) on a `died`-tagged row, or None if the agent is
    still alive at run-end."""
    path = os.path.join(experience_dir, f"{agent_id}.jsonl")
    for rec in read_jsonl(path):
        tags = rec.get("tags") or []
        if not isinstance(tags, list):
            continue
        if "died" not in tags:
            continue
        ts = rec.get("ts")
        if isinstance(ts, int):
            return ts
    return None


def _agent_tps_fps(experience_dir: str, agent_id: str) -> tuple[int, int]:
    """Per-agent (tps, fps) totals from `acted` / `false-positive`
    tribes-bench rows."""
    path = os.path.join(experience_dir, f"{agent_id}.jsonl")
    tp = 0
    fp = 0
    for rec in read_jsonl(path):
        tags = rec.get("tags") or []
        if not isinstance(tags, list):
            continue
        if "tribes-bench" not in tags:
            continue
        if "acted" in tags:
            tp += 1
        if "false-positive" in tags:
            fp += 1
    return tp, fp


def _replicate_events(experience_dir: str, agent_id: str) -> list[dict[str, Any]]:
    """Per-agent successful replicate rows (tagged `replicated`),
    ordered by ts ascending."""
    path = os.path.join(experience_dir, f"{agent_id}.jsonl")
    out: list[dict[str, Any]] = []
    for rec in read_jsonl(path):
        tags = rec.get("tags") or []
        if not isinstance(tags, list):
            continue
        if "replicated" not in tags or "tribes-bench" not in tags:
            continue
        ts = rec.get("ts")
        if not isinstance(ts, int):
            continue
        out.append(rec)
    out.sort(key=lambda r: int(r.get("ts") or 0))
    return out


def _variant_from_tags(tags: list[Any]) -> str:
    """Extract a prompt_variant value from a learn() tag list. Tries
    `variant:<name>` and bare-name match against VARIANT_CYCLE so the
    analyser stays compatible with both the legacy hunter.ag (no
    variant tag) and the post-#447 form that includes it."""
    for t in tags:
        if not isinstance(t, str):
            continue
        if t.startswith("variant:"):
            return t.split(":", 1)[1]
        if t in VARIANT_CYCLE:
            return t
    return ""


def collect_node_agents(node_root: str, node_label: str) -> dict[str, dict[str, Any]]:
    """Build a per-agent dict keyed by agent_id, populated with
    (tribe, node, born_ts, died_ts, tps, fps, replicate_events). The
    parent_id and prompt_variant fields are filled in by
    build_lineage_tree() once the global agent inventory is known.
    """
    agentis_root = os.path.join(node_root, ".agentis")
    daemon_dir = os.path.join(agentis_root, "daemon")
    experience_dir = os.path.join(agentis_root, "experience")
    snapshot = load_agent_to_tribe_snapshot(node_root)
    agent_to_tribe = snapshot if snapshot else load_agent_to_tribe(daemon_dir)
    out: dict[str, dict[str, Any]] = {}
    for agent_id, tribe in agent_to_tribe.items():
        born = _agent_birth_ts(experience_dir, agent_id)
        died = _agent_death_ts(experience_dir, agent_id)
        tps, fps = _agent_tps_fps(experience_dir, agent_id)
        rep_events = _replicate_events(experience_dir, agent_id)
        out[agent_id] = {
            "agent_id": agent_id,
            "tribe": tribe,
            "node": node_label,
            "born_ts": born,
            "died_ts": died,
            "tps_total": tps,
            "fps_total": fps,
            "_replicate_events": rep_events,
        }
    # Ensure every JSONL author appears in the inventory even when the
    # daemon snapshot lost their .colony entry (the post-kill cleanup
    # in #416 catches most cases but not all).
    if os.path.isdir(experience_dir):
        for fname in os.listdir(experience_dir):
            if not fname.endswith(".jsonl"):
                continue
            agent_id = fname[: -len(".jsonl")]
            if agent_id in out:
                continue
            tribe = ""
            for rec in read_jsonl(os.path.join(experience_dir, fname)):
                tags = rec.get("tags") or []
                if not isinstance(tags, list):
                    continue
                for t in tags:
                    if isinstance(t, str) and t.startswith("tribe-"):
                        tribe = t
                        break
                if tribe:
                    break
            born = _agent_birth_ts(experience_dir, agent_id)
            died = _agent_death_ts(experience_dir, agent_id)
            tps, fps = _agent_tps_fps(experience_dir, agent_id)
            rep_events = _replicate_events(experience_dir, agent_id)
            out[agent_id] = {
                "agent_id": agent_id,
                "tribe": tribe,
                "node": node_label,
                "born_ts": born,
                "died_ts": died,
                "tps_total": tps,
                "fps_total": fps,
                "_replicate_events": rep_events,
            }
    return out


def _link_parents(agents: dict[str, dict[str, Any]]) -> list[dict[str, Any]]:
    """Walk every agent's per-tribe replicate event list and link each
    Nth replicate event (for tribe T) to the (N+1)th-born agent in
    that tribe. The first agent in each tribe (lowest born_ts) is the
    seed root with parent_id = None.

    Returns the ordered list of replicate events as dicts:
        {ts, parent_id, child_id, tribe, parent_variant, child_variant}
    used downstream by mutation-diff.csv.
    """
    by_tribe: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for a in agents.values():
        if a["tribe"]:
            by_tribe[a["tribe"]].append(a)
    for tribe, lst in by_tribe.items():
        lst.sort(key=lambda x: (x["born_ts"], x["agent_id"]))
        # Root: first agent.
        for idx, a in enumerate(lst):
            a["_birth_index"] = idx
            a["prompt_variant"] = pick_variant(tribe, idx)
            if idx == 0:
                a["parent_id"] = None
            else:
                a["parent_id"] = None  # filled below if a matching event exists
    # Collect every replicate event in this node's agents, sort by ts,
    # and assign each to the next un-parented child in its tribe.
    events_out: list[dict[str, Any]] = []
    pending_children: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for tribe, lst in by_tribe.items():
        # Slot 0 is the seed root; slots 1.. are the descendants in birth order.
        for child in lst[1:]:
            pending_children[tribe].append(child)
    # Aggregate parent rows in temporal order.
    parent_rows: list[tuple[int, dict[str, Any], dict[str, Any]]] = []
    for a in agents.values():
        for rec in a.get("_replicate_events", []):
            ts = int(rec.get("ts") or 0)
            parent_rows.append((ts, a, rec))
    parent_rows.sort(key=lambda t: (t[0], t[1]["agent_id"]))
    for ts, parent, rec in parent_rows:
        tribe = parent["tribe"]
        if not tribe:
            continue
        children = pending_children.get(tribe, [])
        if not children:
            # No more un-parented children -- record the event with an
            # unresolved child for mutation-diff anyway.
            tags = rec.get("tags") or []
            tag_variant = _variant_from_tags(tags) if isinstance(tags, list) else ""
            events_out.append({
                "ts": ts,
                "parent_id": parent["agent_id"],
                "child_id": "",
                "tribe": tribe,
                "parent_variant": parent.get("prompt_variant", ""),
                "child_variant": tag_variant,
            })
            continue
        child = children.pop(0)
        child["parent_id"] = parent["agent_id"]
        # Prefer the variant tagged on the replicate row when present
        # (post-#447 hunter.ag). Fall back to the deterministic
        # pick_variant() rotation when the legacy hunter.ag emitted no
        # variant tag.
        tags = rec.get("tags") or []
        tag_variant = _variant_from_tags(tags) if isinstance(tags, list) else ""
        if tag_variant:
            child["prompt_variant"] = tag_variant
        events_out.append({
            "ts": ts,
            "parent_id": parent["agent_id"],
            "child_id": child["agent_id"],
            "tribe": tribe,
            "parent_variant": parent.get("prompt_variant", ""),
            "child_variant": child.get("prompt_variant", ""),
        })
    return events_out


def build_lineage(agents: dict[str, dict[str, Any]]) -> tuple[
    list[dict[str, Any]], list[dict[str, Any]]
]:
    """Return (lineage_roots, replicate_events).

    `lineage_roots` is a list of dicts in the schema documented in the
    PR header: one dict per root, with `children` recursively nested.
    `replicate_events` is the parent->child event list used by
    mutation-diff.csv.
    """
    events = _link_parents(agents)
    children_of: dict[str, list[str]] = defaultdict(list)
    for a in agents.values():
        if a.get("parent_id"):
            children_of[a["parent_id"]].append(a["agent_id"])
    for lst in children_of.values():
        lst.sort(key=lambda aid: (agents[aid]["born_ts"], aid))

    def to_node(aid: str) -> dict[str, Any]:
        a = agents[aid]
        return {
            "agent_id": a["agent_id"],
            "tribe": a["tribe"],
            "node": a["node"],
            "born_ts": a["born_ts"],
            "died_ts": a["died_ts"],
            "parent_id": a.get("parent_id"),
            "prompt_variant": a.get("prompt_variant", ""),
            "tps_total": a["tps_total"],
            "fps_total": a["fps_total"],
            "children": [to_node(c) for c in children_of.get(aid, [])],
        }

    roots = sorted(
        [a for a in agents.values() if not a.get("parent_id")],
        key=lambda a: (a["tribe"], a["born_ts"], a["agent_id"]),
    )
    return [to_node(r["agent_id"]) for r in roots], events


def write_lineage_json(out_dir: str, roots: list[dict[str, Any]]) -> str:
    out_path = os.path.join(out_dir, "lineage.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"roots": roots}, f, indent=2, sort_keys=False)
        f.write("\n")
    return out_path


# --- Survivor analysis ------------------------------------------------------

def _collect_descendants(node: dict[str, Any]) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for c in node.get("children", []):
        out.append(c)
        out.extend(_collect_descendants(c))
    return out


def write_survivor_analysis(out_dir: str, roots: list[dict[str, Any]]) -> str:
    out_path = os.path.join(out_dir, "survivor-analysis.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "lineage_id", "parent_id", "tribe", "prompt_variant",
            "node_count", "mean_tps_per_descendant",
            "outlived_parent", "unauthored_specialist",
        ])
        for root in roots:
            descendants = _collect_descendants(root)
            node_count = 1 + len(descendants)
            if descendants:
                mean_tps = sum(d["tps_total"] for d in descendants) / float(len(descendants))
            else:
                mean_tps = 0.0
            outlived = False
            parent_died = root.get("died_ts")
            if parent_died is not None:
                for d in descendants:
                    d_died = d.get("died_ts")
                    if d_died is None or d_died > parent_died:
                        outlived = True
                        break
            unauthored = False
            root_variant = root.get("prompt_variant", "")
            root_tps = root.get("tps_total", 0)
            for d in descendants:
                if d.get("prompt_variant", "") != root_variant and d.get("tps_total", 0) > root_tps:
                    unauthored = True
                    break
            w.writerow([
                root["agent_id"],
                "",
                root["tribe"],
                root_variant,
                node_count,
                f"{mean_tps:.2f}",
                "true" if outlived else "false",
                "true" if unauthored else "false",
            ])
    return out_path


# --- Mutation diff ----------------------------------------------------------

def _mutation_kind(parent_variant: str, child_variant: str) -> str:
    if not parent_variant or not child_variant:
        return ""
    if parent_variant == child_variant:
        return "same"
    try:
        pi = VARIANT_CYCLE.index(parent_variant)
        ci = VARIANT_CYCLE.index(child_variant)
    except ValueError:
        return "other"
    delta = (ci - pi) % len(VARIANT_CYCLE)
    if delta == 0:
        return "same"
    return f"cycle-{delta}"


def write_mutation_diff(out_dir: str, events: list[dict[str, Any]]) -> str:
    out_path = os.path.join(out_dir, "mutation-diff.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "ts", "parent_id", "child_id", "tribe",
            "parent_variant", "child_variant", "mutation_kind",
        ])
        for ev in sorted(events, key=lambda e: int(e.get("ts") or 0)):
            w.writerow([
                ev.get("ts", 0),
                ev.get("parent_id", ""),
                ev.get("child_id", ""),
                ev.get("tribe", ""),
                ev.get("parent_variant", ""),
                ev.get("child_variant", ""),
                _mutation_kind(ev.get("parent_variant", ""), ev.get("child_variant", "")),
            ])
    return out_path


# --- Comparison report ------------------------------------------------------

def _read_run_meta(run_dir: str) -> dict[str, Any]:
    path = os.path.join(run_dir, "run-meta.json")
    if not os.path.isfile(path):
        return {}
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _read_rotations(run_dir: str) -> list[dict[str, str]]:
    path = os.path.join(run_dir, "rotations.csv")
    if not os.path.isfile(path):
        return []
    out: list[dict[str, str]] = []
    with open(path, encoding="utf-8") as f:
        reader = csv.DictReader(f)
        for r in reader:
            out.append(r)
    return out


def _aggregate_per_node(rows_by_node: dict[str, list[list[str]]]) -> dict[str, dict[str, int]]:
    """Per-node sums of findings/TPs/FPs/CB across all telemetry rows."""
    out: dict[str, dict[str, int]] = {}
    for node, rows in rows_by_node.items():
        tot_f = 0
        tot_tp = 0
        tot_fp = 0
        tot_cb = 0
        tribes: set[str] = set()
        for r in rows:
            r2 = r + [""] * max(0, len(TELEMETRY_COLUMNS) - len(r))
            try:
                tot_cb += int(r2[3] or 0)
                tot_f += int(r2[4] or 0)
                tot_tp += int(r2[5] or 0)
                tot_fp += int(r2[6] or 0)
            except ValueError:
                pass
            t = r2[1]
            if t:
                tribes.add(t)
        out[node] = {
            "findings": tot_f,
            "tps": tot_tp,
            "fps": tot_fp,
            "cb": tot_cb,
            "tribes": len(tribes),
        }
    return out


def write_comparison_md(
    out_dir: str,
    run_dir: str,
    rows_by_node: dict[str, list[list[str]]],
    rotations: list[dict[str, str]],
    roots: list[dict[str, Any]],
    events: list[dict[str, Any]],
    market_rows: list[dict[str, Any]],
    server_node_count: int,
) -> str:
    out_path = os.path.join(out_dir, "comparison-stage3.md")
    meta = _read_run_meta(run_dir)
    per_node = _aggregate_per_node(rows_by_node)
    laptop = per_node.get("laptop", {"findings": 0, "tps": 0, "fps": 0, "cb": 0, "tribes": 0})
    server = per_node.get("server", {"findings": 0, "tps": 0, "fps": 0, "cb": 0, "tribes": 0})
    total_f = laptop["findings"] + server["findings"]
    total_tp = laptop["tps"] + server["tps"]
    total_fp = laptop["fps"] + server["fps"]
    total_cb = laptop["cb"] + server["cb"]

    # Lineage stats.
    n_replicates = len(events)
    n_deaths = 0
    for root in roots:
        for n in [root] + _collect_descendants(root):
            if n.get("died_ts") is not None:
                n_deaths += 1
    n_lineages = len(roots)
    depth_max = 0
    depth_sum = 0
    depth_count = 0

    def _depth(n: dict[str, Any], d: int = 0) -> int:
        nonlocal depth_max, depth_sum, depth_count
        depth_max = max(depth_max, d)
        depth_sum += d
        depth_count += 1
        for c in n.get("children", []):
            _depth(c, d + 1)
        return d

    for root in roots:
        _depth(root, 0)
    depth_mean = (depth_sum / depth_count) if depth_count else 0.0

    # Mutation outcomes.
    mut_counts: dict[str, int] = defaultdict(int)
    for ev in events:
        mut_counts[_mutation_kind(ev.get("parent_variant", ""), ev.get("child_variant", ""))] += 1
    n_unauthored = 0
    for root in roots:
        descendants = _collect_descendants(root)
        rv = root.get("prompt_variant", "")
        rt = root.get("tps_total", 0)
        for d in descendants:
            if d.get("prompt_variant", "") != rv and d.get("tps_total", 0) > rt:
                n_unauthored += 1
                break

    top_variants_per_tribe: dict[str, dict[str, int]] = defaultdict(lambda: defaultdict(int))
    for root in roots:
        for n in [root] + _collect_descendants(root):
            tribe = n.get("tribe", "")
            v = n.get("prompt_variant", "")
            if tribe and v:
                top_variants_per_tribe[tribe][v] += n.get("tps_total", 0)

    # Knowledge market: aggregate across nodes.
    n_buy = 0
    n_sell = 0
    n_cache_hit = 0
    cross_node_trades = 0
    same_node_trades = 0
    # tribe -> node label for cross-vs-same-node bookkeeping.
    tribe_to_node: dict[str, str] = {}
    for root in roots:
        for n in [root] + _collect_descendants(root):
            tribe = n.get("tribe", "")
            if tribe and tribe not in tribe_to_node:
                tribe_to_node[tribe] = n.get("node", "")
    for r in market_rows:
        op = r.get("op", "")
        if op == "buy":
            n_buy += 1
            if (r.get("cache_hit") or "") == "1":
                n_cache_hit += 1
        elif op == "sell":
            n_sell += 1
        # Cross-node when buyer tribe and topic-implied seller tribe
        # belong to different nodes. Topic shape:
        # `tribes-bench-tribe-X/...`.
        if op == "buy":
            buyer_tribe = r.get("tribe", "")
            topic = r.get("topic", "")
            seller_tribe = ""
            if isinstance(topic, str) and topic.startswith("tribes-bench-"):
                rest = topic[len("tribes-bench-"):]
                seller_tribe = rest.split("/", 1)[0] if "/" in rest else rest
            if buyer_tribe and seller_tribe:
                bn = tribe_to_node.get(buyer_tribe, "")
                sn = tribe_to_node.get(seller_tribe, "")
                if bn and sn and bn != sn:
                    cross_node_trades += 1
                elif bn and sn and bn == sn:
                    same_node_trades += 1

    lines: list[str] = []
    lines.append("# Stage 3 (#439) multinode pilot summary")
    lines.append("")
    lines.append(f"- run dir: `{run_dir}`")
    lines.append(f"- server nodes detected: {server_node_count}")
    lines.append("")

    lines.append("## 1. Run shape")
    lines.append("")
    started = meta.get("started_at", "")
    wall = meta.get("wall_clock_s", "")
    rot_int = meta.get("rotation_interval_s", "")
    lines.append("| metric | value |")
    lines.append("|---|---|")
    lines.append(f"| started_at | {started} |")
    lines.append(f"| wall_clock_s | {wall} |")
    lines.append(f"| rotation_interval_s | {rot_int} |")
    lines.append(f"| rotations recorded | {len(rotations)} |")
    lines.append(f"| nodes | {1 + server_node_count} |")
    lines.append(f"| laptop tribes seen | {laptop['tribes']} |")
    lines.append(f"| server tribes seen | {server['tribes']} |")
    lines.append("")

    lines.append("## 2. Findings volume")
    lines.append("")
    lines.append("| node | findings | TPs | FPs |")
    lines.append("|---|---|---|---|")
    lines.append(f"| laptop | {laptop['findings']} | {laptop['tps']} | {laptop['fps']} |")
    lines.append(f"| server | {server['findings']} | {server['tps']} | {server['fps']} |")
    lines.append(f"| total | {total_f} | {total_tp} | {total_fp} |")
    lines.append("")
    if rotations:
        lines.append("Per-target findings (after each rotation row):")
        lines.append("")
        lines.append("| ts | target_dir | bugs_manifest |")
        lines.append("|---|---|---|")
        for r in rotations:
            lines.append(
                f"| {r.get('ts','')} | {r.get('target_dir','')} | {r.get('bugs_manifest','')} |"
            )
        lines.append("")

    lines.append("## 3. Cost per verified bug")
    lines.append("")
    lines.append("| node | CB | TPs | CB / TP |")
    lines.append("|---|---|---|---|")
    cpt_l = (laptop["cb"] / laptop["tps"]) if laptop["tps"] > 0 else 0.0
    cpt_s = (server["cb"] / server["tps"]) if server["tps"] > 0 else 0.0
    cpt_t = (total_cb / total_tp) if total_tp > 0 else 0.0
    lines.append(f"| laptop | {laptop['cb']} | {laptop['tps']} | {cpt_l:.2f} |")
    lines.append(f"| server | {server['cb']} | {server['tps']} | {cpt_s:.2f} |")
    lines.append(f"| total  | {total_cb} | {total_tp} | {cpt_t:.2f} |")
    lines.append("")

    lines.append("## 4. Replication dynamics")
    lines.append("")
    lines.append("| metric | value |")
    lines.append("|---|---|")
    lines.append(f"| replicate events | {n_replicates} |")
    lines.append(f"| deaths recorded | {n_deaths} |")
    lines.append(f"| distinct lineages (root agents) | {n_lineages} |")
    lines.append(f"| lineage depth max | {depth_max} |")
    lines.append(f"| lineage depth mean | {depth_mean:.2f} |")
    lines.append("")

    lines.append("## 5. Mutation outcomes")
    lines.append("")
    lines.append("| mutation_kind | count |")
    lines.append("|---|---|")
    for k in ("same", "cycle-1", "cycle-2"):
        lines.append(f"| {k} | {mut_counts.get(k, 0)} |")
    if mut_counts.get("other"):
        lines.append(f"| other | {mut_counts.get('other', 0)} |")
    if mut_counts.get(""):
        lines.append(f"| (unknown) | {mut_counts.get('', 0)} |")
    lines.append("")
    lines.append(f"unauthored-specialist lineages: {n_unauthored}")
    lines.append("")
    if top_variants_per_tribe:
        lines.append("Top-3 surviving variants per tribe (ranked by aggregate TPs):")
        lines.append("")
        lines.append("| tribe | rank | variant | tps |")
        lines.append("|---|---|---|---|")
        for tribe in sorted(top_variants_per_tribe.keys()):
            ranked = sorted(
                top_variants_per_tribe[tribe].items(),
                key=lambda kv: (-kv[1], kv[0]),
            )[:3]
            for i, (v, tps) in enumerate(ranked, start=1):
                lines.append(f"| {tribe} | {i} | {v} | {tps} |")
        lines.append("")

    lines.append("## 6. Knowledge market activity")
    lines.append("")
    if not market_rows:
        lines.append("_no market activity in this run_")
    else:
        lines.append("| metric | value |")
        lines.append("|---|---|")
        lines.append(f"| buy ops | {n_buy} |")
        lines.append(f"| sell ops | {n_sell} |")
        lines.append(f"| cache-hit buys | {n_cache_hit} |")
        lines.append(f"| cross-node buy trades | {cross_node_trades} |")
        lines.append(f"| same-node buy trades | {same_node_trades} |")
    lines.append("")

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return out_path


# --- Main -------------------------------------------------------------------

def main() -> None:
    run_dir, laptop_dir, server_runs, out_dir = parse_args(sys.argv)

    server_node_dirs = discover_server_node_dirs(server_runs)
    if not server_node_dirs:
        if not os.path.isdir(server_runs):
            print(
                f"analyse-stage3: warning: server-runs dir missing ({server_runs}); "
                "proceeding with laptop-only data",
                file=sys.stderr,
            )
        else:
            print(
                f"analyse-stage3: warning: no server hermetic .agentis trees under {server_runs}; "
                "proceeding with laptop-only data",
                file=sys.stderr,
            )

    laptop_rows = run_stage2_analyser(laptop_dir)
    server_rows_by_node: list[list[list[str]]] = []
    for node_dir in server_node_dirs:
        server_rows_by_node.append(run_stage2_analyser(node_dir))

    combined_path = write_combined_telemetry(out_dir, laptop_rows, server_rows_by_node)
    print(combined_path)

    # Per-node agent inventory.
    laptop_agents = collect_node_agents(laptop_dir, "laptop")
    server_agents: dict[str, dict[str, Any]] = {}
    for node_dir in server_node_dirs:
        server_agents.update(collect_node_agents(node_dir, "server"))

    # Collision-safe merge: laptop wins on duplicate agent_id (should
    # never happen in practice -- the daemon registry uses 16-byte hex
    # ids -- but better to be deterministic on the off chance).
    all_agents: dict[str, dict[str, Any]] = {}
    all_agents.update(server_agents)
    all_agents.update(laptop_agents)

    roots, events = build_lineage(all_agents)
    lineage_path = write_lineage_json(out_dir, roots)
    print(lineage_path)

    survivor_path = write_survivor_analysis(out_dir, roots)
    print(survivor_path)

    mutation_path = write_mutation_diff(out_dir, events)
    print(mutation_path)

    rotations = _read_rotations(run_dir)
    market_rows: list[dict[str, Any]] = []
    market_rows.extend(load_market_log(laptop_dir))
    for node_dir in server_node_dirs:
        market_rows.extend(load_market_log(node_dir))

    rows_by_node: dict[str, list[list[str]]] = {
        "laptop": laptop_rows,
        "server": [r for nrows in server_rows_by_node for r in nrows],
    }
    comparison_path = write_comparison_md(
        out_dir=out_dir,
        run_dir=run_dir,
        rows_by_node=rows_by_node,
        rotations=rotations,
        roots=roots,
        events=events,
        market_rows=market_rows,
        server_node_count=len(server_node_dirs),
    )
    print(comparison_path)


if __name__ == "__main__":
    main()
