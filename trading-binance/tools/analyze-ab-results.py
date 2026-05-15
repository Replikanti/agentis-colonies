#!/usr/bin/env python3
# analyze-ab-results.py -- A/B emergence experiment analyser for the
# trading-binance federation (#573 PR-5).
#
# Walks an experiment directory produced by run-ab-experiment.sh:
#
#   <experiment-dir>/
#     experiment-manifest.json
#     ab-trading-<ts>-control-run-1/
#       trade-ledger.jsonl
#       laptop-node/.agentis/experience/*.jsonl
#       laptop-node/.agentis/memo*.jsonl
#     ab-trading-<ts>-treatment-run-1/
#       ...
#
# Per-(arm, tribe) metrics:
#   - pnl_bps_total
#   - win_rate (excludes FLAT)
#   - total_trades
#   - max_drawdown_bps (chronological)
#   - sharpe = mean(pnl) / stdev(pnl)   (no annualisation; caveat)
#   - mutation_rate surrogates: distinct prompt-body SHAs +
#     `strategist_prompt_evolve` learn rows tagged `rewritten`
#
# Aggregates per (arm, tribe) across the N replicates: mean + stdev.
#
# Output: <experiment-dir>/comparison.md
#
# Stdlib only. Refuses to emit the report if any run dir cannot be
# unambiguously mapped to one arm via experiment-manifest.json.
#
# Usage: analyze-ab-results.py <experiment-dir>

import argparse
import json
import math
import os
import re
import statistics
import sys
from pathlib import Path


TRIBES = ["tribe-alpha", "tribe-beta", "tribe-gamma", "tribe-delta", "tribe-epsilon"]

# Tag-list classifications we count from experience rows.
_PNL_BPS_RE = re.compile(r"pnl_bps=(-?\d+(?:\.\d+)?)")


def read_jsonl(path):
    """Return a list of decoded JSON objects from a .jsonl file. Returns
    an empty list when the file is missing or unreadable (per-line
    JSONDecodeError tolerated)."""
    out = []
    if not os.path.isfile(path):
        return out
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    out.append(json.loads(line))
                except (json.JSONDecodeError, ValueError):
                    continue
    except OSError:
        return []
    return out


def _classification_from_tags(tags):
    """Return WIN / LOSS / FLAT from a tag list, or empty string."""
    if not isinstance(tags, list):
        return ""
    for t in tags:
        if not isinstance(t, str):
            continue
        if t.startswith("classification:"):
            return t.split(":", 1)[1]
    return ""


def _pnl_bps_from_row(row):
    """Extract pnl_bps from a learn() row's `details` string. The
    strategist emits `details = "pnl_bps=<int_or_float>"`. Returns 0.0
    when the field is absent or unparseable."""
    details = row.get("details") if isinstance(row, dict) else None
    if not isinstance(details, str):
        return 0.0
    m = _PNL_BPS_RE.search(details)
    if not m:
        return 0.0
    try:
        return float(m.group(1))
    except (TypeError, ValueError):
        return 0.0


def _ts_from_row(row):
    """Best-effort chronological key. Falls back to 0 when the row
    carries no timestamp."""
    if not isinstance(row, dict):
        return 0
    ts = row.get("ts")
    if isinstance(ts, (int, float)):
        return int(ts)
    when = row.get("when")
    if isinstance(when, (int, float)):
        return int(when)
    return 0


def _collect_settle_rows(experience_dir, tribe):
    """Return chronologically-sorted settle rows for one tribe. Looks
    at every .jsonl file under experience_dir (one per daemon id) and
    keeps rows whose topic == 'settle' AND tags contain the tribe name
    AND a classification tag. Missing dir returns []."""
    out = []
    if not os.path.isdir(experience_dir):
        return out
    try:
        names = sorted(os.listdir(experience_dir))
    except OSError:
        return out
    for name in names:
        if not name.endswith(".jsonl"):
            continue
        rows = read_jsonl(os.path.join(experience_dir, name))
        for row in rows:
            if not isinstance(row, dict):
                continue
            if row.get("topic") != "settle":
                continue
            tags = row.get("tags") or []
            if not isinstance(tags, list):
                continue
            if tribe not in tags:
                continue
            cls = _classification_from_tags(tags)
            if not cls:
                continue
            out.append(row)
    out.sort(key=_ts_from_row)
    return out


def _max_drawdown(pnls):
    """Chronological max drawdown over the running equity curve.
    pnls already sorted by ts ascending. Returns a non-negative bps
    value (0 when no trades or curve monotonically non-decreasing)."""
    if not pnls:
        return 0.0
    running = 0.0
    peak = 0.0
    max_dd = 0.0
    for p in pnls:
        running += p
        if running > peak:
            peak = running
        dd = peak - running
        if dd > max_dd:
            max_dd = dd
    return max_dd


def _sharpe_like(pnls):
    """mean / stdev across per-trade returns; no annualisation. Returns
    0.0 when fewer than 2 trades (stdev undefined) or stdev == 0."""
    if len(pnls) < 2:
        return 0.0
    try:
        sd = statistics.stdev(pnls)
    except statistics.StatisticsError:
        return 0.0
    if sd == 0:
        return 0.0
    return statistics.mean(pnls) / sd


def _mutation_surrogates(run_dir, tribe):
    """Return (distinct_prompt_body_shas, rewrite_event_count) for one
    (run, tribe). Sources:
      - distinct `strategist:prompt_body:<sha>` memo keys recorded in
        any .jsonl under .agentis/memo* (best-effort -- the runtime
        layout may vary).
      - `learn("strategist_prompt_evolve", ..., tags=[..., "rewritten"])`
        rows in .agentis/experience/."""
    agentis_dir = os.path.join(run_dir, "laptop-node", ".agentis")
    sha_set = set()
    if os.path.isdir(agentis_dir):
        for root, _dirs, files in os.walk(agentis_dir):
            base = os.path.basename(root)
            if not (base.startswith("memo") or base == "memo"):
                # Only descend through memo* directories; avoid
                # over-walking the entire .agentis tree.
                continue
            for f in files:
                if not f.endswith(".jsonl"):
                    continue
                for row in read_jsonl(os.path.join(root, f)):
                    if not isinstance(row, dict):
                        continue
                    key = row.get("key")
                    if isinstance(key, str) and key.startswith("strategist:prompt_body:"):
                        sha_set.add(key.split(":", 2)[2])
        # Also probe top-level memo*.jsonl in case the runtime keeps a
        # single flat file rather than per-key dirs.
        for entry in os.listdir(agentis_dir):
            full = os.path.join(agentis_dir, entry)
            if not os.path.isfile(full):
                continue
            if not entry.startswith("memo"):
                continue
            if not entry.endswith(".jsonl"):
                continue
            for row in read_jsonl(full):
                if not isinstance(row, dict):
                    continue
                key = row.get("key")
                if isinstance(key, str) and key.startswith("strategist:prompt_body:"):
                    sha_set.add(key.split(":", 2)[2])

    rewrite_count = 0
    exp_dir = os.path.join(run_dir, "laptop-node", ".agentis", "experience")
    if os.path.isdir(exp_dir):
        for name in os.listdir(exp_dir):
            if not name.endswith(".jsonl"):
                continue
            for row in read_jsonl(os.path.join(exp_dir, name)):
                if not isinstance(row, dict):
                    continue
                if row.get("topic") != "strategist_prompt_evolve":
                    continue
                tags = row.get("tags") or []
                if not isinstance(tags, list):
                    continue
                if "rewritten" not in tags:
                    continue
                if tribe and tribe not in tags:
                    # Best-effort tribe filter; strategist tags rewrite
                    # rows with `trading-binance` but not always the
                    # tribe name -- so unfiltered fall-through is the
                    # safe default.
                    pass
                rewrite_count += 1
    return len(sha_set), rewrite_count


def compute_run_tribe_metrics(run_dir, tribe):
    """All metrics for one (run, tribe). Missing experience dir => zero
    row, no crash."""
    exp_dir = os.path.join(run_dir, "laptop-node", ".agentis", "experience")
    rows = _collect_settle_rows(exp_dir, tribe)
    pnls = []
    wins = 0
    losses = 0
    flats = 0
    for row in rows:
        cls = _classification_from_tags(row.get("tags") or [])
        bps = _pnl_bps_from_row(row)
        pnls.append(bps)
        if cls == "WIN":
            wins += 1
        elif cls == "LOSS":
            losses += 1
        elif cls == "FLAT":
            flats += 1
    total = len(rows)
    decided = wins + losses
    win_rate = (wins / decided) if decided > 0 else 0.0
    pnl_total = sum(pnls)
    max_dd = _max_drawdown(pnls)
    sharpe = _sharpe_like(pnls)
    distinct_shas, rewrite_events = _mutation_surrogates(run_dir, tribe)
    return {
        "tribe": tribe,
        "total_trades": total,
        "wins": wins,
        "losses": losses,
        "flats": flats,
        "win_rate": win_rate,
        "pnl_bps_total": pnl_total,
        "max_drawdown_bps": max_dd,
        "sharpe": sharpe,
        "distinct_prompt_shas": distinct_shas,
        "rewrite_events": rewrite_events,
    }


def _agg(values):
    """(mean, stdev) tuple; stdev=0 when n<2."""
    if not values:
        return (0.0, 0.0)
    mean = statistics.mean(values)
    if len(values) < 2:
        return (mean, 0.0)
    try:
        sd = statistics.stdev(values)
    except statistics.StatisticsError:
        sd = 0.0
    return (mean, sd)


def aggregate_arm_tribe(per_run_metrics):
    """List of metric dicts (one per replicate) -> aggregated dict."""
    if not per_run_metrics:
        return {
            "n": 0,
            "pnl_bps_mean": 0.0, "pnl_bps_stdev": 0.0,
            "win_rate_mean": 0.0, "win_rate_stdev": 0.0,
            "trades_mean": 0.0, "trades_stdev": 0.0,
            "max_dd_mean": 0.0, "max_dd_stdev": 0.0,
            "sharpe_mean": 0.0, "sharpe_stdev": 0.0,
            "distinct_shas_mean": 0.0, "distinct_shas_stdev": 0.0,
            "rewrite_events_mean": 0.0, "rewrite_events_stdev": 0.0,
        }
    pnl = [m["pnl_bps_total"] for m in per_run_metrics]
    wr = [m["win_rate"] for m in per_run_metrics]
    tr = [m["total_trades"] for m in per_run_metrics]
    dd = [m["max_drawdown_bps"] for m in per_run_metrics]
    sh = [m["sharpe"] for m in per_run_metrics]
    ds = [m["distinct_prompt_shas"] for m in per_run_metrics]
    re_ = [m["rewrite_events"] for m in per_run_metrics]
    pnl_m, pnl_s = _agg(pnl)
    wr_m, wr_s = _agg(wr)
    tr_m, tr_s = _agg(tr)
    dd_m, dd_s = _agg(dd)
    sh_m, sh_s = _agg(sh)
    ds_m, ds_s = _agg(ds)
    re_m, re_s = _agg(re_)
    return {
        "n": len(per_run_metrics),
        "pnl_bps_mean": pnl_m, "pnl_bps_stdev": pnl_s,
        "win_rate_mean": wr_m, "win_rate_stdev": wr_s,
        "trades_mean": tr_m, "trades_stdev": tr_s,
        "max_dd_mean": dd_m, "max_dd_stdev": dd_s,
        "sharpe_mean": sh_m, "sharpe_stdev": sh_s,
        "distinct_shas_mean": ds_m, "distinct_shas_stdev": ds_s,
        "rewrite_events_mean": re_m, "rewrite_events_stdev": re_s,
    }


def _fmt(x, places=2):
    if isinstance(x, float):
        if math.isnan(x) or math.isinf(x):
            return "n/a"
        return f"{x:.{places}f}"
    return str(x)


HONEST_CAVEATS = """## Honest caveats

- Single symbol (BTCUSDT).
- Single timeframe (1h).
- No live or paper trading — offline replay only; alpha-decay from
  adversaries not exercised.
- No multi-tribe knowledge-market.
- N=3 replicates per arm is a direction-of-effect probe, not a
  publishable result. ~70% power to detect a 50bps mean difference. A
  null result here means "evolution is not obviously winning"; it does
  NOT prove "evolution adds no value."
- Same LLM model both arms — testing the meta-prompt evolution
  mechanism, not the underlying model.
- 90 days is short — evolved strategies may overfit. Out-of-sample
  validation is Phase 2.
- No multiple-comparison correction across the 5 tribes; tribe-level
  tables are exploratory.
"""


def load_manifest(experiment_dir):
    """Read experiment-manifest.json and return (manifest_dict,
    run_dir -> arm map). Raises FileNotFoundError if missing."""
    mpath = os.path.join(experiment_dir, "experiment-manifest.json")
    if not os.path.isfile(mpath):
        raise FileNotFoundError(mpath)
    with open(mpath, "r", encoding="utf-8") as f:
        manifest = json.load(f)
    run_to_arm = {}
    for run in manifest.get("runs", []):
        rd = run.get("run_dir")
        arm = run.get("arm")
        if not rd or not arm:
            continue
        run_to_arm[os.path.basename(rd.rstrip("/"))] = arm
    return manifest, run_to_arm


def discover_run_dirs(experiment_dir, run_to_arm):
    """List every direct subdir of experiment_dir matching the
    ab-trading-*-{control,treatment}-run-* pattern. Returns
    (arm -> [absolute run_dir]) mapping. Refuses to map any subdir
    whose basename is not unambiguously found in run_to_arm."""
    arms = {"control": [], "treatment": []}
    if not os.path.isdir(experiment_dir):
        return arms, []
    unmapped = []
    for entry in sorted(os.listdir(experiment_dir)):
        full = os.path.join(experiment_dir, entry)
        if not os.path.isdir(full):
            continue
        if "-control-run-" not in entry and "-treatment-run-" not in entry:
            continue
        arm = run_to_arm.get(entry)
        if arm in ("control", "treatment"):
            arms[arm].append(full)
        else:
            unmapped.append(entry)
    return arms, unmapped


def render_report(manifest, arm_run_metrics, federation_agg):
    """Build the comparison.md text body."""
    lines = []
    lines.append("# A/B emergence experiment — comparison report")
    lines.append("")
    lines.append("## Manifest")
    lines.append("")
    lines.append("| Field | Value |")
    lines.append("|---|---|")
    lines.append("| experiment_ts | " + str(manifest.get("experiment_ts", "")) + " |")
    lines.append("| symbol | " + str(manifest.get("symbol", "")) + " |")
    lines.append("| timeframe | " + str(manifest.get("timeframe", "")) + " |")
    lines.append("| start | " + str(manifest.get("start", "")) + " |")
    lines.append("| end | " + str(manifest.get("end", "")) + " |")
    lines.append("| replay_speed | " + str(manifest.get("replay_speed", "")) + " |")
    lines.append("| n_replicates_per_arm | " + str(manifest.get("n_replicates_per_arm", "")) + " |")
    lines.append("| llm_model | " + str(manifest.get("llm_model", "")) + " |")
    lines.append("")
    lines.append("Arms:")
    lines.append("")
    lines.append("- **control** = REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=999 (prompt evolution off)")
    lines.append("- **treatment** = REPLAY_STRATEGIST_PROMPT_EVOLUTION_THRESHOLD=3 (prompt evolution on)")
    lines.append("")
    lines.append("### Run -> arm mapping")
    lines.append("")
    lines.append("| run_idx | arm | run_dir | threshold | exit_code |")
    lines.append("|---|---|---|---|---|")
    for run in manifest.get("runs", []):
        lines.append(
            "| " + str(run.get("run_idx", "")) + " | "
            + str(run.get("arm", "")) + " | "
            + os.path.basename(str(run.get("run_dir", ""))) + " | "
            + str(run.get("strategist_prompt_evolution_threshold", "")) + " | "
            + str(run.get("exit_code", "")) + " |"
        )
    lines.append("")

    # Per-tribe tables.
    lines.append("## Per-tribe arm-vs-arm (mean +/- stdev across replicates)")
    lines.append("")
    for tribe in TRIBES:
        lines.append("### " + tribe)
        lines.append("")
        lines.append("| Metric | control | treatment |")
        lines.append("|---|---|---|")
        c = arm_run_metrics["control"]["per_tribe_agg"][tribe]
        t = arm_run_metrics["treatment"]["per_tribe_agg"][tribe]
        lines.append("| n (replicates) | " + _fmt(c["n"], 0) + " | " + _fmt(t["n"], 0) + " |")
        lines.append("| pnl_bps_total | " + _fmt(c["pnl_bps_mean"]) + " +/- " + _fmt(c["pnl_bps_stdev"]) + " | " + _fmt(t["pnl_bps_mean"]) + " +/- " + _fmt(t["pnl_bps_stdev"]) + " |")
        lines.append("| win_rate | " + _fmt(c["win_rate_mean"], 4) + " +/- " + _fmt(c["win_rate_stdev"], 4) + " | " + _fmt(t["win_rate_mean"], 4) + " +/- " + _fmt(t["win_rate_stdev"], 4) + " |")
        lines.append("| total_trades | " + _fmt(c["trades_mean"]) + " +/- " + _fmt(c["trades_stdev"]) + " | " + _fmt(t["trades_mean"]) + " +/- " + _fmt(t["trades_stdev"]) + " |")
        lines.append("| max_drawdown_bps | " + _fmt(c["max_dd_mean"]) + " +/- " + _fmt(c["max_dd_stdev"]) + " | " + _fmt(t["max_dd_mean"]) + " +/- " + _fmt(t["max_dd_stdev"]) + " |")
        lines.append("| sharpe (per-trade, no annualisation) | " + _fmt(c["sharpe_mean"], 4) + " +/- " + _fmt(c["sharpe_stdev"], 4) + " | " + _fmt(t["sharpe_mean"], 4) + " +/- " + _fmt(t["sharpe_stdev"], 4) + " |")
        lines.append("| distinct prompt-body SHAs | " + _fmt(c["distinct_shas_mean"]) + " +/- " + _fmt(c["distinct_shas_stdev"]) + " | " + _fmt(t["distinct_shas_mean"]) + " +/- " + _fmt(t["distinct_shas_stdev"]) + " |")
        lines.append("| `strategist_prompt_evolve` rewrite rows | " + _fmt(c["rewrite_events_mean"]) + " +/- " + _fmt(c["rewrite_events_stdev"]) + " | " + _fmt(t["rewrite_events_mean"]) + " +/- " + _fmt(t["rewrite_events_stdev"]) + " |")
        lines.append("")

    # Federation aggregate.
    lines.append("## Federation aggregate (all tribes combined)")
    lines.append("")
    lines.append("| Metric | control | treatment |")
    lines.append("|---|---|---|")
    fc = federation_agg["control"]
    ft = federation_agg["treatment"]
    lines.append("| n (replicate x tribe rows) | " + _fmt(fc["n"], 0) + " | " + _fmt(ft["n"], 0) + " |")
    lines.append("| pnl_bps_total | " + _fmt(fc["pnl_bps_mean"]) + " +/- " + _fmt(fc["pnl_bps_stdev"]) + " | " + _fmt(ft["pnl_bps_mean"]) + " +/- " + _fmt(ft["pnl_bps_stdev"]) + " |")
    lines.append("| win_rate | " + _fmt(fc["win_rate_mean"], 4) + " +/- " + _fmt(fc["win_rate_stdev"], 4) + " | " + _fmt(ft["win_rate_mean"], 4) + " +/- " + _fmt(ft["win_rate_stdev"], 4) + " |")
    lines.append("| total_trades | " + _fmt(fc["trades_mean"]) + " +/- " + _fmt(fc["trades_stdev"]) + " | " + _fmt(ft["trades_mean"]) + " +/- " + _fmt(ft["trades_stdev"]) + " |")
    lines.append("| max_drawdown_bps | " + _fmt(fc["max_dd_mean"]) + " +/- " + _fmt(fc["max_dd_stdev"]) + " | " + _fmt(ft["max_dd_mean"]) + " +/- " + _fmt(ft["max_dd_stdev"]) + " |")
    lines.append("| sharpe (per-trade, no annualisation) | " + _fmt(fc["sharpe_mean"], 4) + " +/- " + _fmt(fc["sharpe_stdev"], 4) + " | " + _fmt(ft["sharpe_mean"], 4) + " +/- " + _fmt(ft["sharpe_stdev"], 4) + " |")
    lines.append("| distinct prompt-body SHAs | " + _fmt(fc["distinct_shas_mean"]) + " +/- " + _fmt(fc["distinct_shas_stdev"]) + " | " + _fmt(ft["distinct_shas_mean"]) + " +/- " + _fmt(ft["distinct_shas_stdev"]) + " |")
    lines.append("| `strategist_prompt_evolve` rewrite rows | " + _fmt(fc["rewrite_events_mean"]) + " +/- " + _fmt(fc["rewrite_events_stdev"]) + " | " + _fmt(ft["rewrite_events_mean"]) + " +/- " + _fmt(ft["rewrite_events_stdev"]) + " |")
    lines.append("")

    lines.append(HONEST_CAVEATS)
    return "\n".join(lines) + "\n"


def analyze(experiment_dir):
    """End-to-end driver. Returns (comparison_md_path, report_text).
    Raises SystemExit(non-zero) on unmappable run dirs or missing
    manifest."""
    experiment_dir = os.path.abspath(experiment_dir)
    try:
        manifest, run_to_arm = load_manifest(experiment_dir)
    except FileNotFoundError as e:
        sys.stderr.write("analyze-ab-results: missing experiment-manifest.json at " + str(e) + "\n")
        raise SystemExit(3)

    arms, unmapped = discover_run_dirs(experiment_dir, run_to_arm)
    if unmapped:
        sys.stderr.write(
            "analyze-ab-results: refusing to emit comparison.md -- the following "
            "run dirs cannot be mapped to an arm via experiment-manifest.json: "
            + ", ".join(unmapped) + "\n"
        )
        raise SystemExit(2)

    # Walk each arm x run x tribe.
    arm_run_metrics = {
        "control": {"runs": [], "per_tribe_agg": {}},
        "treatment": {"runs": [], "per_tribe_agg": {}},
    }
    for arm in ("control", "treatment"):
        for run_dir in arms[arm]:
            per_tribe = {}
            for tribe in TRIBES:
                per_tribe[tribe] = compute_run_tribe_metrics(run_dir, tribe)
            arm_run_metrics[arm]["runs"].append({
                "run_dir": run_dir,
                "per_tribe": per_tribe,
            })
        # Per-tribe aggregate across replicates.
        for tribe in TRIBES:
            per_run = [r["per_tribe"][tribe] for r in arm_run_metrics[arm]["runs"]]
            arm_run_metrics[arm]["per_tribe_agg"][tribe] = aggregate_arm_tribe(per_run)

    # Federation-level aggregate (every replicate x tribe row pooled).
    federation_agg = {}
    for arm in ("control", "treatment"):
        pooled = []
        for r in arm_run_metrics[arm]["runs"]:
            for tribe in TRIBES:
                pooled.append(r["per_tribe"][tribe])
        federation_agg[arm] = aggregate_arm_tribe(pooled)

    report = render_report(manifest, arm_run_metrics, federation_agg)
    out_path = os.path.join(experiment_dir, "comparison.md")
    with open(out_path, "w", encoding="utf-8") as f:
        f.write(report)
    return out_path, report


def main(argv):
    parser = argparse.ArgumentParser(
        description="A/B emergence experiment analyser (trading-binance #573 PR-5).",
    )
    parser.add_argument("experiment_dir", help="Path produced by run-ab-experiment.sh")
    args = parser.parse_args(argv)
    out_path, _report = analyze(args.experiment_dir)
    sys.stdout.write("[analyze-ab-results] wrote " + out_path + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
