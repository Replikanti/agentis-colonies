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
                             observed `parent_variant -> child_variant`
                             pair, a `mutation_kind` over the parsed
                             per-tribe variant pool, a `source` flag
                             (`observed` when the replicate row carried
                             a `variant:` tag, `unresolved` otherwise),
                             and the parent variant's aggregated
                             `verified` / `falsepos` counts from the
                             `variant_stats:*` memos.
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
import re
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

# Stage2 bug-class universe (#513) mirrors the 8 classes the post-#499
# hunter.ag class-flip path emits (`_class_pick_universe`). The list is
# the canonical row order for the per-class fitness summary table in
# `comparison-stage3.md` and the per-class CSV reductions in
# `variant-trajectory.csv`. Unknown classes seen in `variant_stats:*`
# memos are appended after these 8 in sorted order with an `unknown:`
# prefix so an off-pool class-flip mutation does not silently disappear
# from the operator-facing summary.
STAGE2_CLASSES = [
    "uninitialised_memory", "use_after_free", "memory_corruption",
    "heap_overflow", "data_race", "send_violation", "missing_lock",
    "dangling_borrow",
]

# Per-tribe variant pools are parsed from each tribe's hunter.ag at
# analysis time. The analyser is observational only -- it does NOT
# re-implement pick_variant(). Variant attribution to agents comes
# from `variant:<name>` tags written by hunter.ag on each replicate
# row, plus per-tribe `variant_stats:<variant>:{verified,falsepos}`
# memos that hunters increment on findings/false-positives.
#
# Any future hunter.ag refactor that returns variants via concatenation
# or a lookup table (i.e. not bare `return "<literal>";` lines inside
# `fn pick_variant`) MUST add a sibling `pick_variant_pool() ->
# list<string>` helper or a `tribe-<name>/agents/variant-pool.txt`
# metadata file so this analyser can keep enumerating the pool.

_VARIANT_POOL_CACHE: dict[str, list[str]] = {}


def parse_variant_pool(hunter_ag_path: str) -> list[str]:
    """Regex-scan the body of `fn pick_variant(...) { ... }` in a
    tribe's hunter.ag and return the list of bare-literal `return
    "<value>";` strings in source order.

    Raises ValueError when the function body has zero return literals
    -- a silent empty pool would re-introduce the stale-variant model
    bug that #495 fixes. Caches results by absolute path.
    """
    abs_path = os.path.abspath(hunter_ag_path)
    cached = _VARIANT_POOL_CACHE.get(abs_path)
    if cached is not None:
        return list(cached)
    try:
        with open(abs_path, encoding="utf-8") as f:
            src = f.read()
    except OSError as exc:
        raise ValueError(f"parse_variant_pool: cannot read {abs_path}: {exc}") from exc
    # Locate the start of `fn pick_variant(...)` and scan the matching
    # body. The grammar is brace-delimited, so we count `{` / `}`
    # characters until the function body closes. This survives nested
    # `if { ... }` blocks inside pick_variant (which every tribe has).
    fn_match = re.search(r"\bfn\s+pick_variant\b[^{]*\{", src)
    if fn_match is None:
        raise ValueError(
            f"parse_variant_pool: no `fn pick_variant` in {abs_path}"
        )
    body_start = fn_match.end()
    depth = 1
    i = body_start
    while i < len(src) and depth > 0:
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
        i += 1
    body = src[body_start:i - 1]
    literals = re.findall(r'return\s+"([^"\\]*)"\s*;', body)
    if not literals:
        raise ValueError(
            f"parse_variant_pool: zero return literals in `fn pick_variant` "
            f"of {abs_path}; refactor must add a pick_variant_pool() helper "
            f"or variant-pool.txt metadata file"
        )
    _VARIANT_POOL_CACHE[abs_path] = list(literals)
    return list(literals)


def discover_tribe_pools(fed_root: str) -> dict[str, list[str]]:
    """Walk `<fed_root>/tribe-*/agents/hunter.ag` and return a dict
    `{tribe_name: [variant, ...]}`. Asserts the union of pools is
    duplicate-free (every tribe uses a disjoint domain prefix).
    """
    pools: dict[str, list[str]] = {}
    if not os.path.isdir(fed_root):
        return pools
    for name in sorted(os.listdir(fed_root)):
        if not name.startswith("tribe-"):
            continue
        hunter = os.path.join(fed_root, name, "agents", "hunter.ag")
        if not os.path.isfile(hunter):
            continue
        pools[name] = parse_variant_pool(hunter)
    seen: dict[str, str] = {}
    for tribe, variants in pools.items():
        for v in variants:
            if v in seen and seen[v] != tribe:
                raise ValueError(
                    f"discover_tribe_pools: variant {v!r} appears in both "
                    f"{seen[v]} and {tribe}; pools must be disjoint"
                )
            seen[v] = tribe
    return pools


def _resolve_fed_root(fed_root_arg: str | None, run_dir: str) -> str:
    """Resolve the federation root used for variant-pool discovery.

    Order: explicit --fed-root > $AGENTIS_FED_ROOT > autodetect via
    run_dir/../.. (the tribes-bench/runs/<ts> shape produced by
    run-stage3-docker.sh).
    """
    if fed_root_arg:
        return os.path.abspath(fed_root_arg)
    env = os.environ.get("AGENTIS_FED_ROOT")
    if env:
        return os.path.abspath(env)
    # Autodetect: tribes-bench/runs/<ts>/  ->  tribes-bench/
    candidate = os.path.abspath(os.path.join(run_dir, "..", ".."))
    return candidate


def read_variant_stats(node_dir: str) -> dict[str, dict[str, int]]:
    """Invoke `agentis memo list --prefix variant_stats:` from
    `node_dir` (so the hermetic .agentis/ tree is the runtime's cwd)
    and parse the `variant_stats:<variant>:{verified,falsepos} = <n>`
    pairs into `{variant: {"verified": int, "falsepos": int}}`.

    Decoupled from the runtime's storage backend by going through the
    CLI rather than reading sled directly. Missing binary, non-zero
    exit, or empty output -> `{}` with a stderr warning. Never raises.
    """
    out: dict[str, dict[str, int]] = {}
    try:
        proc = subprocess.run(
            ["agentis", "memo", "list", "--prefix", "variant_stats:"],
            cwd=node_dir,
            check=False,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        print(
            "analyse-stage3: warning: `agentis` binary not on PATH; "
            "variant_stats memos skipped",
            file=sys.stderr,
        )
        return {}
    except OSError as exc:
        print(
            f"analyse-stage3: warning: cannot invoke agentis memo list "
            f"in {node_dir}: {exc}",
            file=sys.stderr,
        )
        return {}
    if proc.returncode != 0:
        return out
    for raw_line in (proc.stdout or "").splitlines():
        line = raw_line.strip()
        if not line:
            continue
        # Expected shape: `variant_stats:<variant>:<metric> = <int>`
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if not key.startswith("variant_stats:"):
            continue
        rest = key[len("variant_stats:"):]
        if ":" not in rest:
            continue
        variant, _, metric = rest.rpartition(":")
        if metric not in ("verified", "falsepos"):
            continue
        try:
            n = int(value)
        except ValueError:
            continue
        out.setdefault(variant, {"verified": 0, "falsepos": 0})[metric] = n
    return out


def aggregate_variant_stats(
    node_dirs: list[str],
    tribe_pools: dict[str, list[str]],
) -> dict[str, dict[str, dict[str, int]]]:
    """Reverse-lookup variant -> tribe via tribe_pools, then aggregate
    `read_variant_stats()` from every node into `{tribe: {variant:
    {"verified": N, "falsepos": N}}}`.
    """
    variant_to_tribe: dict[str, str] = {}
    for tribe, variants in tribe_pools.items():
        for v in variants:
            variant_to_tribe[v] = tribe
    aggregated: dict[str, dict[str, dict[str, int]]] = {
        tribe: {v: {"verified": 0, "falsepos": 0} for v in variants}
        for tribe, variants in tribe_pools.items()
    }
    for node_dir in node_dirs:
        per_node = read_variant_stats(node_dir)
        for variant, counts in per_node.items():
            tribe = variant_to_tribe.get(variant)
            if tribe is None:
                continue
            slot = aggregated.setdefault(tribe, {}).setdefault(
                variant, {"verified": 0, "falsepos": 0}
            )
            slot["verified"] += int(counts.get("verified", 0))
            slot["falsepos"] += int(counts.get("falsepos", 0))
    return aggregated


def parse_args(argv: list[str]) -> tuple[str, str, str, str, str | None, bool, bool]:
    """Parse argv into (run_dir, laptop_dir, server_runs_dir, out_dir,
    fed_root, no_variant_stats, legacy_top_variants).

    Defaults:
        --laptop-dir   <run-dir>                 (SSH multinode shape)
        --server-runs  <run-dir>/server-runs/    (SSH multinode shape)
        --out          <run-dir>/
        --fed-root     autodetect via run_dir/../.. (or $AGENTIS_FED_ROOT)

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
    p.add_argument(
        "--fed-root",
        default=None,
        help="federation root (tribes-bench/) for variant-pool discovery; "
             "default autodetect via run_dir/../.. or $AGENTIS_FED_ROOT",
    )
    p.add_argument(
        "--no-variant-stats",
        action="store_true",
        help="skip `agentis memo list` reads (for tests / hosts without "
             "the agentis binary on PATH)",
    )
    p.add_argument(
        "--legacy-top-variants",
        action="store_true",
        help="emit the pre-#495 synthetic Top-3 surviving variants table "
             "alongside the observational Variant outcomes table",
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
    return (
        run_dir, laptop_dir, server_runs, out_dir,
        ns.fed_root, bool(ns.no_variant_stats), bool(ns.legacy_top_variants),
    )


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


def _variant_from_tags(
    tags: list[Any],
    known_variants: set[str] | None = None,
) -> str:
    """Extract a prompt_variant value from a learn() tag list. Tries
    `variant:<name>` first; falls back to a bare-name match against
    `known_variants` (the union of every tribe's parsed pool) when the
    legacy untagged hunter.ag form is in play."""
    for t in tags:
        if not isinstance(t, str):
            continue
        if t.startswith("variant:"):
            return t.split(":", 1)[1]
        if known_variants is not None and t in known_variants:
            return t
    return ""


def _agent_observed_variant(
    experience_dir: str,
    agent_id: str,
    known_variants: set[str] | None = None,
) -> str:
    """Earliest variant claim seen on any learn row authored by the
    agent. Recognises `variant:<name>` tags first, then -- when
    `known_variants` is supplied -- bare-name tags matching the union
    of every tribe's parsed pool. Empty string when no claim is found.
    Observational fallback used by collect_node_agents() to seed each
    agent's prompt_variant before lineage linking runs.
    """
    path = os.path.join(experience_dir, f"{agent_id}.jsonl")
    earliest_ts: int | None = None
    earliest_variant = ""
    for rec in read_jsonl(path):
        tags = rec.get("tags") or []
        if not isinstance(tags, list):
            continue
        ts = rec.get("ts")
        if not isinstance(ts, int):
            continue
        for t in tags:
            if not isinstance(t, str):
                continue
            claim = ""
            if t.startswith("variant:"):
                claim = t.split(":", 1)[1]
            elif known_variants is not None and t in known_variants:
                claim = t
            if claim:
                if earliest_ts is None or ts < earliest_ts:
                    earliest_ts = ts
                    earliest_variant = claim
                break
    return earliest_variant


def collect_node_agents(
    node_root: str,
    node_label: str,
    known_variants: set[str] | None = None,
) -> dict[str, dict[str, Any]]:
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
        observed_variant = _agent_observed_variant(
            experience_dir, agent_id, known_variants
        )
        out[agent_id] = {
            "agent_id": agent_id,
            "tribe": tribe,
            "node": node_label,
            "born_ts": born,
            "died_ts": died,
            "tps_total": tps,
            "fps_total": fps,
            "_replicate_events": rep_events,
            "_observed_variant": observed_variant,
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
            observed_variant = _agent_observed_variant(
            experience_dir, agent_id, known_variants
        )
            out[agent_id] = {
                "agent_id": agent_id,
                "tribe": tribe,
                "node": node_label,
                "born_ts": born,
                "died_ts": died,
                "tps_total": tps,
                "fps_total": fps,
                "_replicate_events": rep_events,
                "_observed_variant": observed_variant,
            }
    return out


def _link_parents(
    agents: dict[str, dict[str, Any]],
    known_variants: set[str] | None = None,
) -> list[dict[str, Any]]:
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
        _ = tribe  # symmetry with prior signature; tribe unused below
        lst.sort(key=lambda x: (x["born_ts"], x["agent_id"]))
        # Root: first agent. The prompt_variant is observational --
        # taken from the earliest `variant:<name>` tag the agent
        # actually emitted (collect_node_agents:_observed_variant).
        # Empty when the agent never tagged a variant.
        for idx, a in enumerate(lst):
            a["_birth_index"] = idx
            a["prompt_variant"] = a.get("_observed_variant", "") or ""
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
        tags = rec.get("tags") or []
        tag_variant = (
            _variant_from_tags(tags, known_variants)
            if isinstance(tags, list) else ""
        )
        if not children:
            # No more un-parented children -- record the event with an
            # unresolved child for mutation-diff anyway.
            events_out.append({
                "ts": ts,
                "parent_id": parent["agent_id"],
                "child_id": "",
                "tribe": tribe,
                "parent_variant": parent.get("prompt_variant", ""),
                "child_variant": tag_variant,
                "source": "unresolved",
            })
            continue
        child = children.pop(0)
        child["parent_id"] = parent["agent_id"]
        # The on-row `variant:` tag is the legitimate observational
        # source of the child variant; absence stays empty (no
        # synthesised cycle fallback after #495).
        if tag_variant:
            child["prompt_variant"] = tag_variant
        events_out.append({
            "ts": ts,
            "parent_id": parent["agent_id"],
            "child_id": child["agent_id"],
            "tribe": tribe,
            "parent_variant": parent.get("prompt_variant", ""),
            "child_variant": child.get("prompt_variant", ""),
            "source": "observed" if tag_variant else "unresolved",
        })
    return events_out


def build_lineage(
    agents: dict[str, dict[str, Any]],
    known_variants: set[str] | None = None,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Return (lineage_roots, replicate_events).

    `lineage_roots` is a list of dicts in the schema documented in the
    PR header: one dict per root, with `children` recursively nested.
    `replicate_events` is the parent->child event list used by
    mutation-diff.csv.
    """
    events = _link_parents(agents, known_variants)
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

def _mutation_kind(
    parent_variant: str,
    child_variant: str,
    tribe: str = "",
    tribe_pools: dict[str, list[str]] | None = None,
) -> str:
    """Classify the parent->child variant transition. Empty parent or
    child stays `""` (unresolved). Same-name -> `same`. When a tribe
    pool is available and both ends are known members, the cycle delta
    is `cycle-N` over that pool; otherwise the relation is `other`.
    """
    if not parent_variant or not child_variant:
        return ""
    if parent_variant == child_variant:
        return "same"
    if tribe_pools and tribe and tribe in tribe_pools:
        pool = tribe_pools[tribe]
        try:
            pi = pool.index(parent_variant)
            ci = pool.index(child_variant)
        except ValueError:
            return "other"
        delta = (ci - pi) % len(pool)
        if delta == 0:
            return "same"
        return f"cycle-{delta}"
    return "other"


def write_mutation_diff(
    out_dir: str,
    events: list[dict[str, Any]],
    tribe_pools: dict[str, list[str]] | None = None,
    aggregated_stats: dict[str, dict[str, dict[str, int]]] | None = None,
) -> str:
    """Emit `mutation-diff.csv` augmented with the observational
    columns `source` (`observed` when the replicate row carried a
    `variant:` tag, `unresolved` otherwise) and the parent variant's
    aggregated `verified` / `falsepos` counts pulled from the
    `variant_stats:*` memos. Empty parent_variant rows leave the two
    stat columns blank.
    """
    out_path = os.path.join(out_dir, "mutation-diff.csv")
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow([
            "ts", "parent_id", "child_id", "tribe",
            "parent_variant", "child_variant", "mutation_kind",
            "source", "parent_variant_verified", "parent_variant_falsepos",
        ])
        for ev in sorted(events, key=lambda e: int(e.get("ts") or 0)):
            tribe = ev.get("tribe", "")
            parent_variant = ev.get("parent_variant", "")
            verified_cell: str = ""
            falsepos_cell: str = ""
            if aggregated_stats and tribe and parent_variant:
                stats = aggregated_stats.get(tribe, {}).get(parent_variant)
                if stats is not None:
                    verified_cell = str(stats.get("verified", 0))
                    falsepos_cell = str(stats.get("falsepos", 0))
            w.writerow([
                ev.get("ts", 0),
                ev.get("parent_id", ""),
                ev.get("child_id", ""),
                tribe,
                parent_variant,
                ev.get("child_variant", ""),
                _mutation_kind(
                    parent_variant, ev.get("child_variant", ""),
                    tribe=tribe, tribe_pools=tribe_pools,
                ),
                ev.get("source", ""),
                verified_cell,
                falsepos_cell,
            ])
    return out_path


# --- Per-class trajectory + summary (#513) ---------------------------------

def _split_class_phrasing(variant: str) -> tuple[str, str]:
    """Parse a variant string into `(class, phrasing)`. Post-#499 the
    canonical variant shape is `<class>:<phrasing>`. Empty or
    separator-less inputs collapse to `("", "")` so callers can filter
    them out of the trajectory and summary.
    """
    if not variant or ":" not in variant:
        return ("", "")
    cls, _, phrasing = variant.partition(":")
    return (cls, phrasing)


def emit_variant_trajectory(
    out_dir: str,
    events: list[dict[str, Any]],
    aggregated_stats: dict[str, dict[str, dict[str, int]]] | None = None,
) -> str:
    """Emit `variant-trajectory.csv` (#513): a reconstructed per-(tribe,
    class, phrasing) time series.

    The trajectory is NOT observed history. Hunters do not write
    per-tick `variant_stats` snapshots; we only know the end-of-run
    totals plus the replicate-event timeline from `mutation-diff.csv`.
    For each (tribe, variant) we distribute the final verified /
    falsepos counters proportionally across the replicate events that
    targeted that (tribe, variant) pair, using each event's ordinal
    position over `event_count[tribe,variant]`.

    The hunter-side write-through (observed trajectory) is the deferred
    path; the CSV header carries an inline caveat that links #513 so
    downstream operators do not misread the file as real per-tick
    dynamics. Schema (after the comment line):

        ts,tribe,class,phrasing,verified_cumul,falsepos_cumul,hit_rate
    """
    out_path = os.path.join(out_dir, "variant-trajectory.csv")
    caveat = (
        "# trajectory: reconstructed from end-of-run totals + "
        "replicate-event timeline. Hunter-side write-through is the "
        "observed alternative, deferred (#513).\n"
    )
    header_cols = [
        "ts", "tribe", "class", "phrasing",
        "verified_cumul", "falsepos_cumul", "hit_rate",
    ]
    # Filter to events that carry a usable (tribe, child_variant) pair.
    usable: list[dict[str, Any]] = []
    for ev in events:
        tribe = ev.get("tribe", "")
        variant = ev.get("child_variant", "")
        if not tribe or not variant:
            continue
        usable.append(ev)
    usable.sort(key=lambda e: (int(e.get("ts") or 0), e.get("tribe", "")))
    # Event count per (tribe, variant) over the usable timeline.
    event_count: dict[tuple[str, str], int] = defaultdict(int)
    for ev in usable:
        event_count[(ev.get("tribe", ""), ev.get("child_variant", ""))] += 1
    # Walk timeline; emit one CSV row per usable event whose
    # (tribe, variant) has end totals > 0. Cumulative counters are
    # rounded(final * seen / event_count) so the final row matches the
    # end-of-run total byte-for-byte.
    seen: dict[tuple[str, str], int] = defaultdict(int)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        f.write(caveat)
        w = csv.writer(f)
        w.writerow(header_cols)
        if not usable or not aggregated_stats:
            return out_path
        for ev in usable:
            tribe = ev.get("tribe", "")
            variant = ev.get("child_variant", "")
            stats = aggregated_stats.get(tribe, {}).get(variant)
            if stats is None:
                continue
            final_v = int(stats.get("verified", 0))
            final_fp = int(stats.get("falsepos", 0))
            if final_v + final_fp == 0:
                continue
            n = event_count[(tribe, variant)]
            if n <= 0:
                continue
            seen[(tribe, variant)] += 1
            k = seen[(tribe, variant)]
            verified_cumul = int(round(final_v * k / n))
            falsepos_cumul = int(round(final_fp * k / n))
            denom = verified_cumul + falsepos_cumul
            hit_rate = (verified_cumul / denom) if denom > 0 else 0.0
            cls, phrasing = _split_class_phrasing(variant)
            w.writerow([
                int(ev.get("ts") or 0),
                tribe,
                cls,
                phrasing,
                verified_cumul,
                falsepos_cumul,
                f"{hit_rate:.4f}",
            ])
    return out_path


def render_per_class_summary(
    aggregated_stats: dict[str, dict[str, dict[str, int]]] | None,
) -> list[str]:
    """Render the `### Per-class fitness summary` section lines (#513).

    Returns the markdown lines (no trailing blank) for the new section
    appended to `comparison-stage3.md`. The table has 8 fixed rows in
    `STAGE2_CLASSES` order even when a class has zero counters, so
    cross-tribe drift is visible at a glance. Unknown classes (e.g. an
    off-pool class-flip mutation) are appended sorted with an
    `unknown:` prefix.

    Columns: `class | verified | falsepos | hit_rate | dominant_tribe |
    spread`. `dominant_tribe` is the tribe with the most verified
    counters for the class (`-` when zero); `spread` counts tribes with
    verified > 0 for the class (0-5).
    """
    # Aggregate verified / falsepos per (class, tribe).
    per_class_tribe_verified: dict[str, dict[str, int]] = defaultdict(
        lambda: defaultdict(int)
    )
    per_class_verified: dict[str, int] = defaultdict(int)
    per_class_falsepos: dict[str, int] = defaultdict(int)
    seen_classes: set[str] = set()
    if aggregated_stats:
        for tribe, variants in aggregated_stats.items():
            for variant, counts in variants.items():
                cls, _ = _split_class_phrasing(variant)
                if not cls:
                    continue
                v_n = int(counts.get("verified", 0))
                fp_n = int(counts.get("falsepos", 0))
                per_class_tribe_verified[cls][tribe] += v_n
                per_class_verified[cls] += v_n
                per_class_falsepos[cls] += fp_n
                seen_classes.add(cls)
    # Fixed rows first; unknown classes appended sorted with prefix.
    unknown_classes = sorted(
        c for c in seen_classes if c not in STAGE2_CLASSES
    )
    row_classes = list(STAGE2_CLASSES) + unknown_classes
    lines: list[str] = []
    lines.append("### Per-class fitness summary")
    lines.append("")
    lines.append(
        "Reconstructed per-class rollup over `variant_stats:*` memos "
        "(#513). End-of-run totals only; the per-tick fitness curve in "
        "`variant-trajectory.csv` is proportionally reconstructed -- "
        "hunter-side write-through is the deferred observed-trajectory "
        "path."
    )
    lines.append("")
    lines.append(
        "| class | verified | falsepos | hit_rate | dominant_tribe | spread |"
    )
    lines.append("|---|---|---|---|---|---|")
    for cls in row_classes:
        v_n = per_class_verified.get(cls, 0)
        fp_n = per_class_falsepos.get(cls, 0)
        denom = v_n + fp_n
        hit_rate_cell = f"{v_n / denom:.2f}" if denom > 0 else "n/a"
        tribe_counts = per_class_tribe_verified.get(cls, {})
        if v_n > 0 and tribe_counts:
            dominant = sorted(
                tribe_counts.items(),
                key=lambda kv: (-int(kv[1]), kv[0]),
            )
            # The first entry with verified > 0 is the dominant tribe.
            dominant_tribe = "-"
            for t, c in dominant:
                if int(c) > 0:
                    dominant_tribe = t
                    break
        else:
            dominant_tribe = "-"
        spread = sum(1 for c in tribe_counts.values() if int(c) > 0)
        label = cls if cls in STAGE2_CLASSES else f"unknown:{cls}"
        lines.append(
            f"| {label} | {v_n} | {fp_n} | {hit_rate_cell} | "
            f"{dominant_tribe} | {spread} |"
        )
    return lines


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
    tribe_pools: dict[str, list[str]] | None = None,
    aggregated_stats: dict[str, dict[str, dict[str, int]]] | None = None,
    legacy_top_variants: bool = False,
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
        mut_counts[_mutation_kind(
            ev.get("parent_variant", ""), ev.get("child_variant", ""),
            tribe=ev.get("tribe", ""), tribe_pools=tribe_pools,
        )] += 1
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
    # #495: Variant outcomes per tribe -- observational, sourced from
    # `variant_stats:<variant>:{verified,falsepos}` memos that hunters
    # increment on every finding. Replaces the synthetic Top-3 surviving
    # variants table that was driven by a hardcoded 3-element cycle.
    if aggregated_stats:
        any_active = any(
            (counts.get("verified", 0) + counts.get("falsepos", 0)) > 0
            for variants in aggregated_stats.values()
            for counts in variants.values()
        )
        if any_active:
            lines.append("Variant outcomes per tribe "
                         "(observational, from variant_stats memos):")
            lines.append("")
            lines.append("| tribe | variant | verified | falsepos | hit_rate |")
            lines.append("|---|---|---|---|---|")
            for tribe in sorted(aggregated_stats.keys()):
                ordered = sorted(
                    aggregated_stats[tribe].items(),
                    key=lambda kv: (
                        -int(kv[1].get("verified", 0)),
                        int(kv[1].get("falsepos", 0)),
                        kv[0],
                    ),
                )
                for variant, counts in ordered:
                    v_n = int(counts.get("verified", 0))
                    fp_n = int(counts.get("falsepos", 0))
                    if v_n + fp_n == 0:
                        continue
                    hit_rate = (v_n / (v_n + fp_n)) if (v_n + fp_n) > 0 else 0.0
                    lines.append(
                        f"| {tribe} | {variant} | {v_n} | {fp_n} | "
                        f"{hit_rate:.2f} |"
                    )
            lines.append("")
            # Dead variants: pool members with verified=0 AND falsepos>=1.
            dead_lines: list[str] = []
            for tribe in sorted(aggregated_stats.keys()):
                dead = [
                    (variant, int(counts.get("falsepos", 0)))
                    for variant, counts in aggregated_stats[tribe].items()
                    if int(counts.get("verified", 0)) == 0
                    and int(counts.get("falsepos", 0)) >= 1
                ]
                dead.sort(key=lambda kv: (-kv[1], kv[0]))
                for variant, fp_n in dead:
                    dead_lines.append(f"| {tribe} | {variant} | {fp_n} |")
            if dead_lines:
                lines.append("Dead variants per tribe (0 verified, >=1 falsepos):")
                lines.append("")
                lines.append("| tribe | variant | falsepos |")
                lines.append("|---|---|---|")
                lines.extend(dead_lines)
                lines.append("")
    if legacy_top_variants and top_variants_per_tribe:
        lines.append(
            "Top-3 surviving variants per tribe (legacy synthetic; "
            "kept behind --legacy-top-variants for diff-review continuity):"
        )
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

    # #513: per-class fitness summary. Always emitted (8 fixed rows even
    # when zero counters) so the cross-tribe drift surface stays
    # comparable across runs even before the first verified finding.
    lines.extend(render_per_class_summary(aggregated_stats))
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
    (
        run_dir, laptop_dir, server_runs, out_dir,
        fed_root_arg, no_variant_stats, legacy_top_variants,
    ) = parse_args(sys.argv)

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

    # Discover per-tribe variant pools from hunter.ag sources. A
    # missing fed root is non-fatal -- variants that show up only via
    # `variant:` tags on replicate rows will still resolve, and the
    # mutation_kind column will fall back to "other".
    fed_root = _resolve_fed_root(fed_root_arg, run_dir)
    tribe_pools: dict[str, list[str]] = {}
    try:
        tribe_pools = discover_tribe_pools(fed_root)
    except ValueError as exc:
        print(
            f"analyse-stage3: warning: variant-pool discovery failed: {exc}",
            file=sys.stderr,
        )
    known_variants: set[str] = {v for vs in tribe_pools.values() for v in vs}

    laptop_rows = run_stage2_analyser(laptop_dir)
    server_rows_by_node: list[list[list[str]]] = []
    for node_dir in server_node_dirs:
        server_rows_by_node.append(run_stage2_analyser(node_dir))

    combined_path = write_combined_telemetry(out_dir, laptop_rows, server_rows_by_node)
    print(combined_path)

    # Per-node agent inventory.
    laptop_agents = collect_node_agents(laptop_dir, "laptop", known_variants)
    server_agents: dict[str, dict[str, Any]] = {}
    for node_dir in server_node_dirs:
        server_agents.update(
            collect_node_agents(node_dir, "server", known_variants)
        )

    # Collision-safe merge: laptop wins on duplicate agent_id (should
    # never happen in practice -- the daemon registry uses 16-byte hex
    # ids -- but better to be deterministic on the off chance).
    all_agents: dict[str, dict[str, Any]] = {}
    all_agents.update(server_agents)
    all_agents.update(laptop_agents)

    roots, events = build_lineage(all_agents, known_variants)
    lineage_path = write_lineage_json(out_dir, roots)
    print(lineage_path)

    survivor_path = write_survivor_analysis(out_dir, roots)
    print(survivor_path)

    # Aggregate `variant_stats:*` memos across every node (laptop +
    # each server node). When --no-variant-stats was passed (or the
    # binary is missing), aggregated_stats stays a skeleton keyed by
    # tribe pool with all counters 0; the comparison md skips its
    # outcomes table when nothing has fired.
    aggregated_stats: dict[str, dict[str, dict[str, int]]]
    if no_variant_stats:
        aggregated_stats = {
            tribe: {v: {"verified": 0, "falsepos": 0} for v in variants}
            for tribe, variants in tribe_pools.items()
        }
    else:
        aggregated_stats = aggregate_variant_stats(
            [laptop_dir, *server_node_dirs], tribe_pools,
        )

    mutation_path = write_mutation_diff(
        out_dir, events,
        tribe_pools=tribe_pools,
        aggregated_stats=aggregated_stats,
    )
    print(mutation_path)

    # #513: reconstructed per-(tribe, class, phrasing) trajectory CSV.
    # The trajectory is proportional reconstruction over the replicate
    # timeline, not observed history -- caveat lives in the CSV header.
    trajectory_path = emit_variant_trajectory(
        out_dir, events, aggregated_stats=aggregated_stats,
    )
    print(trajectory_path)

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
        tribe_pools=tribe_pools,
        aggregated_stats=aggregated_stats,
        legacy_top_variants=legacy_top_variants,
    )
    print(comparison_path)


if __name__ == "__main__":
    main()
