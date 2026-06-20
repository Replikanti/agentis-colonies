#!/usr/bin/env python3
"""cross-sectional-sweep.py -- refine the cross-sectional momentum edge (#1197):
(1) sweep rebalance frequency x top-K x lookback to find the best risk-adjusted
config, and (2) apply drawdown-aware TRAILING-VOL TARGETING to tame the 30-35 %
max DD found in #1194.

Same walk-forward as #1194 (rank by trailing return, long top-K / short bottom-K,
dollar-neutral, hold forward, no look-ahead), momentum only (reversal lost).

Sizing: scale each rebalance return by target_per_period_vol / trailing_realised
_vol, using only PAST returns (no look-ahead), capped at --max-leverage (high
leverage = liquidation risk, #1188). This holds the book near a chosen annualised
vol so the drawdown is a deliberate risk choice, not an artifact of raw exposure.

Standard library only. Daily perp klines from fapi.binance.com.
"""
import argparse
import datetime
import json
import math
import sys
import urllib.request

DAY_MS = 86400000


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


def stdev(xs):
    n = len(xs)
    if n < 2:
        return 0.0
    m = sum(xs) / n
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (n - 1))


def sharpe_ann(returns, reb_per_year):
    if len(returns) < 2:
        return 0.0
    sd = stdev(returns)
    if sd == 0:
        return 0.0
    return (sum(returns) / len(returns)) / sd * math.sqrt(reb_per_year)


def ann_vol(returns, reb_per_year):
    return stdev(returns) * math.sqrt(reb_per_year) * 100


def max_dd(returns):
    peak, mdd, acc = 0.0, 0.0, 0.0
    for r in returns:
        acc += r
        peak = max(peak, acc)
        mdd = max(mdd, peak - acc)
    return mdd * 100


def walk_forward(series, days_sorted, lookback_d, rebalance_d, top_k, cost_rt, t_start, t_end):
    cost = cost_rt / 10000.0
    rets, turns = [], []
    prev_long, prev_short = set(), set()
    t = t_start + lookback_d * DAY_MS

    def close_at(ts):
        best = None
        for d in days_sorted:
            if d <= ts:
                best = d
            else:
                break
        return best

    while t + rebalance_d * DAY_MS <= t_end:
        t_lb, t_now, t_fwd = close_at(t - lookback_d * DAY_MS), close_at(t), close_at(t + rebalance_d * DAY_MS)
        if not (t_lb and t_now and t_fwd) or t_fwd <= t_now:
            t += rebalance_d * DAY_MS
            continue
        trailing, forward = {}, {}
        for s, cl in series.items():
            if t_lb in cl and t_now in cl and t_fwd in cl and cl[t_lb] > 0 and cl[t_now] > 0:
                trailing[s] = cl[t_now] / cl[t_lb] - 1.0
                forward[s] = cl[t_fwd] / cl[t_now] - 1.0
        if len(trailing) < 2 * top_k:
            t += rebalance_d * DAY_MS
            continue
        ranked = sorted(trailing, key=lambda s: trailing[s], reverse=True)
        longs, shorts = set(ranked[:top_k]), set(ranked[-top_k:])
        gross = sum(forward[s] for s in longs) / len(longs) - sum(forward[s] for s in shorts) / len(shorts)
        changed = len(longs ^ prev_long) + len(shorts ^ prev_short)
        turn = (changed / 2.0) / (2.0 * top_k)
        rets.append(gross - cost * turn)
        turns.append(turn)
        prev_long, prev_short = longs, shorts
        t += rebalance_d * DAY_MS
    return rets, turns


def vol_target(returns, reb_per_year, target_ann_vol_pct, window, max_lev):
    """Size each period by target / trailing realised vol, using only PAST
    returns (no look-ahead), capped at max_lev. Returns sized series."""
    tgt_per = (target_ann_vol_pct / 100.0) / math.sqrt(reb_per_year)
    sized = []
    for i in range(len(returns)):
        hist = returns[max(0, i - window):i]
        tv = stdev(hist) if len(hist) >= 2 else 0.0
        lev = min(max_lev, tgt_per / tv) if tv > 0 else 1.0
        sized.append(returns[i] * lev)
    return sized


def summarise(returns, reb_per_year, t_span_days):
    total = sum(returns)
    return {
        "ann_pct": round(total / t_span_days * 365 * 100, 2) if t_span_days else 0.0,
        "sharpe": round(sharpe_ann(returns, reb_per_year), 2),
        "ann_vol_pct": round(ann_vol(returns, reb_per_year), 1),
        "max_dd_pct": round(max_dd(returns), 1),
    }


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument("--symbols", required=True)
    ap.add_argument("--start", required=True)
    ap.add_argument("--end", required=True)
    ap.add_argument("--cost-bps-roundtrip", type=float, default=60.0)
    ap.add_argument("--rebalances", default="3,7,14")
    ap.add_argument("--top-ks", default="3,4,6")
    ap.add_argument("--lookbacks", default="14,30")
    ap.add_argument("--target-vol-pct", type=float, default=20.0)
    ap.add_argument("--vol-window", type=int, default=8)
    ap.add_argument("--max-leverage", type=float, default=3.0)
    args = ap.parse_args(argv)

    symbols = [s.strip().upper() for s in args.symbols.split(",") if s.strip()]
    start, end = epoch_ms(args.start), epoch_ms(args.end)
    series = {}
    for s in symbols:
        cl = daily_closes(s, start, end)
        if len(cl) > 60:
            series[s] = cl
    if len(series) < 6:
        sys.stderr.write("not enough symbols\n")
        return 2
    days_sorted = sorted(set().union(*[set(c) for c in series.values()]))

    out = {"symbols_loaded": len(series), "cost_bps": args.cost_bps_roundtrip,
           "target_vol_pct": args.target_vol_pct, "max_leverage": args.max_leverage, "results": []}
    for reb in [int(x) for x in args.rebalances.split(",")]:
        reb_per_year = 365.0 / reb
        for k in [int(x) for x in args.top_ks.split(",")]:
            for lb in [int(x) for x in args.lookbacks.split(",")]:
                rets, turns = walk_forward(series, days_sorted, lb, reb, k, args.cost_bps_roundtrip, start, end)
                if len(rets) < 5:
                    continue
                span = (end - (start + lb * DAY_MS)) / float(DAY_MS)
                raw = summarise(rets, reb_per_year, span)
                sized = summarise(vol_target(rets, reb_per_year, args.target_vol_pct, args.vol_window, args.max_leverage), reb_per_year, span)
                out["results"].append({
                    "rebalance_d": reb, "top_k": k, "lookback_d": lb,
                    "rebalances": len(rets),
                    "avg_turnover": round(sum(turns) / len(turns), 3),
                    "raw": raw, "sized": sized,
                })
    out["results"].sort(key=lambda r: -r["sized"]["sharpe"])
    print(json.dumps(out, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
