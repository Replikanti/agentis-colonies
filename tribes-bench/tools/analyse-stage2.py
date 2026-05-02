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


def parse_args(argv: list[str]) -> tuple[str, str | None]:
    """Parse argv. Returns (run_dir, baseline_csv_path_or_None).

    Backward-compatible: bare ``analyse-stage2.py <run-dir>`` returns
    (run_dir, None) and produces byte-identical output to the M2 form.
    The optional ``--baseline <path>`` flag (M3 #394) triggers
    comparison-report emission to ``<run-dir>/comparison.md``.
    """
    args = argv[1:]
    if not args:
        print("Usage: analyse-stage2.py <run-dir> [--baseline <path>]", file=sys.stderr)
        sys.exit(2)
    run_dir: str | None = None
    baseline: str | None = None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--baseline":
            if i + 1 >= len(args):
                print("analyse-stage2: --baseline requires a path", file=sys.stderr)
                sys.exit(2)
            baseline = args[i + 1]
            i += 2
            continue
        if a.startswith("--"):
            print(f"analyse-stage2: unknown flag: {a}", file=sys.stderr)
            sys.exit(2)
        if run_dir is not None:
            print("analyse-stage2: too many positional args", file=sys.stderr)
            sys.exit(2)
        run_dir = a
        i += 1
    if run_dir is None:
        print("Usage: analyse-stage2.py <run-dir> [--baseline <path>]", file=sys.stderr)
        sys.exit(2)
    if not os.path.isdir(run_dir):
        print(f"analyse-stage2: run dir not found: {run_dir}", file=sys.stderr)
        sys.exit(2)
    if baseline is not None and not os.path.isfile(baseline):
        print(f"analyse-stage2: baseline csv not found: {baseline}", file=sys.stderr)
        sys.exit(2)
    return run_dir, baseline


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


# --- Stage 2 M2 (#393) cognitive-market readers + downstream resolver ---

MARKET_COLUMNS = [
    "ts_ms", "agent_id", "tribe", "op", "topic", "topic_kind",
    "ask_price", "max_cb", "paid_price", "cache_hit",
    "downstream_verified", "op_outcome",
]


def load_market_log(run_dir: str) -> list[dict[str, Any]]:
    """Read `<run-dir>/knowledge-market.csv` (the append-only trade log
    written by hunter.ag's `emit_market_csv` helper) into a list of dict
    rows. Schema is fixed at MARKET_COLUMNS; the hunter writes data rows
    only (no header), so this reader synthesises the column names. Empty
    file → empty list. Missing file → empty list (the analyser stays
    useful when the M2 wiring did not run).
    """
    path = os.path.join(run_dir, "knowledge-market.csv")
    out: list[dict[str, Any]] = []
    if not os.path.isfile(path):
        return out
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            parts = line.split(",")
            # Defensive: tolerate rows with too few/too many columns by
            # padding/truncating to the fixed schema.
            if len(parts) < len(MARKET_COLUMNS):
                parts = parts + [""] * (len(MARKET_COLUMNS) - len(parts))
            elif len(parts) > len(MARKET_COLUMNS):
                parts = parts[: len(MARKET_COLUMNS)]
            row: dict[str, Any] = {}
            for k, v in zip(MARKET_COLUMNS, parts):
                row[k] = v
            out.append(row)
    return out


def resolve_downstream_verified(
    market_rows: list[dict[str, Any]], experience_dir: str
) -> None:
    """For each `op == "buy"` row, scan the buyer tribe's experience
    JSONL within ±5 ticks of the buy ts; mark `downstream_verified` to
    `1` when an `acted` (verified) tribes-bench row appears, `0` when a
    `false-positive` row appears, `""` when neither fires. Mutates
    market_rows in place. Sell rows are left untouched.

    Tick boundary chosen as 5 minutes (300_000 ms) per plan §5; the
    buyer's seed prompt fires once per minute, so 5 ticks is the worst-
    case "within next 5 ticks" window the plan calls for.
    """
    if not os.path.isdir(experience_dir):
        return
    # Build per-tribe sorted list of (ts_ms, kind ∈ {"verified", "false"}).
    by_tribe: dict[str, list[tuple[int, str]]] = defaultdict(list)
    for fname in sorted(os.listdir(experience_dir)):
        if not fname.endswith(".jsonl"):
            continue
        for rec in read_jsonl(os.path.join(experience_dir, fname)):
            tags = rec.get("tags") or []
            if not isinstance(tags, list):
                continue
            if "tribes-bench" not in tags:
                continue
            ts_ms = rec.get("ts")
            if not isinstance(ts_ms, int):
                continue
            tribe = next((t for t in tags if t.startswith("tribe-")), None)
            if not tribe:
                continue
            if "acted" in tags:
                by_tribe[tribe].append((ts_ms, "verified"))
            elif "false-positive" in tags:
                by_tribe[tribe].append((ts_ms, "false"))
    for v in by_tribe.values():
        v.sort(key=lambda r: r[0])
    window_ms = 5 * 60 * 1000
    for row in market_rows:
        if row.get("op") != "buy":
            continue
        try:
            ts = int(row.get("ts_ms") or 0)
        except (TypeError, ValueError):
            continue
        tribe = row.get("tribe") or ""
        if not isinstance(tribe, str) or not tribe:
            continue
        events = by_tribe.get(tribe, [])
        verdict = ""
        for ev_ts, kind in events:
            if ev_ts < ts:
                continue
            if ev_ts > ts + window_ms:
                break
            if kind == "verified":
                verdict = "1"
                break
            if kind == "false":
                verdict = "0"
                break
        row["downstream_verified"] = verdict


def write_market_log(run_dir: str, rows: list[dict[str, Any]]) -> str | None:
    """Write resolved market rows back to `<run-dir>/knowledge-market.csv`
    with a header line prepended. Existing file (header-less append-only
    from hunter.ag) is overwritten. No-op when rows is empty.

    Per plan §9 risk 2: the analyser revenue contract is
    `revenue = sum(ask_price for r in rows if r.op=="buy" and r.cache_hit=="0")`,
    NOT total trade volume. cache_hit=1 rows must be excluded from
    seller-revenue accounting. The CSV preserves the cache_hit column so
    downstream consumers can compute revenue correctly.
    """
    if not rows:
        return None
    path = os.path.join(run_dir, "knowledge-market.csv")
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(MARKET_COLUMNS)
        for row in rows:
            w.writerow([row.get(k, "") for k in MARKET_COLUMNS])
    return path


def main() -> None:
    run_dir, baseline_csv = parse_args(sys.argv)
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

    # Stage 2 M2 (#393) sidecar CSV: read the append-only trade log
    # written by every hunter.ag's `emit_market_csv`, resolve the
    # `downstream_verified` column post-hoc by scanning each buyer's
    # experience JSONL within 5 ticks, and rewrite the CSV with a
    # header line. No-op when no trade rows exist (M2 wiring not run
    # or hunter never reached the buy/sell branch).
    market_rows = load_market_log(run_dir)
    if market_rows:
        resolve_downstream_verified(market_rows, experience_dir)
        market_path = write_market_log(run_dir, market_rows)
        if market_path:
            print(market_path)

    # Stage 2 M3 (#394) optional comparison report. When --baseline is
    # set, emit `<run-dir>/comparison.md` with the 5 fixed sections from
    # plan Decision 4. When --baseline is omitted, behaviour is
    # byte-identical to the M2 form (no comparison.md, no extra prints).
    if baseline_csv is not None:
        comparison_path = write_comparison_report(
            run_dir=run_dir,
            telemetry_csv=out_path,
            baseline_csv=baseline_csv,
            market_rows=market_rows,
        )
        if comparison_path:
            print(comparison_path)


# --- Stage 2 M3 (#394) comparison report -------------------------------------

COMPARISON_COLUMNS = [
    "minute", "tribe", "agents_alive", "cb_balance",
    "findings_emitted", "true_positives", "false_positives",
    "bug_class", "is_first_finder", "tribe_size",
    "replication_event_count", "tribe_death_ts",
]


def _read_telemetry_csv(path: str) -> list[dict[str, str]]:
    """Read a 12-column telemetry.csv and return rows as dicts. Skips
    the header line. Tolerates short/long rows defensively."""
    if not os.path.isfile(path):
        return []
    out: list[dict[str, str]] = []
    with open(path, encoding="utf-8") as f:
        reader = csv.reader(f)
        try:
            header = next(reader)
        except StopIteration:
            return []
        # Trust the documented schema if the row count matches; otherwise
        # the first row IS the header — skip it positionally.
        if header[:1] != ["minute"]:
            # Not a header — re-open to include it.
            f.seek(0)
            reader = csv.reader(f)
        for row in reader:
            if not row:
                continue
            d: dict[str, str] = {}
            for i, k in enumerate(COMPARISON_COLUMNS):
                d[k] = row[i] if i < len(row) else ""
            out.append(d)
    return out


def _safe_int(s: str | int | None) -> int:
    if isinstance(s, int):
        return s
    if s is None:
        return 0
    try:
        return int(s)
    except (TypeError, ValueError):
        return 0


def _aggregate_telemetry(rows: list[dict[str, str]]) -> dict[str, int | float]:
    """Aggregate a telemetry.csv into the comparison-relevant scalars.
    Sum across all rows: total findings, TPs, FPs, CB, replication events,
    first-finder ticks. Also count distinct minutes (run length proxy).
    """
    total_findings = 0
    total_tp = 0
    total_fp = 0
    total_cb = 0
    total_rep = 0
    total_ff = 0
    minutes: set[int] = set()
    tribes: set[str] = set()
    for r in rows:
        total_findings += _safe_int(r.get("findings_emitted"))
        total_tp += _safe_int(r.get("true_positives"))
        total_fp += _safe_int(r.get("false_positives"))
        total_cb += _safe_int(r.get("cb_balance"))
        total_rep += _safe_int(r.get("replication_event_count"))
        total_ff += _safe_int(r.get("is_first_finder"))
        m = _safe_int(r.get("minute"))
        minutes.add(m)
        t = r.get("tribe") or ""
        if t:
            tribes.add(t)
    cost_per_tp = (float(total_cb) / total_tp) if total_tp > 0 else 0.0
    return {
        "total_findings": total_findings,
        "total_tp": total_tp,
        "total_fp": total_fp,
        "total_cb": total_cb,
        "total_rep": total_rep,
        "total_ff": total_ff,
        "n_minutes": len(minutes),
        "n_tribes": len(tribes),
        "cost_per_tp": cost_per_tp,
    }


def _aggregate_market(rows: list[dict[str, object]]) -> dict[str, int]:
    """Aggregate market.csv rows into substrate revenue + cache-hit count.
    Per Risk 7 mitigation: substrate revenue excludes rows where
    cache_hit == "1". The substrate-revenue is computed by joining sell
    rows to substrate (cache_hit=0) buy rows on topic.
    """
    if not rows:
        return {
            "n_buy": 0,
            "n_sell": 0,
            "n_cache_hit": 0,
            "substrate_revenue": 0,
        }
    buy_substrate: set[str] = set()
    n_buy = 0
    n_sell = 0
    n_cache_hit = 0
    for r in rows:
        op = (r.get("op") or "")
        cache_hit = (r.get("cache_hit") or "")
        topic = (r.get("topic") or "")
        if op == "buy":
            n_buy += 1
            if cache_hit == "1":
                n_cache_hit += 1
            if cache_hit == "0" and isinstance(topic, str) and topic:
                buy_substrate.add(topic)
        elif op == "sell":
            n_sell += 1
    revenue = 0
    for r in rows:
        if (r.get("op") or "") != "sell":
            continue
        topic = (r.get("topic") or "")
        if not isinstance(topic, str) or topic not in buy_substrate:
            continue
        try:
            revenue += int(r.get("ask_price") or 0)
        except (TypeError, ValueError):
            continue
    return {
        "n_buy": n_buy,
        "n_sell": n_sell,
        "n_cache_hit": n_cache_hit,
        "substrate_revenue": revenue,
    }


def write_comparison_report(
    run_dir: str,
    telemetry_csv: str,
    baseline_csv: str,
    market_rows: list[dict[str, object]],
) -> str | None:
    """Emit ``<run-dir>/comparison.md`` with the 5 fixed sections from
    plan Decision 4. Section order and headings are stable so downstream
    consumers can grep by section.
    """
    eco_rows = _read_telemetry_csv(telemetry_csv)
    base_rows = _read_telemetry_csv(baseline_csv)
    eco = _aggregate_telemetry(eco_rows)
    base = _aggregate_telemetry(base_rows)
    market = _aggregate_market(market_rows)

    lines: list[str] = []
    lines.append("# Stage 2 M3 (#394) baseline-vs-ecosystem comparison")
    lines.append("")
    lines.append(f"- ecosystem run dir: `{run_dir}`")
    lines.append(f"- baseline csv:       `{baseline_csv}`")
    lines.append("")

    lines.append("## 1. Findings volume")
    lines.append("")
    lines.append("| metric | ecosystem | baseline |")
    lines.append("|---|---|---|")
    lines.append(f"| total findings | {eco['total_findings']} | {base['total_findings']} |")
    lines.append(f"| true positives | {eco['total_tp']} | {base['total_tp']} |")
    lines.append(f"| false positives | {eco['total_fp']} | {base['total_fp']} |")
    lines.append(f"| first-finder ticks | {eco['total_ff']} | {base['total_ff']} |")
    lines.append("")

    lines.append("## 2. Cost per true positive")
    lines.append("")
    lines.append("| metric | ecosystem | baseline |")
    lines.append("|---|---|---|")
    lines.append(f"| total CB | {eco['total_cb']} | {base['total_cb']} |")
    lines.append(f"| TPs | {eco['total_tp']} | {base['total_tp']} |")
    lines.append(
        f"| CB / TP | {eco['cost_per_tp']:.2f} | {base['cost_per_tp']:.2f} |"
    )
    lines.append("")

    lines.append("## 3. Replication / tribe-size dynamics")
    lines.append("")
    lines.append("| metric | ecosystem | baseline |")
    lines.append("|---|---|---|")
    lines.append(f"| replication events | {eco['total_rep']} | {base['total_rep']} |")
    lines.append(f"| distinct tribes seen | {eco['n_tribes']} | {base['n_tribes']} |")
    lines.append("")

    lines.append("## 4. Run shape")
    lines.append("")
    lines.append("| metric | ecosystem | baseline |")
    lines.append("|---|---|---|")
    lines.append(f"| distinct minutes covered | {eco['n_minutes']} | {base['n_minutes']} |")
    lines.append("")

    lines.append("## 5. Knowledge market activity (ecosystem only)")
    lines.append("")
    if not market_rows:
        lines.append("_no market activity in this run_")
    else:
        lines.append("| metric | value |")
        lines.append("|---|---|")
        lines.append(f"| buy ops | {market['n_buy']} |")
        lines.append(f"| sell ops | {market['n_sell']} |")
        lines.append(f"| cache-hit buys | {market['n_cache_hit']} |")
        lines.append(
            f"| substrate revenue (cache_hit=0 only) | {market['substrate_revenue']} |"
        )
    lines.append("")

    out_path = os.path.join(run_dir, "comparison.md")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return out_path


if __name__ == "__main__":
    main()
