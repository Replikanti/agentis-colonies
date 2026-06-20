#!/usr/bin/env python3
"""cross-sectional-backtest.py -- walk-forward cross-sectional (relative-value)
long-short backtest on alts (#1193). Genuine active trading, not yield: rank
symbols by trailing return, LONG the top-K, SHORT the bottom-K (dollar-neutral,
equal weight), hold forward (out-of-sample), rebalance, repeat.

We proved ABSOLUTE directional prediction has no edge (#1123/#1154/#1166/#1167).
Relative performance (cross-sectional momentum / reversal) is a less-efficient,
documented factor -- this tests, with the same rigour, whether it has an edge
after costs out-of-sample.

Walk-forward (no look-ahead): at rebalance t, score trailing return over
[t-L, t]; pick long top-K / short bottom-K; the realised return is the FORWARD
move [t, t+R] (longs' mean minus shorts' mean), minus turnover cost on the
basket changes. Selection on past, return on future.

momentum = long the top trailing return; reversal = long the bottom (sign flip).
Standard library only. Daily perp klines from fapi.binance.com.
"""
import argparse
import datetime
import json
import math
import os
import sys
import urllib.request


def epoch_ms(s):
    if s.isdigit():
        return int(s)
    return int(datetime.datetime.strptime(s, "%Y-%m-%d").replace(
        tzinfo=datetime.timezone.utc).timestamp() * 1000)


def daily_closes(symbol, start, end):
    out = {}
    cur = start
    while cur < end:
        url = ("https://fapi.binance.com/fapi/v1/klines?symbol=%s&interval=1d&startTime=%d&endTime=%d&limit=1000"
               % (symbol, cur, end))
        try:
            with urllib.request.urlopen(url, timeout=30) as r:
                batch = json.load(r)
        except Exception as e:  # noqa: BLE001
            sys.stderr.write("klines %s err: %s\n" % (symbol, e))
            return out
        if not batch:
            break
        for k in batch:
            out[k[0]] = float(k[4])
        cur = batch[-1][0] + 1
        if len(batch) < 1000:
            break
    return out


def sharpe(returns):
    n = len(returns)
    if n < 2:
        return 0.0
    mean = sum(returns) / n
    var = sum((r - mean) ** 2 for r in returns) / (n - 1)
    sd = math.sqrt(var)
    return mean / sd if sd > 0 else 0.0


def max_dd(cum):
    peak, mdd = -1e18, 0.0
    for x in cum:
        peak = max(peak, x)
        mdd = max(mdd, peak - x)
    return mdd


def run(series, days_sorted, lookback_d, rebalance_d, top_k, reversal, cost_rt, t_start, t_end):
    cost = cost_rt / 10000.0
    # day index helper
    day_ms = 86400000
    rets = []
    prev_long, prev_short = set(), set()
    t = t_start + lookback_d * day_ms
    while t + rebalance_d * day_ms <= t_end:
        # find closes at t-L, t, t+R (nearest available day <= target)
        def close_at(ts):
            # nearest day with data at or before ts
            best = None
            for d in days_sorted:
                if d <= ts:
                    best = d
                else:
                    break
            return best
        t_lb = close_at(t - lookback_d * day_ms)
        t_now = close_at(t)
        t_fwd = close_at(t + rebalance_d * day_ms)
        if not (t_lb and t_now and t_fwd) or t_fwd <= t_now:
            t += rebalance_d * day_ms
            continue
        trailing = {}
        forward = {}
        for s, cl in series.items():
            if t_lb in cl and t_now in cl and t_fwd in cl and cl[t_lb] > 0 and cl[t_now] > 0:
                trailing[s] = cl[t_now] / cl[t_lb] - 1.0
                forward[s] = cl[t_fwd] / cl[t_now] - 1.0
        if len(trailing) < 2 * top_k:
            t += rebalance_d * day_ms
            continue
        ranked = sorted(trailing, key=lambda s: trailing[s], reverse=not reversal)
        longs = set(ranked[:top_k])
        shorts = set(ranked[-top_k:])
        long_ret = sum(forward[s] for s in longs) / len(longs)
        short_ret = sum(forward[s] for s in shorts) / len(shorts)
        gross = long_ret - short_ret  # dollar-neutral long-short
        # turnover cost: names entering either basket pay ~half round-trip,
        # normalised by basket size, across both legs
        changed = len(longs ^ prev_long) + len(shorts ^ prev_short)
        turn_cost = cost * (changed / 2.0) / (2.0 * top_k)
        rets.append(gross - turn_cost)
        prev_long, prev_short = longs, shorts
        t += rebalance_d * day_ms
    if not rets:
        return None
    total = sum(rets)
    days = (t_end - (t_start + lookback_d * day_ms)) / 86400000.0
    cum = []
    acc = 0.0
    for r in rets:
        acc += r
        cum.append(acc)
    reb_per_year = 365.0 / rebalance_d
    return {
        "rebalances": len(rets),
        "total_return_pct": round(total * 100, 3),
        "annualised_pct": round(total / days * 365 * 100, 2) if days else 0.0,
        "sharpe": round(sharpe(rets) * math.sqrt(reb_per_year), 2),
        "max_drawdown_pct": round(max_dd(cum) * 100, 3),
        "avg_per_rebalance_pct": round(total / len(rets) * 100, 4),
    }


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--top-k", type=int, default=4)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=20.0)
    ap.add_argument("--lookbacks", default="7,14,30")
    ap.add_argument("--rebalance-days", type=int, default=7)
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    start, end = epoch_ms(args.start), epoch_ms(args.end)
    series = {}
    for s in symbols:
        cl = daily_closes(s, start, end)
        if len(cl) > 60:
            series[s] = cl
    if len(series) < 2 * args.top_k:
        sys.stderr.write("not enough symbols with data\n")
        return 2
    days_sorted = sorted(set().union(*[set(c) for c in series.values()]))

    out = {"symbols_loaded": sorted(series.keys()), "params": {
        "top_k": args.top_k, "cost_bps_roundtrip": args.cost_bps_roundtrip,
        "rebalance_days": args.rebalance_days}, "results": []}
    for lb in [int(x) for x in args.lookbacks.split(",")]:
        for reversal in (False, True):
            r = run(series, days_sorted, lb, args.rebalance_days, args.top_k,
                    reversal, args.cost_bps_roundtrip, start, end)
            if r:
                r["lookback_days"] = lb
                r["signal"] = "reversal" if reversal else "momentum"
                out["results"].append(r)
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
