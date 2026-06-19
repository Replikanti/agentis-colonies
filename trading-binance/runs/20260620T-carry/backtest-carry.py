#!/usr/bin/env python3
"""backtest-carry.py -- deterministic walk-forward basket funding-carry backtest
(#1173, Phase 1).

Tests whether a mechanical, NON-predictive funding-carry rule nets positive
OUT-OF-SAMPLE after costs. A delta-neutral position (short perp + long spot)
collects the 8h funding rate when funding > 0, with no price-direction bet.

Walk-forward (honest OOS):
  every REBALANCE days, at time t:
    - score each symbol by TRAILING funding over the prior LOOKBACK days:
      score = trailing-mean-funding, kept only if mean > 0 AND positive-event
      ratio >= MIN_POS_RATIO (filters lumpy/spike-driven symbols like BNB);
    - select the TOP-K by score (selection uses only PAST data);
    - hold that basket equal-weight delta-neutral over the FORWARD
      [t, t+REBALANCE) window and accrue the REALISED (out-of-sample) funding;
    - charge a round-trip cost on basket turnover (symbols entering/leaving).
  Selection on past, harvest on future => no look-ahead.

Benchmarks: always-on equal-weight ALL symbols (no selection), BTC-only
always-on, and cash (0). Reports net annualised carry, Sharpe of per-rebalance
returns, max drawdown, turnover/cost drag, honest verdict.

Standard library only. Funding CSVs: <funding-dir>/<SYM>.csv (fundingTime,fundingRate).
"""
import argparse
import csv
import json
import math
import os
import sys

EIGHT_H_MS = 8 * 3600 * 1000
PER_YEAR = 3 * 365  # 8h funding settlements per year


def load_funding(funding_dir, symbols):
    series = {}
    for sym in symbols:
        path = os.path.join(funding_dir, sym + ".csv")
        if not os.path.isfile(path):
            continue
        rows = []
        with open(path, newline="") as fh:
            for r in csv.DictReader(fh):
                rows.append((int(r["fundingTime"]), float(r["fundingRate"])))
        rows.sort()
        if rows:
            series[sym] = rows
    return series


def window_sum(rows, t0, t1):
    """Sum of fundingRate for settlements in [t0, t1)."""
    return sum(fr for (t, fr) in rows if t0 <= t < t1)


def window_stats(rows, t0, t1):
    vals = [fr for (t, fr) in rows if t0 <= t < t1]
    if not vals:
        return None
    mean = sum(vals) / len(vals)
    pos = sum(1 for v in vals if v > 0)
    return mean, pos / len(vals), len(vals)


def max_drawdown(cum):
    peak = -1e18
    mdd = 0.0
    for x in cum:
        peak = max(peak, x)
        mdd = max(mdd, peak - x)
    return mdd


def sharpe(returns):
    n = len(returns)
    if n < 2:
        return 0.0
    mean = sum(returns) / n
    var = sum((r - mean) ** 2 for r in returns) / (n - 1)
    sd = math.sqrt(var)
    if sd == 0:
        return 0.0
    # per-rebalance Sharpe annualised by sqrt(rebalances per year)
    return mean / sd


def run_strategy(series, t_start, t_end, rebalance_ms, lookback_ms, top_k,
                 min_pos_ratio, cost_bps_rt):
    cost = cost_bps_rt / 10000.0
    syms = list(series.keys())
    period_returns = []
    selections = []
    prev_set = set()
    total_cost = 0.0
    t = t_start
    while t < t_end:
        fwd_end = min(t + rebalance_ms, t_end)
        # score on trailing [t - lookback, t)
        scored = []
        for s in syms:
            st = window_stats(series[s], t - lookback_ms, t)
            if not st:
                continue
            mean, pos_ratio, n = st
            if mean > 0 and pos_ratio >= min_pos_ratio:
                scored.append((mean, s))
        scored.sort(reverse=True)
        chosen = [s for (_, s) in scored[:top_k]]
        cur_set = set(chosen)
        # forward realised funding (OOS), equal-weight
        if chosen:
            fwd = [window_sum(series[s], t, fwd_end) for s in chosen]
            gross = sum(fwd) / len(fwd)
        else:
            gross = 0.0
        # turnover cost: symbols entering or leaving each pay ~half round-trip,
        # normalised by basket size
        changed = len(cur_set ^ prev_set)
        k_eff = max(1, len(chosen) if chosen else len(prev_set))
        period_cost = cost * (changed / 2.0) / k_eff
        total_cost += period_cost
        period_returns.append(gross - period_cost)
        selections.append({"t": t, "chosen": chosen})
        prev_set = cur_set
        t = fwd_end
    return period_returns, selections, total_cost


def run_always_on(series, t_start, t_end, rebalance_ms, symbols):
    """Hold all symbols equal-weight delta-neutral the whole window (one entry)."""
    period_returns = []
    t = t_start
    while t < t_end:
        fwd_end = min(t + rebalance_ms, t_end)
        fwd = []
        for s in symbols:
            if s in series:
                fwd.append(window_sum(series[s], t, fwd_end))
        period_returns.append(sum(fwd) / len(fwd) if fwd else 0.0)
        t = fwd_end
    return period_returns


def summarize(period_returns, days, label):
    total = sum(period_returns)
    n = len(period_returns)
    cum = []
    acc = 0.0
    for r in period_returns:
        acc += r
        cum.append(acc)
    mdd = max_drawdown(cum)
    ann = total / days * 365 if days else 0.0
    reb_per_year = (365.0 / days * n) if days else 0.0
    shp = sharpe(period_returns) * math.sqrt(reb_per_year) if reb_per_year > 0 else 0.0
    return {
        "label": label,
        "rebalances": n,
        "total_return_pct": round(total * 100, 4),
        "annualised_pct": round(ann * 100, 3),
        "sharpe": round(shp, 2),
        "max_drawdown_pct": round(mdd * 100, 4),
    }


def main(argv):
    p = argparse.ArgumentParser(description="Walk-forward basket funding-carry backtest.")
    p.add_argument("--funding-dir", required=True)
    p.add_argument("--symbols", required=True, help="universe, comma-separated")
    p.add_argument("--start", required=True, help="epoch_ms or YYYY-MM-DD")
    p.add_argument("--end", required=True, help="epoch_ms or YYYY-MM-DD")
    p.add_argument("--rebalance-days", type=float, default=7.0)
    p.add_argument("--lookback-days", type=float, default=21.0)
    p.add_argument("--top-k", type=int, default=4)
    p.add_argument("--min-pos-ratio", type=float, default=0.55)
    p.add_argument("--cost-bps-roundtrip", type=float, default=20.0)
    args = p.parse_args(argv)

    def to_ms(s):
        if s.isdigit():
            return int(s)
        import datetime
        return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
            tzinfo=datetime.timezone.utc).timestamp() * 1000)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    series = load_funding(args.funding_dir, symbols)
    if not series:
        sys.stderr.write("no funding data loaded\n")
        return 2
    t_start = to_ms(args.start)
    t_end = to_ms(args.end)
    # start harvesting only after one lookback window is available
    lookback_ms = int(args.lookback_days * 24 * 3600 * 1000)
    rebalance_ms = int(args.rebalance_days * 24 * 3600 * 1000)
    harvest_start = t_start + lookback_ms
    days = (t_end - harvest_start) / (24 * 3600 * 1000.0)

    strat_ret, selections, total_cost = run_strategy(
        series, harvest_start, t_end, rebalance_ms, lookback_ms,
        args.top_k, args.min_pos_ratio, args.cost_bps_roundtrip)
    alt_syms = [s for s in symbols if s != "BTCUSDT"]
    bench_all = run_always_on(series, harvest_start, t_end, rebalance_ms, alt_syms)
    bench_btc = run_always_on(series, harvest_start, t_end, rebalance_ms, ["BTCUSDT"])

    out = {
        "universe": symbols,
        "loaded": sorted(series.keys()),
        "window": {"start": args.start, "end": args.end, "harvest_days": round(days, 1)},
        "params": {
            "rebalance_days": args.rebalance_days, "lookback_days": args.lookback_days,
            "top_k": args.top_k, "min_pos_ratio": args.min_pos_ratio,
            "cost_bps_roundtrip": args.cost_bps_roundtrip,
        },
        "strategy_oos_walk_forward": summarize(strat_ret, days, "WF top-%d carry" % args.top_k),
        "total_cost_drag_pct": round(total_cost * 100, 4),
        "benchmark_always_on_all_alts": summarize(bench_all, days, "always-on all alts"),
        "benchmark_btc_only": summarize(bench_btc, days, "BTC-only always-on"),
        "benchmark_cash_pct_per_yr": 0.0,
        "sample_selections": [
            {"chosen": s["chosen"]} for s in selections[:6]
        ],
    }
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
